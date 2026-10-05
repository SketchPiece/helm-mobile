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
    /// Themes this Mac publishes (`<state>/themes/*.json`), for Settings → Appearance.
    private(set) var themes: [HelmTheme] = []
    /// When the thread list on screen was last in step with the server: set while it is a copy
    /// saved on this phone or the connection is down, nil while it is live.
    private(set) var shellSavedAt: Date?

    /// Called each time the socket comes up with a fresh config (the app refreshes the widget).
    @ObservationIgnored var onLive: (() -> Void)?
    @ObservationIgnored private var connection: RPCConnection?
    @ObservationIgnored private var supervisor: Task<Void, Never>?
    @ObservationIgnored private var streams: [Task<Void, Never>] = []
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var threads: [String: WeakThread] = [:]
    @ObservationIgnored private var projectionCache: [String: CachedProjection] = [:]
    @ObservationIgnored private var shellDirty = false
    @ObservationIgnored private var shellSave: Task<Void, Never>?

    struct CachedProjection {
        var projection: ThreadProjection
        /// When it was last in step with the server.
        var savedAt: Date
    }

    private struct WeakThread { weak var value: ThreadSession? }

    init(saved: SavedEnvironment) {
        id = saved.id
        self.saved = saved
    }

    var label: String { config?.label ?? saved.label }
    var http: HelmHTTP { HelmHTTP(baseURL: saved.baseURL, token: Keychain.token(for: saved.id)) }
    var isLive: Bool { status == .live }

    var logStatus: String {
        switch status {
        case .connecting: "connecting"
        case .live: "live"
        case .offline(let reason): "offline (\(reason))"
        case .unauthorized: "unauthorized"
        }
    }

    // MARK: Lifecycle

    func start() {
        guard supervisor == nil else { return }
        log("start, address \(saved.baseURL.absoluteString)")
        restoreShell()
        supervisor = Task { [weak self] in await self?.superviseLoop() }
    }

    func stop() {
        log("stop")
        supervisor?.cancel()
        supervisor = nil
        saveShell()
        teardown()
        wake?.resume()
        wake = nil
    }

    /// Called when the app comes back to the foreground: sockets rarely survive suspension, so
    /// check quickly and reconnect instead of waiting for missed pongs.
    func refreshAfterForeground(reason: String = "foreground") async {
        guard let connection, status == .live else {
            reconnectNow(reason: reason)
            return
        }
        let started = ContinuousClock.now
        do {
            // `server.probe` only exists on servers that advertise it.
            let method = config?.capability("connectionProbe") == true ? "server.probe" : "server.getConfig"
            _ = try await connection.call(method, [:], timeout: .seconds(4))
        } catch {
            log("\(reason): live socket did not answer (\(ConnectionLog.describe(error)), \(Self.elapsed(since: started))), reconnecting")
            await connection.close()
        }
    }

    func reconnectNow(reason: String = "retry") {
        if case .unauthorized = status { return }
        if wake == nil, status != .live {
            // An attempt is under way: don't let the request vanish. If it fails, the next one
            // starts right away instead of after the backoff.
            log("\(reason): attempt already in progress, will retry at once if it fails")
            wakeRequested = true
        } else if wake != nil {
            log("\(reason): retrying now")
        }
        backoff = 1
        wakeSupervisor()
    }

    private func wakeSupervisor() {
        wakeTimer?.cancel()
        wakeTimer = nil
        wake?.resume()
        wake = nil
    }

    @ObservationIgnored private var wakeTimer: Task<Void, Never>?
    /// A retry was asked for while an attempt was running.
    @ObservationIgnored private var wakeRequested = false
    @ObservationIgnored private var backoff: Double = 1
    @ObservationIgnored private var attempt = 0

    private func log(_ message: String) { ConnectionLog.shared.log(label, message) }

    private static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        return ms < 10_000 ? "\(ms) ms" : "\(ms / 1000) s"
    }

    private func superviseLoop() async {
        while !Task.isCancelled {
            status = .connecting
            attempt += 1
            wakeRequested = false
            let started = ContinuousClock.now
            log("attempt \(attempt) → \(saved.baseURL.absoluteString)")
            do {
                try await connectOnce()
                backoff = 1
                status = .live
                log("connected (attempt \(attempt), \(Self.elapsed(since: started)))")
                lastConnectedAt = Date()
                if shell.isFromServer { shellSavedAt = nil }
                onLive?()
                let liveSince = ContinuousClock.now
                await waitForClose()
                wentOffline()
                let detail = await connection?.closeDetail ?? ""
                log("connection lost after \(Self.elapsed(since: liveSince))" + (detail.isEmpty ? "" : " (\(detail))"))
                teardown()
                if Task.isCancelled { return }
                status = .offline(String(localized: "Connection lost"))
            } catch HelmHTTPError.status(401, _) {
                log("attempt \(attempt): not authorized (401), pairing needed")
                teardown()
                status = .unauthorized
                return
            } catch {
                let detail = await connection?.closeDetail ?? ""
                log("attempt \(attempt) failed after \(Self.elapsed(since: started)): \(ConnectionLog.describe(error))"
                    + (detail.isEmpty ? "" : " (\(detail))"))
                teardown()
                status = .offline(error.localizedDescription)
            }
            if Task.isCancelled { return }
            if wakeRequested {
                wakeRequested = false
                continue
            }
            // Back off with jitter, but wake early on foreground or an explicit retry.
            let wait = backoff * Double.random(in: 0.8...1.2)
            backoff = min(backoff * 2, 10)
            log(String(format: "next attempt in %.1f s", wait))
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
        if TailnetRouting.usesNode(saved.baseURL), !TailnetNode.shared.isRunning() {
            // Just launched: the built-in Tailscale node is still coming up and would refuse
            // the connection. Wait for it rather than fail into the backoff.
            let waitStarted = ContinuousClock.now
            log("waiting for the built-in Tailscale node")
            let running = await TailnetRouting.waitForNode(timeout: .seconds(12))
            log(running ? "Tailscale node ready after \(Self.elapsed(since: waitStarted))"
                        : "Tailscale node still not running after \(Self.elapsed(since: waitStarted)), trying anyway")
        }
        var step = ContinuousClock.now
        let ticket = try await http.webSocketTicket()
        let url = await http.webSocketURL(ticket: ticket)
        log("ticket in \(Self.elapsed(since: step)), opening socket via \(HelmHTTP.logHost(url))"
            + (TailnetRouting.usesNode(saved.baseURL) ? " (built-in Tailscale)" : ""))
        step = ContinuousClock.now
        let connection = RPCConnection(url: url)
        self.connection = connection
        connectionClosed = false
        configTimedOut = false
        await connection.start { [weak self] error in
            Task { @MainActor in
                if let error, let self, connection === self.connection, self.status == .live {
                    self.log("socket closed: \(ConnectionLog.describe(error))")
                }
                self?.markClosed(connection)
            }
        }
        // A socket that opens but never answers would otherwise hang here until the pings give up.
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.connection === connection, self.status == .connecting else { return }
            self.log("no server config 15 s after opening the socket, giving up on this attempt")
            self.configTimedOut = true
            await connection.close()
        }
        defer { watchdog.cancel() }

        // The config snapshot comes first; everything else depends on it.
        // Opting in to themes adds `environmentThemesUpdated` events (decoded below).
        let configStream = connection.stream("subscribeServerConfig", ["environmentThemes": true])
        let config: ServerConfig
        do {
            config = try await firstConfig(configStream, on: connection)
        } catch {
            throw configTimedOut ? RPCError.timedOut : error
        }
        log("server config in \(Self.elapsed(since: step)) (Helm \(config.serverVersion ?? "?"))")
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
        // Resume only from a list this session got from the server; a saved one gets a fresh snapshot.
        if shell.isFromServer, shell.sequence > 0 { shellPayload["afterSequence"] = .number(Double(shell.sequence)) }
        let shellStream = connection.stream("orchestration.subscribeShell", .object(shellPayload))
        streams.append(Task { [weak self] in
            do {
                for try await item in shellStream {
                    self?.applyShell(item)
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

    /// Waits for the config snapshot; the rest of the stream keeps applying updates.
    private func firstConfig(_ configStream: AsyncThrowingStream<JSON, Error>, on connection: RPCConnection) async throws -> ServerConfig {
        try await withCheckedThrowingContinuation { continuation in
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
    }

    @ObservationIgnored private var configTimedOut = false

    /// The config and shell streams live as long as the socket. If one ends while the socket
    /// is still up (a server-side failure), reconnect rather than show frozen data as "live".
    private func streamEnded(on ended: RPCConnection) async {
        guard ended === connection, !Task.isCancelled else { return }
        await ended.close()
    }

    // MARK: Local cache

    /// Shows the list saved on this phone until the server's own arrives.
    private func restoreShell() {
        guard !AppModel.isUnitTestHost else { return }
        Task { [weak self, id] in
            guard let saved = await LocalCache.shared.shell(environmentId: id) else { return }
            guard let self, !self.shell.isFromServer, self.shell.threads.isEmpty, self.shell.projects.isEmpty else { return }
            self.shell = saved.shell
            self.shellSavedAt = saved.savedAt
        }
    }

    private func applyShell(_ item: JSON) {
        let replaced = shell.apply(item)
        guard shell.isFromServer else { return }
        if replaced {
            shellSavedAt = nil
            LocalCache.shared.keepThreads(Set(shell.threads.keys), environmentId: id)
        }
        if item["kind"]?.string == "thread.removed", let threadId = item["threadId"]?.string {
            forgetThread(threadId)
        }
        shellDirty = true
        shellSave = shellSave ?? Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.shellSave = nil
            self?.saveShell()
        }
    }

    /// Writes the list if it changed. Only ever a list that came from the server.
    private func saveShell() {
        shellSave?.cancel()
        shellSave = nil
        guard shellDirty, shell.isFromServer else { return }
        shellDirty = false
        LocalCache.shared.saveShell(shell, environmentId: id, savedAt: shellSavedAt ?? Date())
    }

    /// The socket closed: what is on screen was current until now.
    private func wentOffline() {
        if shell.isFromServer, shellSavedAt == nil { shellSavedAt = Date() }
        saveShell()
    }

    /// Writes everything that changed now, e.g. on the way to the background.
    func saveToDisk() {
        saveShell()
        for weakThread in threads.values { weakThread.value?.saveToDisk() }
    }

    /// A deleted thread: nothing to show for it any more.
    func forgetThread(_ threadId: String) {
        projectionCache[threadId] = nil
        cacheOrder.removeAll { $0 == threadId }
        LocalCache.shared.removeThread(threadId, environmentId: id)
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
        case "environmentThemesUpdated":
            themes = HelmTheme.published(event["payload"]?["themes"] ?? [], source: label)
            ThemeStore.shared.update(from: themes)
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

    /// Keeps a projection in memory for the next time the thread opens.
    func cache(_ projection: ThreadProjection, savedAt: Date = Date()) {
        let id = projection.thread.id
        projectionCache[id] = CachedProjection(projection: projection, savedAt: savedAt)
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > 30 { projectionCache[cacheOrder.removeFirst()] = nil }
    }

    @ObservationIgnored private var cacheOrder: [String] = []

    /// An older page of a thread's timeline (`OrchestrationV2ThreadHistoryPage`), over HTTP.
    func threadHistoryPage(threadId: String, cursor: String) async throws -> JSON {
        try await http.threadHistoryPage(threadId: threadId, cursor: cursor)
    }

    /// The live connection, for thread sessions that need to resubscribe on their own.
    var currentConnection: RPCConnection? { status == .live ? connection : nil }

    // MARK: Calls

    func call(_ tag: String, _ payload: JSON = [:], timeout: Duration = .seconds(30)) async throws -> JSON {
        guard let connection, status == .live else { throw RPCError.disconnected }
        return try await connection.call(tag, payload, timeout: timeout)
    }

    /// Waits for the socket to come (back) up, e.g. right after returning from another app.
    /// Throws `RPCError.disconnected` when it doesn't within `timeout` or pairing was revoked.
    func waitUntilLive(timeout: Duration = .seconds(15)) async throws {
        if status == .live { return }
        reconnectNow(reason: "a request is waiting for the connection")
        let deadline = ContinuousClock.now + timeout
        while status != .live {
            if status == .unauthorized || ContinuousClock.now >= deadline { throw RPCError.disconnected }
            try await Task.sleep(for: .milliseconds(200))
        }
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

    /// `server.refreshProviders {}`: probes every provider again, usage limits included, and
    /// replaces the catalog with the answer (the config stream would deliver it a moment later).
    func refreshProviders() async throws {
        let result = try await call("server.refreshProviders", [:], timeout: .seconds(45))
        if let list = result["providers"]?.array { config?.providers = list.compactMap(Provider.init(json:)) }
    }

    /// `server.getUsageSummary` for a window from `Usage.window(days:)`. Scans transcripts, so it can be slow.
    func usageSummary(_ window: JSON) async throws -> Usage.Summary {
        Usage.Summary(json: try await call("server.getUsageSummary", window, timeout: .seconds(90)))
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

    /// Shows a settle, reopen, snooze or wake in the list before the server confirms it.
    func setPendingShelfMove(threadId: String, _ move: ShellState.ShelfMove) {
        shell.setPendingShelfMove(threadId: threadId, move)
    }

    func revertPendingShelfMove(threadId: String) {
        shell.revertPendingShelfMove(threadId: threadId)
    }
}
