import Foundation
import Observation
import WatchConnectivity
import WatchKit
import os

private let log = Logger(subsystem: "com.sketchpiece.helm.watch", category: "store")

/// The watch's side of the bridge: the thread list the phone last sent, the threads open on the
/// watch, and requests to the phone. Everything goes through Helm on the iPhone.
@MainActor
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    private(set) var snapshot: WatchSnapshot = .empty
    private(set) var details: [String: WatchThreadDetail] = [:]
    private(set) var isReachable = false
    private(set) var isActivated = false
    /// A refresh is on its way.
    private(set) var isRefreshing = false
    private(set) var refreshError: String?

    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private let savedKey = "watch.snapshot"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: savedKey),
           let saved = WatchCoding.decode(WatchSnapshot.self, from: [WatchKey.payload: data])
        {
            snapshot = saved
        }
    }

    func activate() {
        if let demo = WatchDemo.snapshotIfRequested() {
            snapshot = demo
            details = WatchDemo.details
            isReachable = true
            isActivated = true
            return
        }
        guard WCSession.isSupported(), session == nil else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    var isDemo: Bool { WatchDemo.isOn }

    // MARK: Snapshot

    func refresh() async {
        guard !isDemo else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let reply = await request(.snapshot)
        if let snapshot = reply.snapshot {
            accept(snapshot)
            refreshError = nil
        } else {
            refreshError = reply.error
        }
    }

    fileprivate func accept(_ snapshot: WatchSnapshot) {
        guard snapshot.updatedAt >= self.snapshot.updatedAt || self.snapshot.updatedAt == .distantPast else { return }
        self.snapshot = snapshot
        if let data = WatchCoding.encode(snapshot)[WatchKey.payload] as? Data {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }

    fileprivate func accept(_ detail: WatchThreadDetail) {
        details[detail.thread.id] = detail
        // The list row follows what the open thread shows.
        if let index = snapshot.threads.firstIndex(where: { $0.id == detail.thread.id }) {
            snapshot.threads[index] = detail.thread
        }
    }

    func thread(_ id: String) -> WatchThread? {
        details[id]?.thread ?? snapshot.threads.first { $0.id == id }
    }

    // MARK: Threads

    /// `id` is `WatchThread.id` ("environment|thread"); a thread just started isn't in the list yet.
    func open(_ id: String) async {
        guard !isDemo, let ref = Self.ref(id) else { return }
        let reply = await request(.open(environmentId: ref.environmentId, threadId: ref.threadId))
        if let detail = reply.detail { accept(detail) }
    }

    func close(_ id: String) {
        guard !isDemo, let ref = Self.ref(id) else { return }
        Task { _ = await request(.close(environmentId: ref.environmentId, threadId: ref.threadId)) }
    }

    private static func ref(_ id: String) -> (environmentId: String, threadId: String)? {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Sends an action and plays a haptic for how it went. Returns the error to show, if any.
    @discardableResult
    func perform(_ message: WatchRequestMessage) async -> WatchReply {
        if isDemo {
            try? await Task.sleep(for: .milliseconds(500))
            WKInterfaceDevice.current().play(.success)
            return .success
        }
        let reply = await request(message)
        log.info("perform \(String(describing: message), privacy: .public): ok \(reply.ok) \(reply.error ?? "", privacy: .public)")
        WKInterfaceDevice.current().play(reply.ok ? .success : .failure)
        return reply
    }

    private func request(_ message: WatchRequestMessage) async -> WatchReply {
        guard let session, session.activationState == .activated else {
            return .failure(String(localized: "Connecting to iPhone…"))
        }
        guard session.isReachable else {
            return .failure(String(localized: "iPhone isn't reachable."))
        }
        return await Self.send(WatchCoding.encode(message))
    }

    /// Off the main actor: WatchConnectivity calls the handlers on its own queue.
    private nonisolated static func send(_ payload: [String: Any]) async -> WatchReply {
        let session = WCSession.default
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            session.sendMessage(payload, replyHandler: { @Sendable reply in
                once.resume(WatchCoding.decode(WatchReply.self, from: reply) ?? .failure(String(localized: "The iPhone sent something unexpected.")))
            }, errorHandler: { @Sendable error in
                once.resume(.failure(error.localizedDescription))
            })
        }
    }

    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<WatchReply, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<WatchReply, Never>) { self.continuation = continuation }
        func resume(_ reply: WatchReply) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: reply)
        }
    }

    fileprivate func sessionChanged(activated: Bool, reachable: Bool) {
        isActivated = activated
        isReachable = reachable
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let context = WatchCoding.decode(WatchSnapshot.self, from: session.receivedApplicationContext)
        let (activated, reachable) = (activationState == .activated, session.isReachable)
        Task { @MainActor in
            self.sessionChanged(activated: activated, reachable: reachable)
            if let context { self.accept(context) }
            await self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let (activated, reachable) = (session.activationState == .activated, session.isReachable)
        Task { @MainActor in
            self.sessionChanged(activated: activated, reachable: reachable)
            if reachable { await self.refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = WatchCoding.decode(WatchSnapshot.self, from: applicationContext) else { return }
        Task { @MainActor in self.accept(snapshot) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let push = WatchCoding.decode(WatchPush.self, from: message) else { return }
        Task { @MainActor in
            switch push {
            case .snapshot(let snapshot): self.accept(snapshot)
            case .detail(let detail): self.accept(detail)
            }
        }
    }
}
