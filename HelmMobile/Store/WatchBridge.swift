import Foundation
import Observation
import UIKit
import WatchConnectivity

/// The Apple Watch app's way to Helm. The watch has no Tailscale and no tokens, so the phone stays the
/// only client: it sends the watch the thread list and does what the watch asks. A message from the
/// watch wakes the app in the background; the request waits for the Mac's connection first.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private weak var model: AppModel?
    private var session: WCSession?
    /// Threads the watch has open, kept subscribed while it looks at them.
    private var open: [ThreadRef: ThreadSession] = [:]
    private var lastSnapshot: WatchSnapshot?
    private var snapshotSoon: Task<Void, Never>?
    private var detailSoon: [ThreadRef: Task<Void, Never>] = [:]

    func start(model: AppModel) {
        guard WCSession.isSupported(), session == nil else { return }
        self.model = model
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        followThreadList()
    }

    // MARK: Thread list

    /// Builds the snapshot and asks to hear about the next change. Re-armed only when the debounced
    /// publish runs, so a busy list is built at most every 600 ms.
    @discardableResult
    private func followThreadList() -> WatchSnapshot {
        withObservationTracking {
            buildSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSnapshot() }
        }
    }

    private func scheduleSnapshot() {
        guard snapshotSoon == nil else { return }
        snapshotSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.snapshotSoon = nil
            self?.publishSnapshot()
        }
    }

    private func publishSnapshot(force: Bool = false) {
        let snapshot = followThreadList()
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        guard force || snapshot.withoutDate != lastSnapshot?.withoutDate else { return }
        lastSnapshot = snapshot
        let payload = WatchCoding.encode(snapshot)
        try? session.updateApplicationContext(payload)
        if session.isReachable {
            session.sendMessage(WatchCoding.encode(WatchPush.snapshot(snapshot)), replyHandler: nil, errorHandler: nil)
        }
    }

    func buildSnapshot() -> WatchSnapshot {
        guard let model else { return .empty }
        let now = Date()
        let entries = model.allThreads()
        let active = entries
            .filter { !$0.thread.isSettled && !$0.thread.isSnoozed(now: now) }
            .sorted(by: Self.watchOrder)
            .prefix(40)
        let settled = entries
            .filter(\.thread.isSettled)
            .sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
            .prefix(8)
        let projects = model.allProjects().prefix(30).map { environment, project in
            WatchProject(environmentId: environment.id, projectId: project.id, title: project.title,
                         icon: Self.icon(project, fallback: project.title), macLabel: environment.label)
        }
        return WatchSnapshot(
            macs: model.environments.map { WatchMac(id: $0.id, label: $0.label, isLive: $0.isLive) },
            threads: (active + settled).map { Self.watchThread($0, now: now) },
            projects: Array(projects),
            updatedAt: now
        )
    }

    /// Who needs the user first, then running work, then the newest.
    private static func watchOrder(_ a: ThreadListEntry, _ b: ThreadListEntry) -> Bool {
        func rank(_ thread: ThreadSummary) -> Int {
            switch thread.phase {
            case .approval, .input: 0
            case .failed, .limited: 1
            case .done: 2
            case .working, .waiting: 3
            case .idle: 4
            }
        }
        let (ra, rb) = (rank(a.thread), rank(b.thread))
        if ra != rb { return ra < rb }
        return (a.thread.updatedAt ?? .distantPast) > (b.thread.updatedAt ?? .distantPast)
    }

    private static func icon(_ project: Project?, fallback: String) -> WatchIcon {
        guard let project else { return WatchIcon(emoji: nil, letters: String(fallback.prefix(2)).uppercased(), color: nil) }
        return WatchIcon(emoji: project.iconKind == "emoji" ? project.iconEmoji : nil,
                         letters: project.initials, color: project.iconKind == "monogram" ? project.iconColor : nil)
    }

    private static func watchThread(_ entry: ThreadListEntry, now: Date) -> WatchThread {
        let thread = entry.thread
        return WatchThread(
            environmentId: entry.ref.environmentId,
            threadId: thread.id,
            title: thread.displayTitle,
            projectTitle: entry.project?.title ?? entry.environmentLabel,
            icon: icon(entry.project, fallback: entry.environmentLabel),
            phase: WatchPhase(rawValue: thread.phase.rawValue) ?? .idle,
            latestText: thread.latestMessageText.map { glance($0, limit: 160) },
            latestRole: thread.latestMessageRole,
            lastError: thread.lastError.map { glance($0, limit: 160) },
            updatedAt: thread.updatedAt,
            isPinned: thread.pinnedAt != nil,
            isSettled: thread.isSettled,
            isSnoozed: thread.isSnoozed(now: now)
        )
    }

    private static func glance(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    // MARK: Open threads

    private func detail(for ref: ThreadRef) -> WatchThreadDetail? {
        guard let model, let environment = model.environment(ref.environmentId) else { return nil }
        let session = open[ref]
        let projection = session?.projection
        guard let summary = projection?.thread ?? environment.thread(ref.threadId) else { return nil }
        let entry = ThreadListEntry(ref: ref, thread: environment.thread(ref.threadId) ?? summary,
                                    project: environment.project(summary.projectId), environmentLabel: environment.label)
        var messages: [WatchMessage] = []
        if let projection {
            let blocks = Timeline.blocks(from: projection.rows.map(\.item), liveRunId: projection.activeRun?.id)
            for block in blocks.suffix(12) {
                switch block {
                case .user(let item):
                    messages.append(WatchMessage(id: item.id, role: .user, text: Self.clip(ContextReference.displayText(item.text), 600), date: item.startedAt))
                case .assistant(let item):
                    messages.append(WatchMessage(id: item.id, role: .assistant, text: Self.clip(item.text, 2400), date: item.completedAt ?? item.startedAt))
                case .plan(let item):
                    messages.append(WatchMessage(id: item.id, role: .plan, text: Self.clip(item.text, 1600), date: item.startedAt))
                case .error(let item):
                    messages.append(WatchMessage(id: item.id, role: .error, text: Self.clip(item.text.isEmpty ? (item.title ?? "") : item.text, 400), date: item.startedAt))
                case .work(let id, let items, let isLive):
                    let label = isLive
                        ? String(localized: "Working…")
                        : String(localized: "\(items.count) steps")
                    messages.append(WatchMessage(id: id, role: .work, text: label, date: items.last?.startedAt))
                default:
                    break
                }
            }
        } else if let text = summary.latestMessageText {
            messages.append(WatchMessage(id: "latest", role: summary.latestMessageRole == "user" ? .user : .assistant,
                                         text: Self.clip(text, 1200), date: summary.updatedAt))
        }
        return WatchThreadDetail(
            thread: Self.watchThread(entry, now: Date()),
            messages: messages,
            requests: projection?.pendingRequests.map(Self.watchRequest) ?? [],
            isWorking: projection?.isWorking ?? summary.isWorking,
            queuedCount: projection?.queued.count ?? 0,
            isStale: projection == nil || session?.savedAt != nil
        )
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private static func watchRequest(_ request: PendingRequest) -> WatchRequest {
        switch request.kind {
        case let .approval(requestKind, prompt, detail, appName, options):
            let title: String = if let appName { String(localized: "\(appName) wants to continue") } else {
                switch requestKind {
                case "command": String(localized: "Run this command?")
                case "file-change": String(localized: "Make these edits?")
                case "file-read": String(localized: "Read these files?")
                case "mcp-elicitation": String(localized: "A tool needs your input")
                default: String(localized: "Allow this?")
                }
            }
            return WatchRequest(
                id: request.id, kind: .approval, canRespond: request.canRespond, title: title,
                detail: (detail ?? prompt).map { clip($0, 800) },
                options: options.map { .init(decision: $0.decision, label: $0.label, isWarning: $0.warning != nil) },
                questions: [], dismissible: false
            )
        case let .questions(questions, dismissible):
            return WatchRequest(
                id: request.id, kind: .questions, canRespond: request.canRespond, title: nil, detail: nil, options: [],
                questions: questions.map { question in
                    .init(id: question.id, header: question.header, question: question.question,
                          options: question.options.map { .init(label: $0.label, detail: $0.description, answer: $0.answer) },
                          multiSelect: question.multiSelect, allowCustomAnswer: question.allowCustomAnswer)
                },
                dismissible: dismissible
            )
        }
    }

    private func openThread(_ ref: ThreadRef) {
        guard open[ref] == nil, let environment = model?.environment(ref.environmentId) else { return }
        let session = environment.threadSession(ref.threadId)
        open[ref] = session
        followDetail(ref)
    }

    private func closeThread(_ ref: ThreadRef) {
        open[ref] = nil
        detailSoon[ref]?.cancel()
        detailSoon[ref] = nil
    }

    /// Like `followThreadList`: one build per debounced push, however fast the thread streams.
    @discardableResult
    private func followDetail(_ ref: ThreadRef) -> WatchThreadDetail? {
        guard open[ref] != nil else { return nil }
        return withObservationTracking {
            detail(for: ref)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.open[ref] != nil else { return }
                self.scheduleDetail(ref)
            }
        }
    }

    private func scheduleDetail(_ ref: ThreadRef) {
        guard detailSoon[ref] == nil else { return }
        detailSoon[ref] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.detailSoon[ref] = nil
            guard let detail = self.followDetail(ref), let session = self.session, session.isReachable else { return }
            session.sendMessage(WatchCoding.encode(WatchPush.detail(detail)), replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Requests from the watch

    fileprivate func handle(_ message: WatchRequestMessage) async -> WatchReply {
        guard let model else { return .failure(String(localized: "Helm isn't ready on the iPhone.")) }
        // Woken in the background: finish before iOS suspends the app again.
        let task = UIApplication.shared.beginBackgroundTask(withName: "helm.watch")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        do {
            switch message {
            case .snapshot:
                if model.environments.contains(where: { !$0.isLive }) {
                    for environment in model.environments where !environment.isLive {
                        try? await environment.waitUntilLive(timeout: .seconds(4))
                    }
                }
                let snapshot = buildSnapshot()
                lastSnapshot = snapshot
                return WatchReply(ok: true, snapshot: snapshot)
            case let .open(environmentId, threadId):
                let ref = ThreadRef(environmentId: environmentId, threadId: threadId)
                openThread(ref)
                guard let environment = model.environment(environmentId) else { return .failure(Self.macGone) }
                try? await environment.waitUntilLive(timeout: .seconds(6))
                // A moment for the subscription's snapshot, so the first answer has the conversation.
                for _ in 0..<15 where open[ref]?.projection == nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                open[ref]?.markVisited()
                return WatchReply(ok: true, detail: detail(for: ref))
            case let .close(environmentId, threadId):
                closeThread(ThreadRef(environmentId: environmentId, threadId: threadId))
                return .success
            case let .respond(environmentId, threadId, requestId, decision):
                let environment = try await live(environmentId)
                try await environment.dispatch("runtime-request.respond", [
                    "threadId": .string(threadId), "requestId": .string(requestId), "decision": .string(decision),
                ])
            case let .answer(environmentId, threadId, requestId, answers):
                let environment = try await live(environmentId)
                // Multi-select questions take a list even for one pick; the rest take the string.
                let session = open[ThreadRef(environmentId: environmentId, threadId: threadId)]
                var multi: Set<String> = []
                for case let .questions(questions, _) in session?.projection?.pendingRequests.filter({ $0.id == requestId }).map(\.kind) ?? [] {
                    multi.formUnion(questions.filter(\.multiSelect).map(\.id))
                }
                var values: [String: JSON] = [:]
                for (id, list) in answers {
                    values[id] = multi.contains(id) ? .array(list.map(JSON.string)) : .string(list.first ?? "")
                }
                try await environment.dispatch("runtime-request.respond", [
                    "threadId": .string(threadId), "requestId": .string(requestId), "answers": .object(values),
                ])
            case let .dismiss(environmentId, threadId, requestId):
                let environment = try await live(environmentId)
                try await environment.dispatch("thread.user-input.dismiss", [
                    "threadId": .string(threadId), "requestId": .string(requestId),
                ])
            case let .send(environmentId, threadId, text):
                let environment = try await live(environmentId)
                let session = open[ThreadRef(environmentId: environmentId, threadId: threadId)]
                    ?? environment.threadSession(threadId)
                await session.send(text: text, attachments: [], modelSelection: nil, runtimeMode: nil, interactionMode: nil)
                if let failed = session.outbox.last(where: { $0.text == text })?.failed {
                    session.outbox.last(where: { $0.text == text }).map(session.discard)
                    return .failure(failed)
                }
            case let .interrupt(environmentId, threadId):
                let environment = try await live(environmentId)
                let session = open[ThreadRef(environmentId: environmentId, threadId: threadId)]
                    ?? environment.threadSession(threadId)
                for _ in 0..<15 where session.projection == nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if session.projection?.activeRun != nil {
                    try await session.interrupt()
                } else {
                    try await session.stopBackgroundWork(latestRunId: environment.thread(threadId)?.latestRunId)
                }
            case let .settle(environmentId, threadId):
                _ = try await live(environmentId)
                try await model.perform(.settle, on: ThreadRef(environmentId: environmentId, threadId: threadId))
            case let .snooze(environmentId, threadId, until):
                _ = try await live(environmentId)
                try await model.perform(.snooze(until), on: ThreadRef(environmentId: environmentId, threadId: threadId))
            case let .launch(environmentId, projectId, text):
                let environment = try await live(environmentId)
                let project = environment.project(projectId)
                guard let config = environment.config, let selection = config.initialSelection(project: project) else {
                    return .failure(String(localized: "No model is available on this Mac."))
                }
                let ref = try await model.launch(AppModel.LaunchRequest(
                    environment: environment, projectId: projectId, text: text, attachments: [],
                    modelSelection: selection, runtimeMode: config.defaultRuntimeMode, interactionMode: "default",
                    newWorktree: false, baseBranch: nil
                ))
                return WatchReply(ok: true, threadId: ref.threadId)
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static var macGone: String { String(localized: "This Mac is no longer paired.") }

    private func live(_ environmentId: String) async throws -> EnvironmentSession {
        guard let environment = model?.environment(environmentId) else { throw WatchBridgeError(message: Self.macGone) }
        do {
            try await environment.waitUntilLive(timeout: .seconds(12))
        } catch {
            throw WatchBridgeError(message: String(localized: "Can't reach \(environment.label)."))
        }
        return environment
    }

    private struct WatchBridgeError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}

private extension WatchSnapshot {
    /// The snapshot without its timestamp, to skip sending what the watch already has.
    var withoutDate: WatchSnapshot {
        var copy = self
        copy.updatedAt = .distantPast
        return copy
    }
}

/// WatchConnectivity calls back on its own queue; the reply handler is only ever called once.
private struct ReplyBox: @unchecked Sendable {
    let reply: ([String: Any]) -> Void
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.publishSnapshot(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switched to another watch: talk to the new one.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publishSnapshot(force: true) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.publishSnapshot(force: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let box = ReplyBox(reply: replyHandler)
        guard let request = WatchCoding.decode(WatchRequestMessage.self, from: message) else {
            box.reply(WatchCoding.encode(WatchReply.failure("Unknown request")))
            return
        }
        Task { @MainActor in
            let reply = await self.handle(request)
            box.reply(WatchCoding.encode(reply))
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let request = WatchCoding.decode(WatchRequestMessage.self, from: message) else { return }
        Task { @MainActor in _ = await self.handle(request) }
    }
}
