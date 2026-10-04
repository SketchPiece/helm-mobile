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

    struct OutgoingMessage: Identifiable, Hashable {
        var id: String  // messageId
        var commandId: String
        var text: String
        var attachments: [ChatAttachment]
        var failed: String?
    }

    @ObservationIgnored private weak var environment: EnvironmentSession?
    @ObservationIgnored private var lastSequence = 0
    @ObservationIgnored private var subscription: Task<Void, Never>?

    init(threadId: String, environment: EnvironmentSession, cached: ThreadProjection?) {
        self.threadId = threadId
        self.environment = environment
        projection = cached
    }

    isolated deinit {
        subscription?.cancel()
        // Cache once on the way out (not per streaming event: that copies the timeline).
        if let projection { environment?.cache(projection) }
    }

    @ObservationIgnored private var retryDelay: Double = 1

    func subscribe(on connection: RPCConnection) {
        subscription?.cancel()
        var payload: [String: JSON] = ["threadId": .string(threadId)]
        if environment?.config?.threadResumeCompletionMarker == true { payload["requestCompletionMarker"] = true }
        if projection != nil, lastSequence > 0 { payload["afterSequence"] = .number(Double(lastSequence)) }
        let stream = connection.stream("orchestration.subscribeThread", .object(payload))
        subscription = Task { [weak self] in
            do {
                for try await item in stream { self?.apply(item) }
            } catch RPCError.disconnected {
                return  // the environment reconnects and resubscribes every open thread
            } catch {
                self?.loadError = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
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

    private func apply(_ item: JSON) {
        switch item["kind"]?.string {
        case "snapshot":
            guard let json = item["projection"], let next = ThreadProjection(json: json) else { return }
            lastSequence = item["snapshotSequence"]?.int ?? lastSequence
            projection = next
            loadError = nil
            retryDelay = 1
            reconcileOutbox()
            environment?.cache(next)
        case "event":
            guard let sequence = item["sequence"]?.int, sequence > lastSequence else { return }
            lastSequence = sequence
            guard let event = item["event"], projection != nil else {
                if item["event"]?["type"]?.string == "thread.deleted" { isDeleted = true }
                return
            }
            if projection?.apply(event: event) == false {
                isDeleted = true
                projection = nil
            }
            let type = event["type"]?.string
            if type == "turn-item.updated" || type == "message.updated" { reconcileOutbox() }
        default:
            break
        }
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

    // MARK: Actions

    enum FollowUp { case queue, steer }

    /// Sends a message. While a turn runs it queues (default) or steers into the running turn.
    func send(text: String, attachments: [ChatAttachment], followUp: FollowUp = .queue,
              modelSelection: ModelSelection?, runtimeMode: String?, interactionMode: String?) async {
        var message = OutgoingMessage(
            id: UUID().uuidString.lowercased(), commandId: UUID().uuidString.lowercased(),
            text: text, attachments: attachments
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

    func respond(to request: PendingRequest, decision: String) async throws {
        try await environment?.dispatch("runtime-request.respond", [
            "threadId": .string(threadId), "requestId": .string(request.id), "decision": .string(decision),
        ])
    }

    func answer(_ request: PendingRequest, answers: [String: JSON]) async throws {
        try await environment?.dispatch("runtime-request.respond", [
            "threadId": .string(threadId), "requestId": .string(request.id), "answers": .object(answers),
        ])
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
