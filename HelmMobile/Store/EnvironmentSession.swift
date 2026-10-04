import Foundation
import Observation

/// One paired Helm server: keeps a socket open (reconnecting with backoff), holds the server
/// config and the shell (projects + thread list), and hands out thread subscriptions.
@MainActor
@Observable
final class EnvironmentSession: Identifiable {
    enum Status: Equatable {
        case connecting
        case live
        case offline(String)
        /// The bearer was revoked or expired; the user has to pair again.
        case unauthorized
    }

    nonisolated let id: String
    private(set) var saved: SavedEnvironment
    private(set) var status: Status = .connecting
    private(set) var config: ServerConfig?
    private(set) var shell = ShellState()
    private(set) var lastConnectedAt: Date?

    @ObservationIgnored private var connection: RPCConnection?
    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var streams: [Task<Void, Never>] = []
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var threads: [String: WeakThread] = [:]
    @ObservationIgnored private var projectionCache: [String: ThreadProjection] = [:]

    private struct WeakThread { weak var value: ThreadSession? }

    init(saved: SavedEnvironment) {
        id = saved.id
        self.saved = saved
    }

    var label: String { config?.label ?? saved.label }
    var http: HelmHTTP { HelmHTTP(baseURL: saved.baseURL, token: Keychain.token(for: saved.id)) }
    var isLive: Bool { status == .live }

    // MARK: Lifecycle

    func start() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in await self?.superviseLoop() }
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        teardown()
        wake?.resume()
        wake = nil
    }

    /// Called when the app comes back to the foreground: sockets rarely survive suspension, so
    /// check quickly and reconnect instead of waiting for missed pongs.
    func refreshAfterForeground() async {
        guard let connection, status == .live else {
            wakeSupervisor()
            return
        }
        do {
            // `server.probe` only exists on servers that advertise it.
            let method = config?.capability("connectionProbe") == true ? "server.probe" : "server.getConfig"
            _ = try await connection.call(method, [:], timeout: .seconds(4))
        } catch {
            await connection.close()
        }
    }

    func reconnectNow() {
        if case .unauthorized = status { return }
        wakeSupervisor()
    }

    private func wakeSupervisor() {
        wakeTimer?.cancel()
        wakeTimer = nil
        wake?.resume()
        wake = nil
    }

    @ObservationIgnored private var wakeTimer: Task<Void, Never>?

    private func superviseLoop() async {
        var delay: Double = 1
        while !Task.isCancelled {
            status = .connecting
            do {
                try await connectOnce()
                delay = 1
                status = .live
                lastConnectedAt = Date()
                await waitForClose()
                teardown()
                if Task.isCancelled { return }
                status = .offline(String(localized: "Connection lost"))
            } catch HelmHTTPError.status(401, _) {
                teardown()
                status = .unauthorized
                return
            } catch {
                teardown()
                status = .offline(error.localizedDescription)
            }
            // Back off with jitter, but wake early on foreground or an explicit retry.
            let wait = delay * Double.random(in: 0.8...1.2)
            delay = min(delay * 2, 10)
            await sleepOrWake(seconds: wait)
        }
    }

    private func sleepOrWake(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake = continuation
            wakeTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.wakeSupervisor()
            }
        }
    }

    @ObservationIgnored private var closeContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var connectionClosed = false

    private func waitForClose() async {
        guard !connectionClosed else { return }
        await withCheckedContinuation { continuation in
            closeContinuation = continuation
        }
    }

    private func markClosed(_ closed: RPCConnection) {
        guard closed === connection else { return }
        connectionClosed = true
        closeContinuation?.resume()
        closeContinuation = nil
    }

    private func teardown() {
        streams.forEach { $0.cancel() }
        streams.removeAll()
        if let connection {
            Task { await connection.close() }
        }
        connection = nil
        closeContinuation?.resume()
        closeContinuation = nil
    }

    private func connectOnce() async throws {
        let http = self.http
        guard http.token != nil else { throw HelmHTTPError.status(401, "missing token") }
        let ticket = try await http.webSocketTicket()
        let url = await http.webSocketURL(ticket: ticket)
        let connection = RPCConnection(url: url)
        self.connection = connection
        connectionClosed = false
        await connection.start { [weak self] _ in
            Task { @MainActor in self?.markClosed(connection) }
        }

        // The config snapshot comes first; everything else depends on it.
        let configStream = connection.stream("subscribeServerConfig", [:])
        let config: ServerConfig = try await withCheckedThrowingContinuation { continuation in
            streams.append(Task { [weak self] in
                var resumed = false
                do {
                    for try await event in configStream {
                        if !resumed {
                            resumed = true
                            if let snapshot = event["config"], let config = ServerConfig(json: snapshot) {
                                continuation.resume(returning: config)
                            } else {
                                continuation.resume(throwing: RPCError.defect("No server config"))
                            }
                            continue
                        }
                        self?.applyConfigEvent(event)
                    }
                    if !resumed { continuation.resume(throwing: RPCError.disconnected) }
                } catch {
                    if !resumed { continuation.resume(throwing: error) }
                }
                await self?.streamEnded(on: connection)
            })
        }
        guard config.environmentId == saved.id else {
            throw RPCError.defect(String(localized: "This address now belongs to a different Helm server."))
        }
        self.config = config
        if saved.label != config.label {
            saved.label = config.label
            AppModel.persistLabel(id: id, label: config.label)
        }

        var shellPayload: [String: JSON] = [:]
        if config.shellResumeCompletionMarker { shellPayload["requestCompletionMarker"] = true }
        if shell.sequence > 0 { shellPayload["afterSequence"] = .number(Double(shell.sequence)) }
        let shellStream = connection.stream("orchestration.subscribeShell", .object(shellPayload))
        streams.append(Task { [weak self] in
            do {
                for try await item in shellStream {
                    self?.shell.apply(item)
                    self?.resolveProjectWaiters()
                }
            } catch {}
            await self?.streamEnded(on: connection)
        })

        for (key, weakThread) in threads {
            if let thread = weakThread.value {
                thread.subscribe(on: connection)
            } else {
                threads[key] = nil
            }
        }
    }

    /// The config and shell streams live as long as the socket. If one ends while the socket
    /// is still up (a server-side failure), reconnect rather than show frozen data as "live".
    private func streamEnded(on ended: RPCConnection) async {
        guard ended === connection, !Task.isCancelled else { return }
        await ended.close()
    }

    private func applyConfigEvent(_ event: JSON) {
        switch event["type"]?.string {
        case "snapshot":
            if let snapshot = event["config"], let next = ServerConfig(json: snapshot) { config = next }
        case "providerStatuses":
            if let list = event["payload"]?["providers"]?.array {
                config?.providers = list.compactMap(Provider.init(json:))
            }
        case "settingsUpdated":
            if let settings = event["payload"]?["settings"] {
                config?.defaultModelSelection = ModelSelection(json: settings["defaultModelSelection"]?.nonNull)
                config?.defaultRuntimeMode = settings["defaultRuntimeMode"]?.string ?? config?.defaultRuntimeMode ?? "full-access"
                config?.applySettings(settings)
            }
        default:
            break
        }
    }

    // MARK: Threads

    /// A live subscription for a thread view. Kept while the view holds it.
    func threadSession(_ threadId: String) -> ThreadSession {
        if let existing = threads[threadId]?.value { return existing }
        let session = ThreadSession(threadId: threadId, environment: self, cached: projectionCache[threadId])
        threads[threadId] = WeakThread(value: session)
        if let connection { session.subscribe(on: connection) }
        return session
    }

    func cache(_ projection: ThreadProjection) {
        let id = projection.thread.id
        projectionCache[id] = projection
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > 30 { projectionCache[cacheOrder.removeFirst()] = nil }
    }

    @ObservationIgnored private var cacheOrder: [String] = []

    /// The live connection, for thread sessions that need to resubscribe on their own.
    var currentConnection: RPCConnection? { status == .live ? connection : nil }

    // MARK: Calls

    func call(_ tag: String, _ payload: JSON = [:], timeout: Duration = .seconds(30)) async throws -> JSON {
        guard let connection, status == .live else { throw RPCError.disconnected }
        return try await connection.call(tag, payload, timeout: timeout)
    }

    /// A server stream on the live socket; it ends when the socket does.
    func stream(_ tag: String, _ payload: JSON = [:]) throws -> AsyncThrowingStream<JSON, Error> {
        guard let connection, status == .live else { throw RPCError.disconnected }
        return connection.stream(tag, payload)
    }

    /// `orchestration.dispatchCommand`. `commandId` is generated unless provided (retries reuse it).
    @discardableResult
    func dispatch(_ type: String, _ fields: [String: JSON], commandId: String = UUID().uuidString.lowercased()) async throws -> JSON {
        var command = fields
        command["type"] = .string(type)
        command["commandId"] = .string(commandId)
        return try await call("orchestration.dispatchCommand", .object(command))
    }

    @ObservationIgnored private var workspaceRefreshes: [String: Date] = [:]

    /// Asks the provider to scan a workspace's own skills and slash commands
    /// (`server.refreshProviders {instanceId, cwd}`), once per provider and cwd, retrying after 10 s.
    func refreshProviderWorkspace(instanceId: String, cwd: String) async {
        guard config?.provider(instanceId)?.hasSnapshot(cwd: cwd) == false else { return }
        let key = "\(instanceId)|\(cwd)"
        if let last = workspaceRefreshes[key], Date().timeIntervalSince(last) < 10 { return }
        workspaceRefreshes[key] = Date()
        guard let result = try? await call("server.refreshProviders", [
            "instanceId": .string(instanceId), "cwd": .string(cwd),
        ], timeout: .seconds(30)), let list = result["providers"]?.array else { return }
        for provider in list.compactMap(Provider.init(json:)) {
            if let index = config?.providers.firstIndex(where: { $0.instanceId == provider.instanceId }) {
                config?.providers[index] = provider
            }
        }
    }

    func project(_ id: String?) -> Project? { id.flatMap { shell.projects[$0] } }

    /// A project the server just created reaches the shell a moment after the RPC answers.
    /// Waits for it to arrive, or nil after `timeout`.
    func waitForProject(_ projectId: String, timeout: Duration = .seconds(15)) async -> Project? {
        if let project = shell.projects[projectId] { return project }
        let token = UUID()
        return await withCheckedContinuation { continuation in
            projectWaiters.append(ProjectWaiter(token: token, projectId: projectId, continuation: continuation))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeProjectWaiter(token, with: nil)
            }
        }
    }

    private struct ProjectWaiter {
        var token: UUID
        var projectId: String
        var continuation: CheckedContinuation<Project?, Never>
    }

    @ObservationIgnored private var projectWaiters: [ProjectWaiter] = []

    private func resolveProjectWaiters() {
        for waiter in projectWaiters {
            if let project = shell.projects[waiter.projectId] { resumeProjectWaiter(waiter.token, with: project) }
        }
    }

    private func resumeProjectWaiter(_ token: UUID, with project: Project?) {
        guard let index = projectWaiters.firstIndex(where: { $0.token == token }) else { return }
        projectWaiters.remove(at: index).continuation.resume(returning: project)
    }

    func thread(_ id: String) -> ThreadSummary? { shell.threads[id] }

    /// Shows a reorder write in the list before the server confirms it.
    func setPendingOrderKey(threadId: String, pinned: Bool, key: String) {
        shell.setPendingOrderKey(threadId: threadId, pinned: pinned, key: key)
    }

    func revertPendingOrderKey(threadId: String) {
        shell.revertPendingOrderKey(threadId: threadId)
    }
}
