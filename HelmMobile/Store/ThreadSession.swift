import Foundation
import Observation

/// A thread view's live subscription (`orchestration.subscribeThread`) plus its actions.
@MainActor
@Observable
final class ThreadSession {
    let threadId: String
    private(set) var projection: ThreadProjection?
    private(set) var isDeleted = false
    private(set) var loadError: String?
    /// Messages sent from this phone that the server hasn't echoed yet.
    private(set) var outbox: [OutgoingMessage] = []
    /// An older history page is on its way.
    private(set) var isLoadingHistory = false
    /// Why the last older page didn't load; cleared by the next try.
    private(set) var historyError: String?
    /// When the timeline on screen was last in step with the server: set while it is a saved
    /// copy or the connection is down, nil once a live snapshot is in.
    private(set) var savedAt: Date?
    /// Looked for a copy saved on this phone (found or not).
    private(set) var checkedSavedCopy = false

    struct OutgoingMessage: Identifiable, Hashable {
        var id: String  // messageId
        var commandId: String
        var text: String
        var attachments: [ChatAttachment]
        /// `OrchestrationMessageContext` for the `t3-context://` links in `text`.
        var context: JSON?
        var failed: String?
    }

    @ObservationIgnored private(set) weak var environment: EnvironmentSession?
    @ObservationIgnored private var lastSequence = 0
    @ObservationIgnored private var subscription: Task<Void, Never>?
    /// The projection changed since it was last written to disk.
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(threadId: String, environment: EnvironmentSession, cached: EnvironmentSession.CachedProjection?) {
        self.threadId = threadId
        self.environment = environment
        projection = cached?.projection
        savedAt = cached?.savedAt
        checkedSavedCopy = cached != nil
        if cached == nil { restoreSavedCopy() }
    }

    isolated deinit {
        subscription?.cancel()
        pendingSave?.cancel()
        // Cache once on the way out (not per streaming event: that copies the timeline).
        if let projection { environment?.cache(projection, savedAt: savedAt ?? Date()) }
        saveToDisk()
    }

    // MARK: Local cache

    /// Shows the copy saved on this phone until the server's snapshot arrives.
    private func restoreSavedCopy() {
        guard let environmentId = environment?.id, !AppModel.isUnitTestHost else {
            checkedSavedCopy = true
            return
        }
        Task { [weak self, threadId] in
            let saved = await LocalCache.shared.thread(threadId, environmentId: environmentId)
            guard let self else { return }
            self.checkedSavedCopy = true
            guard let saved, self.projection == nil, !self.isDeleted else { return }
            self.projection = saved.projection
            self.savedAt = saved.savedAt
        }
    }

    /// Writes the timeline if it changed; a copy read from disk is never written back.
    func saveToDisk() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty, let projection, let environment else { return }
        isDirty = false
        LocalCache.shared.saveThread(projection, environmentId: environment.id, savedAt: savedAt ?? Date())
    }

    /// While events stream in, write at most every few seconds.
    private func saveSoon() {
        isDirty = true
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.pendingSave = nil
            self?.saveToDisk()
        }
    }

    /// The stream stopped: what is on screen was current until now.
    private func wentOffline() {
        if projection != nil, savedAt == nil { savedAt = Date() }
        saveToDisk()
    }

    @ObservationIgnored private var retryDelay: Double = 1

    func subscribe(on connection: RPCConnection) {
        subscription?.cancel()
        // A long thread arrives as its recent window; older pages load on demand.
        var payload: [String: JSON] = ["threadId": .string(threadId), "acceptBoundedSnapshot": true]
        if environment?.config?.threadResumeCompletionMarker == true { payload["requestCompletionMarker"] = true }
        if projection != nil, lastSequence > 0 { payload["afterSequence"] = .number(Double(lastSequence)) }
        let stream = connection.stream("orchestration.subscribeThread", .object(payload))
        subscription = Task { [weak self] in
            do {
                for try await item in stream {
                    // A snapshot is built off the main thread (a long thread took ~75 ms on an
                    // older iPad); the stream waits for it, so events still apply in order.
                    var built: ThreadProjection?
                    if item["kind"]?.string == "snapshot" {
                        built = await Task.detached(priority: .userInitiated) {
                            Perf.measure("thread.projection") { ThreadProjection(snapshot: item) }
                        }.value
                        guard !Task.isCancelled else { return }
                    }
                    self?.apply(item, snapshot: built)
                }
            } catch RPCError.disconnected {
                if !Task.isCancelled { self?.wentOffline() }
                return  // the environment reconnects and resubscribes every open thread
            } catch {
                self?.loadError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.wentOffline()
            await self?.resubscribeAfterEnd()
        }
    }

    /// The thread stream ended while the socket stayed up (a server-side failure): try again
    /// with a short backoff, starting from a fresh snapshot.
    private func resubscribeAfterEnd() async {
        guard !isDeleted else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        try? await Task.sleep(for: .seconds(delay))
        guard let connection = environment?.currentConnection else { return }
        lastSequence = 0
        subscribe(on: connection)
    }

    private func apply(_ item: JSON, snapshot: ThreadProjection?) {
        let kind = item["kind"]?.string
        Perf.measure("thread.apply.\(kind ?? "other")") { applyMeasured(item, snapshot: snapshot) }
        if kind == "snapshot" { Perf.mark("thread snapshot", "\(threadId.prefix(8)) \(projection?.rows.count ?? 0) rows") }
    }

    private func applyMeasured(_ item: JSON, snapshot: ThreadProjection?) {
        switch item["kind"]?.string {
        case "snapshot":
            guard let next = snapshot else { return }
            lastSequence = item["snapshotSequence"]?.int ?? lastSequence
            projection = next
            savedAt = nil
            historyError = nil
            loadError = nil
            retryDelay = 1
            reconcileOutbox()
            environment?.cache(next)
            isDirty = true
            saveToDisk()
        case "event":
            guard let sequence = item["sequence"]?.int, sequence > lastSequence else { return }
            lastSequence = sequence
            guard let event = item["event"], projection != nil else {
                if item["event"]?["type"]?.string == "thread.deleted" { markDeleted() }
                return
            }
            if projection?.apply(event: event) == false {
                markDeleted()
                return
            }
            let type = event["type"]?.string
            if type == "turn-item.updated" || type == "message.updated" { reconcileOutbox() }
            savedAt = nil
            saveSoon()
        default:
            // A resumed stream sends no new snapshot; it is live again once it speaks.
            if lastSequence > 0 { savedAt = nil }
        }
    }

    private func markDeleted() {
        isDeleted = true
        projection = nil
        isDirty = false
        pendingSave?.cancel()
        environment?.forgetThread(threadId)
    }

    /// Drops outgoing bubbles the server now knows about: as a timeline item, or (for queued
    /// messages, which get their turn item only when they start) as a conversation message.
    private func reconcileOutbox() {
        guard !outbox.isEmpty, let projection else { return }
        outbox.removeAll { pending in
            projection.messages[pending.id] != nil
                || projection.items.values.contains { $0.raw["messageId"]?.string == pending.id }
        }
    }

    // MARK: History

    /// Prepends the next older page of the timeline (`GET …/threads/{id}/history?cursor=`).
    /// `beforeMerge` lets the view hold the page until it can keep its scroll position. A page
    /// that comes back after a new snapshot replaced the window is dropped.
    func loadEarlier(beforeMerge: () async -> Void = {}) async {
        guard !isLoadingHistory, let environment, let history = projection?.history, history.hasMore,
              let cursor = history.cursor
        else { return }
        isLoadingHistory = true
        historyError = nil
        do {
            let page = try await environment.threadHistoryPage(threadId: threadId, cursor: cursor)
            await beforeMerge()
            if projection?.history.cursor == cursor { projection?.mergeOlder(page: page) }
        } catch {
            if projection?.history.cursor == cursor {
                historyError = String(localized: "Couldn't load earlier messages.")
            }
        }
        isLoadingHistory = false
    }

    // MARK: Actions

    enum FollowUp { case queue, steer }

    /// Sends a message. While a turn runs it queues (default) or steers into the running turn.
    func send(text: String, attachments: [ChatAttachment], context: JSON? = nil, followUp: FollowUp = .queue,
              modelSelection: ModelSelection?, runtimeMode: String?, interactionMode: String?) async {
        var message = OutgoingMessage(
            id: UUID().uuidString.lowercased(), commandId: UUID().uuidString.lowercased(),
            text: text, attachments: attachments, context: context
        )
        guard let environment else {
            // Never drop typed text: keep it visible with a way to retry.
            message.failed = String(localized: "Not connected to Helm.")
            outbox.append(message)
            return
        }
        outbox.append(message)
        await deliver(message, followUp: followUp, modelSelection: modelSelection,
                      runtimeMode: runtimeMode, interactionMode: interactionMode, environment: environment)
    }

    func retry(_ message: OutgoingMessage) async {
        guard let environment, let index = outbox.firstIndex(where: { $0.id == message.id }) else { return }
        outbox[index].failed = nil
        await deliver(outbox[index], followUp: .queue, modelSelection: nil, runtimeMode: nil, interactionMode: nil,
                      environment: environment)
    }

    func discard(_ message: OutgoingMessage) {
        outbox.removeAll { $0.id == message.id }
    }

    private func deliver(_ message: OutgoingMessage, followUp: FollowUp, modelSelection: ModelSelection?,
                         runtimeMode: String?, interactionMode: String?, environment: EnvironmentSession) async {
        do {
            let thread = projection?.thread ?? environment.thread(threadId)
            if let runtimeMode, runtimeMode != thread?.runtimeMode {
                try await environment.dispatch("thread.runtime-mode.set", [
                    "threadId": .string(threadId), "runtimeMode": .string(runtimeMode),
                ], commandId: "\(message.commandId):runtime-mode")
            }
            if let interactionMode, interactionMode != thread?.interactionMode {
                try await environment.dispatch("thread.interaction-mode.set", [
                    "threadId": .string(threadId), "interactionMode": .string(interactionMode),
                ], commandId: "\(message.commandId):interaction-mode")
            }
            var fields: [String: JSON] = [
                "createdBy": "user",
                "creationSource": "mobile",
                "threadId": .string(threadId),
                "messageId": .string(message.id),
                "text": .string(message.text),
                "attachments": .array(message.attachments.map(\.json)),
            ]
            if let context = message.context { fields["context"] = context }
            if let modelSelection { fields["modelSelection"] = modelSelection.json }
            let isWorking = projection?.isWorking ?? thread?.isWorking ?? false
            let serverResolves = environment.config?.capability("serverResolvedCommandContext") ?? false
            if !isWorking {
                fields["dispatchMode"] = ["type": "start_immediately"]
            } else if followUp == .queue {
                fields["dispatchMode"] = ["type": "queue_after_active"]
            } else if serverResolves {
                fields["dispatchMode"] = ["type": "start_immediately"]
                fields["deliveryIntent"] = "auto"
            } else if let run = projection?.activeRun {
                let canSteer = projection?.activeSession?.supportsActiveSteering ?? false
                fields["dispatchMode"] = canSteer
                    ? ["type": "steer_active", "targetRunId": .string(run.id)]
                    : ["type": "queue_after_active"]
            } else {
                fields["dispatchMode"] = ["type": "start_immediately"]
            }
            try await environment.dispatch("message.dispatch", fields, commandId: message.commandId)
            PushService.shared.armForLocalWork(
                projectTitle: environment.project(thread?.projectId)?.title ?? environment.label,
                threadTitle: thread?.displayTitle ?? ""
            )
            if let index = outbox.firstIndex(where: { $0.id == message.id }) { outbox[index].failed = nil }
            reconcileOutbox()
        } catch {
            if let index = outbox.firstIndex(where: { $0.id == message.id }) {
                outbox[index].failed = error.localizedDescription
            }
        }
    }

    func interrupt() async throws {
        guard let environment, let run = projection?.activeRun else { return }
        try await environment.dispatch("run.interrupt", [
            "threadId": .string(threadId), "runId": .string(run.id), "holdQueue": true,
        ])
    }

    /// Stops what the thread left running after its turn (subagents, commands, monitors). The
    /// server accepts an interrupt of the settled latest run while its provider still has such work.
    func stopBackgroundWork(latestRunId: String?) async throws {
        let latest = projection?.runs.values.max { $0.ordinal < $1.ordinal }?.id ?? latestRunId
        guard let environment, let runId = latest else { return }
        try await environment.dispatch("run.interrupt", [
            "threadId": .string(threadId), "runId": .string(runId), "holdQueue": true,
        ])
    }

    func respond(to request: PendingRequest, decision: String) async throws {
        try await environment?.dispatch("runtime-request.respond", [
            "threadId": .string(threadId), "requestId": .string(request.id), "decision": .string(decision),
        ])
    }

    /// `attachmentsByQuestionId` only lists questions that have attachments, and is left out
    /// entirely when none do.
    func answer(_ request: PendingRequest, answers: [String: JSON],
                attachmentsByQuestionId: [String: [ChatAttachment]] = [:]) async throws {
        var fields: [String: JSON] = [
            "threadId": .string(threadId), "requestId": .string(request.id), "answers": .object(answers),
        ]
        let attached = attachmentsByQuestionId.filter { !$0.value.isEmpty }
        if !attached.isEmpty {
            fields["attachmentsByQuestionId"] = .object(attached.mapValues { .array($0.map(\.json)) })
        }
        try await environment?.dispatch("runtime-request.respond", fields)
    }

    func dismiss(_ request: PendingRequest) async throws {
        try await environment?.dispatch("thread.user-input.dismiss", [
            "threadId": .string(threadId), "requestId": .string(request.id),
        ])
    }

    func cancelQueued(_ runId: String) async throws {
        try await environment?.dispatch("queued-run.cancel", ["threadId": .string(threadId), "runId": .string(runId)])
    }

    func steerQueued(_ runId: String) async throws {
        guard let active = projection?.activeRun else { return }
        try await environment?.dispatch("queued-message.promote-to-steer", [
            "threadId": .string(threadId), "queuedRunId": .string(runId), "targetRunId": .string(active.id),
        ])
    }

    /// Rewrites a queued message. Without `attachments` in the payload its attachments and
    /// context stay as they were.
    func editQueued(_ runId: String, _ payload: QueuedEdit.Payload) async throws {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var fields: [String: JSON] = ["threadId": .string(threadId), "runId": .string(runId), "text": .string(text)]
        if let attachments = payload.attachments { fields["attachments"] = .array(attachments.map(\.json)) }
        if let context = payload.context { fields["context"] = context }
        try await environment?.dispatch("queued-run.edit", fields)
    }

    /// Moves a queued message right before `beforeRunId`, or to the end of the queue when nil.
    func reorderQueued(_ runId: String, before beforeRunId: String?) async throws {
        try await environment?.dispatch("queued-run.reorder", [
            "threadId": .string(threadId), "runId": .string(runId),
            "beforeRunId": beforeRunId.map { .string($0) } ?? .null,
        ])
    }

    /// The usage-limit card's toggles: resume automatically at reset, or snooze until it.
    /// `resetAt` is the shell's `usageLimitResetAt`, sent back verbatim.
    func setLimitRecovery(runId: String, resetAt: String, autoResume: Bool? = nil, snooze: Bool? = nil) async throws {
        var recovery: [String: JSON] = ["runId": .string(runId), "resetAt": .string(resetAt)]
        if let autoResume { recovery["autoResume"] = .bool(autoResume) }
        if let snooze { recovery["snooze"] = .bool(snooze) }
        try await environment?.dispatch("thread.metadata.update", [
            "threadId": .string(threadId), "limitRecovery": .object(recovery),
        ])
    }

    /// "Continue now" after a usage limit: a continuation of the blocked run, then the queue
    /// (held when the run failed) is let go.
    func continueAfterLimit(runId: String) async throws {
        guard let environment else { throw RPCError.disconnected }
        try await environment.dispatch("message.dispatch", [
            "createdBy": "user",
            "creationSource": "mobile",
            "threadId": .string(threadId),
            "messageId": .string(UUID().uuidString.lowercased()),
            "text": .string("Continue where you left off."),
            "attachments": [],
            "manualContinuationOfRunId": .string(runId),
            "dispatchMode": ["type": "start_immediately"],
        ])
        if projection?.queued.contains(where: \.held) == true {
            try await resumeQueue()
        }
    }

    func resumeQueue() async throws {
        try await environment?.dispatch("queue.resume", ["threadId": .string(threadId)])
    }

    func setModel(_ selection: ModelSelection) async throws {
        try await environment?.dispatch("thread.model-selection.set", [
            "threadId": .string(threadId), "modelSelection": selection.json,
        ])
    }

    func setRuntimeMode(_ mode: String) async throws {
        try await environment?.dispatch("thread.runtime-mode.set", [
            "threadId": .string(threadId), "runtimeMode": .string(mode),
        ])
    }

    func setInteractionMode(_ mode: String) async throws {
        try await environment?.dispatch("thread.interaction-mode.set", [
            "threadId": .string(threadId), "interactionMode": .string(mode),
        ])
    }

    func markVisited() {
        guard let environment, environment.config?.capability("threadVisitedTracking") == true else { return }
        let threadId = threadId
        // The watermark is compared with server timestamps, so never send a time earlier than
        // the latest activity even if this phone's clock runs behind.
        let summary = environment.thread(threadId)
        let latest = [Date(), summary?.updatedAt, summary?.latestRunCompletedAt].compactMap { $0 }.max() ?? Date()
        Task {
            try? await environment.dispatch("thread.visit", [
                "threadId": .string(threadId), "visitedAt": .string(ISODate.string(latest)),
            ])
        }
    }

    func turnDiff(checkpoint: Checkpoint) async throws -> String {
        guard let environment, let to = checkpoint.appRunOrdinal else { return "" }
        let result = try await environment.call("orchestration.getTurnDiff", [
            "threadId": .string(threadId),
            "fromTurnCount": .number(Double(max(0, to - 1))),
            "toTurnCount": .number(Double(to)),
        ], timeout: .seconds(60))
        return result["diff"]?.string ?? ""
    }
}
