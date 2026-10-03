import Foundation

/// One timeline entry (`TurnItem`, discriminated by `type`). Fields are read leniently; the raw
/// JSON is kept for types this client does not render specially.
struct TurnItem: Identifiable, Hashable, Sendable {
    var id: String
    var type: String
    var threadId: String
    var runId: String?
    var nodeId: String?
    var parentItemId: String?
    var ordinal: Int
    var status: String
    var title: String?
    var startedAt: Date?
    var completedAt: Date?
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string, let type = json["type"]?.string else { return nil }
        self.id = id
        self.type = type
        threadId = json["threadId"]?.string ?? ""
        runId = json["runId"]?.nonNull?.string
        nodeId = json["nodeId"]?.nonNull?.string
        parentItemId = json["parentItemId"]?.nonNull?.string
        ordinal = json["ordinal"]?.int ?? 0
        status = json["status"]?.string ?? "completed"
        title = json["title"]?.nonNull?.string
        startedAt = ISODate.parse(json["startedAt"]?.nonNull?.string)
        completedAt = ISODate.parse(json["completedAt"]?.nonNull?.string)
        raw = json
    }

    var text: String { raw["text"]?.string ?? raw["markdown"]?.string ?? raw["message"]?.string ?? "" }
    var isStreaming: Bool { raw["streaming"]?.bool ?? false }
    var isRunning: Bool { ["running", "pending", "waiting"].contains(status) }
    var requestId: String? { raw["requestId"]?.string }
    var inputIntent: String? { raw["inputIntent"]?.string }

    var attachments: [ChatAttachment] {
        (raw["attachments"]?.array ?? []).compactMap(ChatAttachment.init(json:))
    }
}

struct ChatAttachment: Identifiable, Hashable, Sendable {
    var id: String
    var type: String
    var name: String
    var mimeType: String
    var sizeBytes: Int

    init(id: String, type: String, name: String, mimeType: String, sizeBytes: Int) {
        self.id = id
        self.type = type
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        type = json["type"]?.string ?? "file"
        name = json["name"]?.string ?? id
        mimeType = json["mimeType"]?.string ?? "application/octet-stream"
        sizeBytes = json["sizeBytes"]?.int ?? 0
    }

    var json: JSON {
        ["type": .string(type), "id": .string(id), "name": .string(name), "mimeType": .string(mimeType),
         "sizeBytes": .number(Double(sizeBytes))]
    }

    var isImage: Bool { type == "image" }
}

struct Run: Identifiable, Hashable, Sendable {
    var id: String
    var ordinal: Int
    var status: String
    var userMessageId: String?
    var activeAttemptId: String?
    var providerThreadId: String?
    var queuePosition: Int?
    var queueHeld: Bool
    var requestedAt: Date?
    var startedAt: Date?
    var completedAt: Date?
    var workStartedAt: Date?
    var checkpointId: String?

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        ordinal = json["ordinal"]?.int ?? 0
        status = json["status"]?.string ?? "completed"
        userMessageId = json["userMessageId"]?.nonNull?.string
        activeAttemptId = json["activeAttemptId"]?.nonNull?.string
        providerThreadId = json["providerThreadId"]?.nonNull?.string
        queuePosition = json["queuePosition"]?.nonNull?.int
        queueHeld = json["queueHeld"]?.bool ?? false
        requestedAt = ISODate.parse(json["requestedAt"]?.string)
        startedAt = ISODate.parse(json["startedAt"]?.nonNull?.string)
        completedAt = ISODate.parse(json["completedAt"]?.nonNull?.string)
        workStartedAt = ISODate.parse(json["workStartedAt"]?.nonNull?.string)
        checkpointId = json["checkpointId"]?.nonNull?.string
    }

    static let activeStatuses: Set<String> = ["preparing", "starting", "running", "waiting"]
    var isActive: Bool { Self.activeStatuses.contains(status) }
    var workingSince: Date? { workStartedAt ?? startedAt ?? requestedAt }
}

struct RunAttempt: Identifiable, Hashable, Sendable {
    var id: String
    var runId: String
    var rootNodeId: String?
    var status: String
    var providerTurnId: String?

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        runId = json["runId"]?.string ?? ""
        rootNodeId = json["rootNodeId"]?.nonNull?.string
        status = json["status"]?.string ?? ""
        providerTurnId = json["providerTurnId"]?.nonNull?.string
    }
}

struct RuntimeRequest: Identifiable, Hashable, Sendable {
    var id: String
    var kind: String
    var status: String
    var responseCapability: String
    var createdAt: Date?

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        kind = json["kind"]?.string ?? "permission"
        status = json["status"]?.string ?? "pending"
        responseCapability = json["responseCapability"]?["type"]?.string ?? "live"
        createdAt = ISODate.parse(json["createdAt"]?.string)
    }
}

struct ProviderSessionInfo: Identifiable, Hashable, Sendable {
    var id: String
    var status: String
    var supportsActiveSteering: Bool
    var supportsQueuedMessages: Bool
    var supportsInterrupt: Bool

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        status = json["status"]?.string ?? ""
        let turns = json["capabilities"]?["turns"]
        supportsActiveSteering = turns?["supportsActiveSteering"]?.bool ?? false
        supportsQueuedMessages = turns?["supportsQueuedMessages"]?.bool ?? false
        supportsInterrupt = turns?["supportsInterrupt"]?.bool ?? true
    }
}

struct ProviderThreadInfo: Identifiable, Hashable, Sendable {
    var id: String
    var providerSessionId: String?
    var usedTokens: Int?
    var maxTokens: Int?

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        providerSessionId = json["providerSessionId"]?.nonNull?.string
        let usage = json["contextUsage"]?.nonNull
        usedTokens = usage?["usedTokens"]?.int
        maxTokens = usage?["maxTokens"]?.int
    }
}

struct Checkpoint: Identifiable, Hashable, Sendable {
    var id: String
    var runId: String?
    var appRunOrdinal: Int?
    var status: String
    var files: [CheckpointFile]

    struct CheckpointFile: Hashable, Sendable {
        var path: String
        var kind: String
        var additions: Int
        var deletions: Int
    }

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        runId = json["runId"]?.nonNull?.string
        appRunOrdinal = json["appRunOrdinal"]?.nonNull?.int
        status = json["status"]?.string ?? ""
        files = (json["files"]?.array ?? []).map {
            CheckpointFile(
                path: $0["path"]?.string ?? "",
                kind: $0["kind"]?.string ?? "modified",
                additions: $0["additions"]?.int ?? 0,
                deletions: $0["deletions"]?.int ?? 0
            )
        }
    }
}

/// A pending approval or question the user has to answer.
struct PendingRequest: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case approval(requestKind: String, prompt: String?, appName: String?, options: [ApprovalOption])
        case questions([UserQuestion], dismissible: Bool)
    }

    var id: String
    var kind: Kind
    var canRespond: Bool
    var createdAt: Date?
}

struct ApprovalOption: Hashable, Sendable {
    var decision: String
    var label: String
    var warning: String?
}

struct UserQuestion: Identifiable, Hashable, Sendable {
    struct Option: Hashable, Sendable {
        var label: String
        var description: String?
        var value: String?
        var answer: String { value ?? label }
    }

    var id: String
    var header: String?
    var question: String
    var options: [Option]
    var multiSelect: Bool
    var allowCustomAnswer: Bool
}

struct QueuedMessage: Identifiable, Hashable, Sendable {
    var id: String  // run id
    var text: String
    var held: Bool
}

/// Thread detail state (`OrchestrationV2ThreadProjection`) with the reducer from
/// client-runtime's `orchestrationV2Projection.ts`. The timeline is `rows`, server-ordered.
struct ThreadProjection: Sendable {
    var threadJSON: JSON
    var thread: ThreadSummary
    var runs: [String: Run] = [:]
    var attempts: [String: RunAttempt] = [:]
    var runtimeRequests: [String: RuntimeRequest] = [:]
    var providerSessions: [String: ProviderSessionInfo] = [:]
    var providerThreads: [String: ProviderThreadInfo] = [:]
    var checkpoints: [String: Checkpoint] = [:]
    var messages: [String: JSON] = [:]
    var items: [String: TurnItem] = [:]
    /// The visible timeline. `local` rows are maintained here; inherited/synthetic rows are
    /// kept as the server sent them.
    var rows: [Row] = []

    struct Row: Hashable, Sendable {
        var visibility: String
        var item: TurnItem
    }

    init?(json: JSON) {
        guard let threadJSON = json["thread"], let thread = ThreadSummary(json: threadJSON) else { return nil }
        self.threadJSON = threadJSON
        self.thread = thread
        runs = Self.index(json["runs"], Run.init(json:))
        attempts = Self.index(json["attempts"], RunAttempt.init(json:))
        runtimeRequests = Self.index(json["runtimeRequests"], RuntimeRequest.init(json:))
        providerSessions = Self.index(json["providerSessions"], ProviderSessionInfo.init(json:))
        providerThreads = Self.index(json["providerThreads"], ProviderThreadInfo.init(json:))
        checkpoints = Self.index(json["checkpoints"], Checkpoint.init(json:))
        for message in json["messages"]?.array ?? [] {
            if let id = message["id"]?.string { messages[id] = message }
        }
        items = Self.index(json["turnItems"], TurnItem.init(json:))
        rows = (json["visibleTurnItems"]?.array ?? []).compactMap { row in
            guard let item = row["item"].flatMap(TurnItem.init(json:)) else { return nil }
            return Row(visibility: row["visibility"]?.string ?? "local", item: item)
        }
        // Items referenced by visible rows count as known items too.
        for row in rows where items[row.item.id] == nil { items[row.item.id] = row.item }
    }

    private static func index<T: Identifiable>(_ json: JSON?, _ make: (JSON) -> T?) -> [String: T] where T.ID == String {
        var result: [String: T] = [:]
        for element in json?.array ?? [] {
            if let value = make(element) { result[value.id] = value }
        }
        return result
    }

    // MARK: Reducer

    /// Applies one domain event. Returns false when the thread was deleted.
    @discardableResult
    mutating func apply(event: JSON) -> Bool {
        guard event["threadId"]?.string == thread.id, let type = event["type"]?.string else { return true }
        let payload = event["payload"] ?? .null
        if type == "thread.deleted" { return false }
        if type.hasPrefix("thread.") {
            if let updated = ThreadSummary(json: payload) {
                threadJSON = payload
                thread = updated
            }
            return true
        }
        switch type {
        case "run.created", "run.updated":
            if let run = Run(json: payload) { runs[run.id] = run }
            recomputeVisibility()
        case "run-attempt.created", "run-attempt.updated":
            if let attempt = RunAttempt(json: payload) { attempts[attempt.id] = attempt }
            recomputeVisibility()
        case "runtime-request.updated":
            if let request = RuntimeRequest(json: payload) { runtimeRequests[request.id] = request }
        case "provider-session.attached", "provider-session.updated":
            if let session = ProviderSessionInfo(json: payload) { providerSessions[session.id] = session }
        case "provider-session.detached":
            if let id = payload["providerSessionId"]?.string { providerSessions[id] = nil }
        case "provider-thread.updated":
            if let providerThread = ProviderThreadInfo(json: payload) { providerThreads[providerThread.id] = providerThread }
        case "checkpoint.captured":
            if let checkpoint = Checkpoint(json: payload) { checkpoints[checkpoint.id] = checkpoint }
        case "message.updated":
            if let id = payload["id"]?.string { messages[id] = payload }
        case "turn-item.updated":
            guard let item = TurnItem(json: payload) else { break }
            let previous = items[item.id]
            items[item.id] = item
            if item.type == "run_interrupt_request" || previous?.type == "run_interrupt_request" {
                recomputeVisibility()
            }
            upsertRow(item)
        default:
            break
        }
        return true
    }

    private mutating func upsertRow(_ item: TurnItem) {
        let existing = rows.firstIndex { $0.visibility == "local" && $0.item.id == item.id }
        guard isVisible(item) else {
            if let existing { rows.remove(at: existing) }
            return
        }
        if let existing, rows[existing].item.ordinal == item.ordinal {
            rows[existing].item = item
            return
        }
        if let existing { rows.remove(at: existing) }
        let insertAt = rows.firstIndex { row in
            row.visibility == "local"
                && (row.item.ordinal > item.ordinal || (row.item.ordinal == item.ordinal && row.item.id > item.id))
        }
        rows.insert(Row(visibility: "local", item: item), at: insertAt ?? rows.endIndex)
    }

    private mutating func recomputeVisibility() {
        let hidden = Set(rows.filter { $0.visibility == "local" && !isVisible($0.item) }.map(\.item.id))
        guard !hidden.isEmpty else { return }
        rows.removeAll { $0.visibility == "local" && hidden.contains($0.item.id) }
    }

    /// `orchestrationV2Timeline.ts`: rolled-back runs, cancelled queued messages and superseded
    /// interrupt results are hidden.
    func isVisible(_ item: TurnItem) -> Bool {
        let run = item.runId.flatMap { runs[$0] }
        if run?.status == "rolled_back" { return false }
        if item.type == "user_message", item.inputIntent == "queued_turn", run?.status == "cancelled" { return false }
        if item.type == "run_interrupt_result", let runId = item.runId {
            let superseded = attempts.values.contains {
                $0.runId == runId && $0.status == "superseded" && $0.rootNodeId == item.nodeId
            }
            let hasRequest = items.values.contains { $0.type == "run_interrupt_request" && $0.runId == runId }
            if superseded && !hasRequest { return false }
        }
        return true
    }

    // MARK: Derived state

    var activeRun: Run? {
        runs.values.filter(\.isActive).max { $0.ordinal < $1.ordinal }
    }

    var isWorking: Bool { activeRun != nil }

    var queued: [QueuedMessage] {
        runs.values
            .filter { $0.status == "queued" }
            .filter { run in
                guard let messageId = run.userMessageId, let message = messages[messageId] else { return true }
                return message["notification"] == nil && message["delegatedCompletion"] == nil
            }
            .sorted { ($0.queuePosition ?? $0.ordinal, $0.ordinal) < ($1.queuePosition ?? $1.ordinal, $1.ordinal) }
            .map { run in
                QueuedMessage(
                    id: run.id,
                    text: run.userMessageId.flatMap { messages[$0]?["text"]?.string } ?? "",
                    held: run.queueHeld
                )
            }
    }

    var activeSession: ProviderSessionInfo? {
        let providerThreadId = activeRun?.providerThreadId ?? threadJSON["activeProviderThreadId"]?.nonNull?.string
        guard let sessionId = providerThreadId.flatMap({ providerThreads[$0]?.providerSessionId }) else {
            return providerSessions.values.first
        }
        return providerSessions[sessionId]
    }

    var contextUsage: (used: Int, max: Int)? {
        let providerThreadId = activeRun?.providerThreadId ?? threadJSON["activeProviderThreadId"]?.nonNull?.string
        guard let info = providerThreadId.flatMap({ providerThreads[$0] }),
              let used = info.usedTokens, let max = info.maxTokens, max > 0
        else { return nil }
        return (used, max)
    }

    /// Mirrors client-runtime's `threadRequests.ts`.
    var pendingRequests: [PendingRequest] {
        runtimeRequests.values
            .filter { $0.status == "pending" && $0.kind != "auth_refresh" && $0.kind != "dynamic_tool_call" }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            .compactMap { request in
                if request.kind == "user_input" {
                    let item = items.values.filter { $0.type == "user_input_request" && $0.requestId == request.id }
                        .max { $0.ordinal < $1.ordinal }
                    let questions = (item?.raw["questions"]?.array ?? []).compactMap { q -> UserQuestion? in
                        guard let id = q["id"]?.string else { return nil }
                        return UserQuestion(
                            id: id,
                            header: q["header"]?.string,
                            question: q["question"]?.string ?? "",
                            options: (q["options"]?.array ?? []).map {
                                .init(label: $0["label"]?.string ?? "", description: $0["description"]?.string, value: $0["value"]?.string)
                            },
                            multiSelect: q["multiSelect"]?.bool ?? false,
                            allowCustomAnswer: q["allowCustomAnswer"]?.bool ?? true
                        )
                    }
                    let dismissible = item?.raw["responseMode"]?.string == "message" || request.responseCapability == "message"
                    return PendingRequest(
                        id: request.id, kind: .questions(questions, dismissible: dismissible),
                        canRespond: request.responseCapability != "not_resumable", createdAt: request.createdAt
                    )
                }
                let item = items.values.filter { $0.type == "approval_request" && $0.requestId == request.id }
                    .max { $0.ordinal < $1.ordinal }
                var options = (item?.raw["options"]?.array ?? []).compactMap { option -> ApprovalOption? in
                    guard let decision = option["decision"]?.string else { return nil }
                    return ApprovalOption(decision: decision, label: option["label"]?.string ?? decision, warning: option["warning"]?.string)
                }
                if options.isEmpty {
                    options = [
                        ApprovalOption(decision: "accept", label: String(localized: "Allow once")),
                        ApprovalOption(decision: "acceptForSession", label: String(localized: "Allow for session")),
                        ApprovalOption(decision: "decline", label: String(localized: "Decline")),
                    ]
                }
                return PendingRequest(
                    id: request.id,
                    kind: .approval(
                        requestKind: item?.raw["requestKind"]?.string ?? request.kind,
                        prompt: item?.raw["prompt"]?.string,
                        appName: item?.raw["appName"]?.string,
                        options: options
                    ),
                    canRespond: request.responseCapability == "live",
                    createdAt: request.createdAt
                )
            }
    }

    /// The checkpoint (with changed files) captured at the end of a run, for "review changes".
    func checkpoint(forRun runId: String) -> Checkpoint? {
        checkpoints.values.first { $0.runId == runId && $0.status == "ready" }
    }

    var latestCheckpointWithChanges: Checkpoint? {
        checkpoints.values
            .filter { !$0.files.isEmpty && $0.appRunOrdinal != nil }
            .max { ($0.appRunOrdinal ?? 0) < ($1.appRunOrdinal ?? 0) }
    }
}
