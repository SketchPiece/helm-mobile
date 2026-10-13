import Foundation

/// Errors surfaced by RPC calls.
enum RPCError: Error, LocalizedError, Equatable {
    /// The handler failed with a typed error (`Exit.Failure` with a `Fail` cause).
    case failure(tag: String, message: String)
    /// The handler died or the connection reported a defect.
    case defect(String)
    case interrupted
    case disconnected
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failure(_, let message):
            // A token from before this phone asked for the permission; only pairing again adds it.
            if let range = message.range(of: "missing required scope: ") {
                String(localized: "This phone isn't allowed \(message[range.upperBound...].trimmingCharacters(in: .punctuationCharacters)) yet. Pair it with the computer again to allow it.")
            } else {
                message
            }
        case .defect(let message): message
        case .interrupted: String(localized: "The request was interrupted.")
        case .disconnected: String(localized: "Not connected to Helm.")
        case .timedOut: String(localized: "Helm did not answer in time.")
        }
    }

    /// Reads an Effect `Exit.Failure` cause array.
    static func from(cause: JSON?) -> RPCError {
        guard let parts = cause?.array, !parts.isEmpty else { return .defect("Unknown failure") }
        for part in parts where part["_tag"]?.string == "Fail" {
            let error = part["error"]
            let tag = error?["_tag"]?.string ?? "Error"
            let message = error?["message"]?.string
                ?? error?["reason"]?.string
                ?? error?["detail"]?.string
                ?? tag
            return .failure(tag: tag, message: message)
        }
        if parts.contains(where: { $0["_tag"]?.string == "Interrupt" }) { return .interrupted }
        let die = parts.first { $0["_tag"]?.string == "Die" }?["defect"]
        return .defect(die?["message"]?.string ?? die?.string ?? "Server error")
    }
}

/// One Effect RPC session over a WebSocket (`RpcSerialization.layerJson`): one JSON message
/// per text frame. Requests get numeric ids; every stream `Chunk` must be acknowledged or the
/// server stops sending; `Ping` every 5 s keeps the socket alive.
actor RPCConnection {
    private enum Pending {
        case unary(CheckedContinuation<JSON, Error>)
        case stream(AsyncThrowingStream<JSON, Error>.Continuation)
    }

    private let task: URLSessionWebSocketTask
    private var nextId = 0
    private var pending: [Int: Pending] = [:]
    private var closed = false
    private var missedPongs = 0
    private var onClose: (@Sendable (Error?) -> Void)?
    /// Why the socket closed, for the connection log: the WebSocket close code and reason, if any.
    private(set) var closeDetail = ""

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        // Snapshot frames can be several MiB; the default limit is 1 MiB.
        task.maximumMessageSize = 64 * 1024 * 1024
    }

    func start(onClose: @escaping @Sendable (Error?) -> Void) {
        self.onClose = onClose
        task.resume()
        Task { await self.receiveLoop() }
        Task { await self.pingLoop() }
    }

    var isClosed: Bool { closed }

    func close() {
        guard !closed else { return }
        try? sendNow(["_tag": "Eof"])
        task.cancel(with: .normalClosure, reason: nil)
        finish(with: nil)
    }

    /// A unary call; resolves with the `Exit.Success` value.
    func call(_ tag: String, _ payload: JSON = [:], timeout: Duration = .seconds(30)) async throws -> JSON {
        guard !closed else { throw RPCError.disconnected }
        let id = allocateId()
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(id: id, error: .timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = .unary(continuation)
            do {
                try sendNow(request(id: id, tag: tag, payload: payload))
            } catch {
                pending[id] = nil
                continuation.resume(throwing: RPCError.disconnected)
            }
        }
    }

    /// A streaming call. Cancelling the consumer interrupts the server-side handler.
    nonisolated func stream(_ tag: String, _ payload: JSON = [:]) -> AsyncThrowingStream<JSON, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            // Installed synchronously so a consumer that cancels before the request is even
            // sent is still seen; the id arrives later from the actor.
            let handle = StreamHandle()
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let id = handle.cancel() else { return }
                Task { await self?.interrupt(id: id) }
            }
            Task { await self.openStream(tag: tag, payload: payload, continuation: continuation, handle: handle) }
        }
    }

    private func openStream(tag: String, payload: JSON, continuation: AsyncThrowingStream<JSON, Error>.Continuation,
                            handle: StreamHandle) {
        guard !closed else {
            continuation.finish(throwing: RPCError.disconnected)
            return
        }
        let id = allocateId()
        guard handle.assign(id) else { return }  // already cancelled; never send it
        pending[id] = .stream(continuation)
        do {
            try sendNow(request(id: id, tag: tag, payload: payload))
        } catch {
            pending[id] = nil
            continuation.finish(throwing: RPCError.disconnected)
        }
    }

    private func interrupt(id: Int) {
        guard pending.removeValue(forKey: id) != nil, !closed else { return }
        try? sendNow(["_tag": "Interrupt", "requestId": .number(Double(id))])
    }

    private func allocateId() -> Int {
        defer { nextId += 1 }
        return nextId
    }

    private func request(id: Int, tag: String, payload: JSON) -> JSON {
        ["_tag": "Request", "id": .number(Double(id)), "tag": .string(tag), "payload": payload, "headers": []]
    }

    private func sendNow(_ message: JSON) throws {
        let data = try message.data()
        let text = String(decoding: data, as: UTF8.self)
        task.send(.string(text)) { [weak self] error in
            guard let error, let self else { return }
            Task { await self.finish(with: error) }
        }
    }

    private func fail(id: Int, error: RPCError) {
        switch pending.removeValue(forKey: id) {
        case .unary(let c): c.resume(throwing: error)
        case .stream(let c): c.finish(throwing: error)
        case nil: break
        }
    }

    private func receiveLoop() async {
        while !closed {
            do {
                let message = try await task.receive()
                let data: Data = switch message {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: Data()
                }
                missedPongs = 0  // any frame proves the socket is alive (big snapshots delay Pongs)
                let json = try JSON.parse(data)
                if let batch = json.array {
                    batch.forEach(handle)
                } else {
                    handle(json)
                }
            } catch {
                finish(with: error)
                return
            }
        }
    }

    private func pingLoop() async {
        while !closed {
            try? await Task.sleep(for: .seconds(5))
            guard !closed else { return }
            missedPongs += 1
            if missedPongs > 3 {
                closeDetail = "no frames for \(missedPongs * 5) s"
                task.cancel(with: .goingAway, reason: nil)
                finish(with: RPCError.timedOut)
                return
            }
            try? sendNow(["_tag": "Ping"])
        }
    }

    private func handle(_ message: JSON) {
        switch message["_tag"]?.string {
        case "Pong":
            missedPongs = 0
        case "Chunk":
            guard let id = message["requestId"]?.int else { return }
            if case .stream(let continuation) = pending[id] {
                for value in message["values"]?.array ?? [] { continuation.yield(value) }
                try? sendNow(["_tag": "Ack", "requestId": .number(Double(id))])
            }
        case "Exit":
            guard let id = message["requestId"]?.int, let exit = message["exit"] else { return }
            let entry = pending.removeValue(forKey: id)
            if exit["_tag"]?.string == "Success" {
                switch entry {
                case .unary(let c): c.resume(returning: exit["value"] ?? .null)
                case .stream(let c): c.finish()
                case nil: break
                }
            } else {
                let error = RPCError.from(cause: exit["cause"])
                switch entry {
                case .unary(let c): c.resume(throwing: error)
                case .stream(let c): c.finish(throwing: error)
                case nil: break
                }
            }
        case "Defect":
            let defect = message["defect"]
            task.cancel(with: .internalServerError, reason: nil)
            finish(with: RPCError.defect(defect?["message"]?.string ?? defect?.string ?? "Connection defect"))
        default:
            break
        }
    }

    private func finish(with error: Error?) {
        guard !closed else { return }
        closed = true
        if closeDetail.isEmpty, task.closeCode != .invalid {
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            closeDetail = "close code \(task.closeCode.rawValue)" + (reason.isEmpty ? "" : " \(reason)")
        }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            closeDetail += (closeDetail.isEmpty ? "" : ", ") + "handshake HTTP \(response.statusCode)"
        }
        task.cancel(with: .goingAway, reason: nil)
        let failure: RPCError = (error as? RPCError) ?? .disconnected
        for (_, entry) in pending {
            switch entry {
            case .unary(let c): c.resume(throwing: failure)
            case .stream(let c): c.finish(throwing: failure)
            }
        }
        pending.removeAll()
        onClose?(error)
        onClose = nil
    }
}

/// Links a stream's synchronous termination handler with the request id the actor assigns.
private final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var id: Int?
    private var cancelled = false

    /// Returns false when the consumer already went away.
    func assign(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.id = id
        return true
    }

    /// Marks the stream cancelled; returns the id to interrupt if the request was sent.
    func cancel() -> Int? {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        return id
    }
}
