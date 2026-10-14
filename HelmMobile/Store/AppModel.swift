import Foundation
import Network
import Observation
import SwiftUI
import UIKit

/// Identifies a thread across environments.
struct ThreadRef: Hashable, Codable, Sendable {
    var environmentId: String
    var threadId: String
}

/// A thread open in Helm on a Mac nearby, for the remote on Home.
struct MacRemoteTarget: Equatable {
    var ref: ThreadRef
    var macLabel: String
    /// The computer shows a new thread not sent yet, in this project: there is nothing to follow
    /// or send to, only its composer to type and add pictures into.
    var draftProjectId: String?
}

/// A thread row with what the list needs to draw it.
struct ThreadListEntry: Identifiable, Hashable {
    var ref: ThreadRef
    var thread: ThreadSummary
    var project: Project?
    var environmentLabel: String
    var id: ThreadRef { ref }
}

@MainActor
@Observable
final class AppModel {
    private(set) var environments: [EnvironmentSession] = []
    let tailscale = TailscaleService()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init() {
        environments = SavedEnvironments.load().map(EnvironmentSession.init(saved:))
        // As the unit-test host the app stays idle: no sockets, no Tailscale, so the test runner
        // attaches to a quiet main thread.
        guard !Self.isUnitTestHost else { return }
        environments.forEach(adopt)
        Drafts.shared.onLocalChange = { [weak self] key in self?.draftEdited(key) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        ConnectionLog.shared.log("app", "launch \(version) (\(build)), \(environments.count) computer(s), built-in Tailscale \(TailnetNode.shared.hasState ? "set up" : "not set up")")
        tailscale.startIfConfigured()
        tailscale.onRunning = { [weak self] in
            self?.environments.filter { !$0.isLive }.forEach { $0.reconnectNow(reason: "Tailscale node running") }
        }
        environments.forEach { $0.start() }
        NearbyMacs.shared.start()
        // A new network path (Wi-Fi ↔ cellular, Tailscale toggled) is the moment a dropped
        // connection can come back; don't wait for the backoff timer.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            ConnectionLog.shared.log("network", Self.describe(path))
            guard path.status == .satisfied else { return }
            TailnetNode.shared.networkChanged()
            Task { @MainActor in
                // Live sockets may be bound to the old interface: probe them; wake the rest.
                for environment in self?.environments ?? [] {
                    Task { await environment.refreshAfterForeground(reason: "network changed") }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "helm.path"))
    }

    nonisolated private static func describe(_ path: NWPath) -> String {
        let status = switch path.status {
        case .satisfied: "online"
        case .unsatisfied: "offline"
        case .requiresConnection: "needs a connection"
        @unknown default: "unknown"
        }
        let kinds: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "ethernet"), (.other, "other/VPN"),
        ]
        let using = kinds.filter { path.usesInterfaceType($0.0) }.map(\.1)
        var text = "path \(status)" + (using.isEmpty ? "" : " via \(using.joined(separator: "+"))")
        if path.isExpensive { text += ", expensive" }
        if path.isConstrained { text += ", low data mode" }
        return text
    }

    nonisolated static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var hasEnvironments: Bool { !environments.isEmpty }

    func environment(_ id: String) -> EnvironmentSession? { environments.first { $0.id == id } }

    /// A draft written on this phone goes to the Mac it belongs to.
    private func draftEdited(_ key: String) {
        guard let draft = Drafts.shared.draft(for: key) else { return }
        let environment = draft.environmentId.flatMap(environment) ?? environments.first { $0.thread(key) != nil }
        environment?.draftSync.schedule(key)
    }

    static func persistLabel(id: String, label: String) {
        var list = SavedEnvironments.load()
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].label = label
            SavedEnvironments.save(list)
        }
    }

    // MARK: Pairing

    /// Pairs with a server: checks the descriptor, trades the one-time code for a bearer and
    /// starts the session. Re-pairing an existing environment replaces its token and address.
    @discardableResult
    func pair(_ target: PairingTarget) async throws -> EnvironmentSession {
        let http = HelmHTTP(baseURL: target.baseURL, token: nil)
        let descriptor = try await http.descriptor()
        let token = try await http.exchange(code: target.code)
        Keychain.setToken(token, for: descriptor.environmentId)
        let saved = SavedEnvironment(
            id: descriptor.environmentId, label: descriptor.label, baseURL: target.baseURL, pairedAt: Date()
        )
        var list = SavedEnvironments.load().filter { $0.id != saved.id }
        list.append(saved)
        SavedEnvironments.save(list)
        if let existing = environment(saved.id) {
            existing.stop()
            environments.removeAll { $0.id == saved.id }
        }
        let session = EnvironmentSession(saved: saved)
        adopt(session)
        environments.append(session)
        session.start()
        return session
    }

    func remove(_ environment: EnvironmentSession) {
        environment.stop()
        environments.removeAll { $0.id == environment.id }
        SavedEnvironments.save(SavedEnvironments.load().filter { $0.id != environment.id })
        Keychain.setToken(nil, for: environment.id)
        LocalCache.shared.removeEnvironment(environment.id)
    }

    func foregrounded() {
        ConnectionLog.shared.log("app", "foreground: " + environments.map { "\($0.label) \($0.logStatus)" }.joined(separator: ", "))
        NearbyMacs.shared.start()
        for environment in environments {
            Task { await environment.refreshAfterForeground() }
        }
        Task { await UsageWidgetPublisher.shared.publish(from: environments) }
    }

    /// On the way to the background: what is on screen goes to disk, so the next cold start
    /// (or a dead connection) still shows it.
    func backgrounded() {
        ConnectionLog.shared.log("app", "background")
        NearbyMacs.shared.stop()
        environments.forEach { $0.saveToDisk() }
        Drafts.shared.saveNow()
        let task = UIApplication.shared.beginBackgroundTask(withName: "helm.local-cache")
        guard task != .invalid else { return }
        LocalCache.shared.flush {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// A Mac that just connected brings fresh limits for the Usage widget.
    private func adopt(_ environment: EnvironmentSession) {
        environment.onLive = { [weak self] in
            guard let self else { return }
            Task { await UsageWidgetPublisher.shared.publish(from: self.environments) }
        }
    }

    // MARK: Mac remote

    /// How long after the last sign of someone at the Mac its open thread is still offered:
    /// long enough to watch an agent work without touching the Mac.
    static let remoteLinger: TimeInterval = 15 * 60

    /// The thread Helm shows on a Mac on this phone's network, while someone is at that Mac.
    func macRemoteTarget(now: Date = Date()) -> MacRemoteTarget? {
        for environment in environments where environment.isLive && NearbyMacs.shared.contains(environment.id) {
            guard let desktop = environment.desktop, !desktop.macAway,
                  let inUseAt = environment.desktopInUseAt, now.timeIntervalSince(inUseAt) < Self.remoteLinger
            else { continue }
            // Once the new thread is sent the server has it, whatever the window still reports.
            let sent = environment.thread(desktop.threadId) != nil
            guard sent || desktop.draftProjectId != nil else { continue }
            return MacRemoteTarget(ref: ThreadRef(environmentId: environment.id, threadId: desktop.threadId),
                                   macLabel: environment.label, draftProjectId: sent ? nil : desktop.draftProjectId)
        }
        return nil
    }

    // MARK: Thread list

    /// Every view that lists threads asks for this, several times per update; it is built once per
    /// change of any computer's list (reading each `shell` still registers the view's dependency).
    func allThreads() -> [ThreadListEntry] {
        let key = environments.map { ThreadListKey(id: $0.id, revision: $0.shellRevision, label: $0.label, shell: $0.shell.sequence) }
        if let cached = threadListCache, cached.key == key { return cached.entries }
        let entries = Perf.measure("model.allThreads") { buildAllThreads() }
        threadListCache = (key, entries)
        return entries
    }

    private struct ThreadListKey: Equatable {
        var id: String
        var revision: Int
        var label: String
        var shell: Int
    }

    @ObservationIgnored private var threadListCache: (key: [ThreadListKey], entries: [ThreadListEntry])?

    private func buildAllThreads() -> [ThreadListEntry] {
        environments.flatMap { environment in
            environment.shell.threads.values.compactMap { thread -> ThreadListEntry? in
                guard !thread.isSubagent else { return nil }
                return ThreadListEntry(
                    ref: ThreadRef(environmentId: environment.id, threadId: thread.id),
                    thread: thread,
                    project: environment.shell.projects[thread.projectId],
                    environmentLabel: environment.label
                )
            }
        }
    }

    /// Projects across Macs, the latest worked in first, as the New thread fan has them: by their newest
    /// thread; projects without threads after those, by their own date.
    func allProjects() -> [(environment: EnvironmentSession, project: Project)] {
        var latest: [String: Date] = [:]
        for entry in allThreads() {
            let key = "\(entry.ref.environmentId)|\(entry.thread.projectId)"
            latest[key] = max(latest[key] ?? .distantPast, entry.thread.updatedAt ?? .distantPast)
        }
        let all = environments.flatMap { environment in
            environment.shell.projects.values.map { (environment: environment, project: $0, latest: latest["\(environment.id)|\($0.id)"]) }
        }
        return all.sorted { a, b in
            switch (a.latest, b.latest) {
            case let (a?, b?): a > b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): (a.project.updatedAt ?? .distantPast) > (b.project.updatedAt ?? .distantPast)
            }
        }
        .map { ($0.environment, $0.project) }
    }

    // MARK: Thread actions

    enum ThreadAction {
        case settle, unsettle, archive, unarchive, delete, unsnooze, pin, unpin, markUnread, regenerateTitle
        case snooze(Date)
        case rename(String)
        case autoSettle(Bool)
    }

    func perform(_ action: ThreadAction, on ref: ThreadRef) async throws {
        guard let environment = environment(ref.environmentId) else { return }
        // What the thread looked like before, for Undo.
        let before = environment.thread(ref.threadId)
        // A row that changes section moves out right away, animated, not when the server's echo lands.
        let shelfMove: ShellState.ShelfMove? = switch action {
        case .settle: .settle
        case .unsettle: .unsettle
        case .snooze(let date): .snooze(date)
        case .unsnooze: .unsnooze
        default: nil
        }
        if let shelfMove {
            withAnimation(.snappy(duration: 0.3)) { environment.setPendingShelfMove(threadId: ref.threadId, shelfMove) }
        }
        do {
            try await dispatch(action, on: ref.threadId, in: environment)
        } catch {
            if shelfMove != nil {
                withAnimation(.snappy(duration: 0.3)) { environment.revertPendingShelfMove(threadId: ref.threadId) }
            }
            throw error
        }
        if let before { offerUndo(for: action, on: ref, before: before) }
        await UIImpactFeedbackGenerator.light()
    }

    // MARK: Undo

    /// "Settled · Undo" for five seconds after a settle, snooze, unpin or archive. Actions of the
    /// same kind in a row join one notice and are undone together.
    struct UndoNotice: Identifiable, Equatable {
        enum Kind { case settled, snoozed, unpinned, archived }

        let id = UUID()
        var kind: Kind
        var count: Int
        fileprivate var steps: [@MainActor () async throws -> Void]

        var title: String {
            switch kind {
            case .settled: count == 1 ? String(localized: "Thread settled") : String(localized: "\(count) threads settled")
            case .snoozed: count == 1 ? String(localized: "Thread snoozed") : String(localized: "\(count) threads snoozed")
            case .unpinned: count == 1 ? String(localized: "Thread unpinned") : String(localized: "\(count) threads unpinned")
            case .archived: count == 1 ? String(localized: "Thread archived") : String(localized: "\(count) threads archived")
            }
        }

        static func == (lhs: UndoNotice, rhs: UndoNotice) -> Bool { lhs.id == rhs.id && lhs.count == rhs.count }
    }

    private(set) var undoNotice: UndoNotice?
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?

    static let undoWindow: Duration = .seconds(5)

    private func offerUndo(for action: ThreadAction, on ref: ThreadRef, before: ThreadSummary) {
        let kind: UndoNotice.Kind
        let step: @MainActor () async throws -> Void
        let id: JSON = .string(ref.threadId)
        // Undo talks to the server directly (not through `perform`), so it offers no Undo of its own.
        let send: @MainActor (String, [String: JSON], ShellState.ShelfMove?) async throws -> Void = { [weak self] type, fields, move in
            guard let environment = self?.environment(ref.environmentId) else { return }
            if let move {
                withAnimation(.snappy(duration: 0.3)) { environment.setPendingShelfMove(threadId: ref.threadId, move) }
            }
            do {
                try await environment.dispatch(type, fields)
            } catch {
                if move != nil {
                    withAnimation(.snappy(duration: 0.3)) { environment.revertPendingShelfMove(threadId: ref.threadId) }
                }
                throw error
            }
        }
        let wasSnoozedUntil = before.isSnoozed() ? before.snoozedUntil : nil
        let repin: @MainActor () async throws -> Void = { [weak self] in
            var fields: [String: JSON] = ["threadId": id]
            if let key = before.pinOrderKey, self?.canReorder(ref, pinned: true) == true { fields["orderKey"] = .string(key) }
            try await send("thread.pin", fields, nil)
        }
        switch action {
        case .settle:
            kind = .settled
            // Settling drops the pin and the snooze on the server, so Undo puts those back too.
            step = {
                try await send("thread.unsettle", ["threadId": id, "reason": "user"], .unsettle)
                if before.pinnedAt != nil { try await repin() }
                if let wasSnoozedUntil {
                    try await send("thread.snooze", ["threadId": id, "snoozedUntil": .string(ISODate.string(wasSnoozedUntil))],
                                   .snooze(wasSnoozedUntil))
                }
            }
        case .snooze:
            kind = .snoozed
            step = {
                if let wasSnoozedUntil {
                    try await send("thread.snooze", ["threadId": id, "snoozedUntil": .string(ISODate.string(wasSnoozedUntil))],
                                   .snooze(wasSnoozedUntil))
                } else {
                    try await send("thread.unsnooze", ["threadId": id, "reason": "user"], .unsnooze)
                }
            }
        case .unpin:
            guard before.pinnedAt != nil else { return }
            kind = .unpinned
            step = repin
        case .archive:
            kind = .archived
            step = { try await send("thread.unarchive", ["threadId": id], nil) }
        default:
            return
        }
        withAnimation(.snappy(duration: 0.25)) {
            if var notice = undoNotice, notice.kind == kind {
                notice.count += 1
                notice.steps.append(step)
                undoNotice = notice
            } else {
                undoNotice = UndoNotice(kind: kind, count: 1, steps: [step])
            }
        }
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.dismissUndo()
        }
    }

    func dismissUndo() {
        undoExpiry?.cancel()
        withAnimation(.snappy(duration: 0.25)) { undoNotice = nil }
    }

    /// Runs the notice's undo steps (newest first) and clears it.
    func undo() async throws {
        guard let notice = undoNotice else { return }
        dismissUndo()
        for step in notice.steps.reversed() { try await step() }
        await UIImpactFeedbackGenerator.light()
    }

    private func dispatch(_ action: ThreadAction, on threadId: String, in environment: EnvironmentSession) async throws {
        let id: JSON = .string(threadId)
        switch action {
        case .settle: try await environment.dispatch("thread.settle", ["threadId": id])
        case .unsettle: try await environment.dispatch("thread.unsettle", ["threadId": id, "reason": "user"])
        case .archive: try await environment.dispatch("thread.archive", ["threadId": id])
        case .unarchive: try await environment.dispatch("thread.unarchive", ["threadId": id])
        case .delete: try await environment.dispatch("thread.delete", ["threadId": id])
        case .unsnooze: try await environment.dispatch("thread.unsnooze", ["threadId": id, "reason": "user"])
        case .pin:
            var fields: [String: JSON] = ["threadId": id]
            // A fresh pin lands at the top of the pinned block.
            if environment.config?.capability("threadPinReorder") == true,
               let key = OrderKeys.between(nil, pinOrderKeys().values.min())
            {
                fields["orderKey"] = .string(key)
            }
            try await environment.dispatch("thread.pin", fields)
        case .unpin: try await environment.dispatch("thread.unpin", ["threadId": id])
        case .markUnread: try await environment.dispatch("thread.mark-unread", ["threadId": id])
        case .regenerateTitle:
            try await environment.dispatch("thread.metadata.update", ["threadId": id, "regenerateTitle": true])
        case .snooze(let date):
            try await environment.dispatch("thread.snooze", ["threadId": id, "snoozedUntil": .string(ISODate.string(date))])
        case .rename(let title):
            try await environment.dispatch("thread.metadata.update", ["threadId": id, "title": .string(title)])
        case .autoSettle(let enabled):
            try await environment.dispatch("thread.auto-settle.set", ["threadId": id, "enabled": .bool(enabled)])
        }
    }

    // MARK: Arranging

    /// Whether this thread's server takes order keys for the pinned (or active) section.
    func canReorder(_ ref: ThreadRef, pinned: Bool) -> Bool {
        environment(ref.environmentId)?.config?.capability(pinned ? "threadPinReorder" : "threadActiveReorder") == true
    }

    /// Every thread's key for one section, across environments (hidden rows' keys are reserved).
    private func orderKeys(pinned: Bool) -> [ThreadRef: String] {
        var keys: [ThreadRef: String] = [:]
        for environment in environments {
            for thread in environment.shell.threads.values {
                if let key = pinned ? thread.pinOrderKey : thread.activeOrderKey {
                    keys[ThreadRef(environmentId: environment.id, threadId: thread.id)] = key
                }
            }
        }
        return keys
    }

    private func pinOrderKeys() -> [ThreadRef: String] { orderKeys(pinned: true) }

    /// Move up / Move down within the pinned or active section, `ordered` as displayed. The row
    /// moves right away; writes go out in order and a failure puts the unsent ones back.
    func move(_ ref: ThreadRef, _ direction: OrderKeys.Direction, in ordered: [ThreadRef], pinned: Bool) async throws {
        guard let writes = OrderKeys.planMove(ordered: ordered, keys: orderKeys(pinned: pinned), moved: ref, direction) else { return }
        guard writes.allSatisfy({ canReorder($0.id, pinned: pinned) }) else {
            throw RPCError.defect(String(localized: "Helm on this computer can't arrange threads."))
        }
        withAnimation(.snappy(duration: 0.25)) {
            for write in writes {
                environment(write.id.environmentId)?.setPendingOrderKey(threadId: write.id.threadId, pinned: pinned, key: write.key)
            }
        }
        for (index, write) in writes.enumerated() {
            do {
                try await environment(write.id.environmentId)?.dispatch(
                    pinned ? "thread.pin.reorder" : "thread.active.reorder",
                    ["threadId": .string(write.id.threadId), "orderKey": .string(write.key)]
                )
            } catch {
                withAnimation(.snappy(duration: 0.25)) {
                    for rest in writes[index...] {
                        environment(rest.id.environmentId)?.revertPendingOrderKey(threadId: rest.id.threadId)
                    }
                }
                throw error
            }
        }
        await UIImpactFeedbackGenerator.light()
    }

    // MARK: New thread

    struct LaunchRequest {
        var environment: EnvironmentSession
        var projectId: String
        var text: String
        var attachments: [ChatAttachment]
        var context: JSON? = nil
        var modelSelection: ModelSelection
        var runtimeMode: String
        var interactionMode: String
        var newWorktree: Bool
        var baseBranch: String?
        /// Branch the worktree off `origin/<baseBranch>` (fetched first) instead of the local branch.
        var startFromOrigin = false
    }

    /// `orchestration.launchThread`: creates the thread and sends its first message.
    func launch(_ request: LaunchRequest) async throws -> ThreadRef {
        let threadId = UUID().uuidString.lowercased()
        var strategy: JSON = ["type": "root"]
        if request.newWorktree {
            var worktree: [String: JSON] = [
                "type": "worktree",
                "baseRef": .string(request.baseBranch ?? "HEAD"),
                "branch": .string("helm/\(threadId.prefix(8))"),
            ]
            if request.baseBranch != nil { worktree["startFromOrigin"] = .bool(request.startFromOrigin) }
            strategy = .object(worktree)
        }
        let title = Self.titleSeed(ContextReference.displayText(request.text))
        var initialMessage: [String: JSON] = [
            "messageId": .string(UUID().uuidString.lowercased()),
            "text": .string(request.text),
            "attachments": .array(request.attachments.map(\.json)),
        ]
        if let context = request.context { initialMessage["context"] = context }
        let payload: JSON = [
            "commandId": .string(UUID().uuidString.lowercased()),
            "creationSource": "mobile",
            "threadId": .string(threadId),
            "projectId": .string(request.projectId),
            "title": .string(title),
            "generateTitle": true,
            "modelSelection": request.modelSelection.json,
            "runtimeMode": .string(request.runtimeMode),
            "interactionMode": .string(request.interactionMode),
            "workspaceStrategy": strategy,
            "initialMessage": .object(initialMessage),
        ]
        PushService.shared.armForLocalWork(
            projectTitle: request.environment.project(request.projectId)?.title ?? request.environment.label,
            threadTitle: title
        )
        let result = try await request.environment.call("orchestration.launchThread", payload, timeout: .seconds(60))
        let id = result["threadId"]?.string ?? threadId
        if let projectionJSON = result["projection"], let projection = ThreadProjection(json: projectionJSON) {
            request.environment.cache(projection)
        }
        return ThreadRef(environmentId: request.environment.id, threadId: id)
    }

    static func titleSeed(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "New thread") }
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}

extension UIImpactFeedbackGenerator {
    static func light() async {
        await MainActor.run { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
}
