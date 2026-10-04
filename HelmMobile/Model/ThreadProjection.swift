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
    /// `"pasted-text"` for long text folded into a file (the agent reads it instead of inlining it).
    var source: String?

    init(id: String, type: String, name: String, mimeType: String, sizeBytes: Int, source: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.source = source
    }

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        type = json["type"]?.string ?? "file"
        name = json["name"]?.string ?? id
        mimeType = json["mimeType"]?.string ?? "application/octet-stream"
        sizeBytes = json["sizeBytes"]?.int ?? 0
        source = json["source"]?["_tag"]?.string
    }

    var json: JSON {
        var fields: [String: JSON] = [
            "type": .string(type), "id": .string(id), "name": .string(name), "mimeType": .string(mimeType),
            "sizeBytes": .number(Double(sizeBytes)),
        ]
        if let source { fields["source"] = ["_tag": .string(source)] }
        return .object(fields)
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

    /// As the server sent it, for the local cache.
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        raw = json
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

    /// As the server sent it, for the local cache.
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        raw = json
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

    /// As the server sent it, for the local cache.
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        raw = json
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

    /// As the server sent it, for the local cache.
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        raw = json
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

    /// As the server sent it, for the local cache.
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        raw = json
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

    /// As the server sent it, for the local cache.
    var raw: JSON

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        raw = json
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
        /// `detail` is the command or file the request is about, when the tool call is known.
        case approval(requestKind: String, prompt: String?, detail: String?, appName: String?, options: [ApprovalOption])
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
    var attachments: [ChatAttachment] = []
    /// The message's `OrchestrationMessageContext`, for edits that change its attachments.
    var context: JSON?
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
    /// Where older history continues when the server sent a bounded window.
    var history = History()

    struct Row: Hashable, Sendable {
        var visibility: String
        var item: TurnItem
        var sourceThreadId: String
        var sourceItemId: String

        init(visibility: String, item: TurnItem, sourceThreadId: String? = nil, sourceItemId: String? = nil) {
            self.visibility = visibility
            self.item = item
            self.sourceThreadId = sourceThreadId ?? item.threadId
            self.sourceItemId = sourceItemId ?? item.id
        }

        init?(json: JSON) {
            guard let item = json["item"].flatMap(TurnItem.init(json:)) else { return nil }
            self.init(visibility: json["visibility"]?.string ?? "local", item: item,
                      sourceThreadId: json["sourceThreadId"]?.string, sourceItemId: json["sourceItemId"]?.string)
        }

        /// Identity across pages (`threadHistoryMerge.ts`).
        var key: String { "\(sourceThreadId):\(sourceItemId)" }

        var json: JSON {
            ["visibility": .string(visibility), "item": item.raw,
             "sourceThreadId": .string(sourceThreadId), "sourceItemId": .string(sourceItemId)]
        }
    }

    /// Progressive history (`acceptBoundedSnapshot`): the snapshot holds a recent window, older
    /// rows come in pages over HTTP.
    struct History: Equatable, Sendable {
        /// Opaque; the next older page starts here.
        var cursor: String?
        var hasMore = false
        /// The highest local turn ordinal the server knew at snapshot time. Updates to items
        /// older than the window are dropped rather than appended out of place.
        var latestLocalTurnOrdinal: Int?

        /// The timeline is a window: something older is not loaded.
        var isPartial: Bool { hasMore || cursor != nil }

        /// From a `snapshot` stream item; a full snapshot (no history fields) resets it.
        init(snapshot item: JSON) {
            cursor = item["historyCursor"]?.nonNull?.string
            hasMore = item["hasMoreHistory"]?.bool ?? false
            latestLocalTurnOrdinal = item["latestLocalTurnOrdinal"]?.nonNull?.int
        }

        init() {}
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
        rows = (json["visibleTurnItems"]?.array ?? []).compactMap(Row.init(json:))
        // Items referenced by visible rows count as known items too.
        for row in rows where items[row.item.id] == nil { items[row.item.id] = row.item }
    }

    /// A `snapshot` item of `orchestration.subscribeThread`: the projection and its history window.
    init?(snapshot item: JSON) {
        guard let json = item["projection"] else { return nil }
        self.init(json: json)
        history = History(snapshot: item)
    }

    /// The projection as a `snapshot` item, for the local cache; `init(snapshot:)` reads it back.
    /// A timeline longer than `maxRows` keeps its newest rows and drops the history cursor:
    /// what was cut comes back with the server's next snapshot.
    func snapshotItem(maxRows: Int = .max) -> JSON {
        var keptRows = rows
        var keptItems = Array(items.values)
        var history = history
        if rows.count > maxRows {
            keptRows = Array(rows.suffix(maxRows))
            let ids = Set(keptRows.map(\.item.id))
            let oldest = keptRows.filter { $0.visibility == "local" }.map(\.item.ordinal).min() ?? .min
            keptItems.removeAll { !ids.contains($0.id) && $0.ordinal < oldest }
            history = History()
        }
        let projection: JSON = [
            "thread": threadJSON,
            "runs": .array(runs.values.map(\.raw)),
            "attempts": .array(attempts.values.map(\.raw)),
            "runtimeRequests": .array(runtimeRequests.values.map(\.raw)),
            "providerSessions": .array(providerSessions.values.map(\.raw)),
            "providerThreads": .array(providerThreads.values.map(\.raw)),
            "checkpoints": .array(checkpoints.values.map(\.raw)),
            "messages": .array(Array(messages.values)),
            "turnItems": .array(keptItems.map(\.raw)),
            "visibleTurnItems": .array(keptRows.map(\.json)),
        ]
        var item: [String: JSON] = ["kind": "snapshot", "projection": projection, "hasMoreHistory": .bool(history.hasMore)]
        if let cursor = history.cursor { item["historyCursor"] = .string(cursor) }
        if let ordinal = history.latestLocalTurnOrdinal { item["latestLocalTurnOrdinal"] = .number(Double(ordinal)) }
        return .object(item)
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
            let partial = history.isPartial
            // Something older than the loaded window changed: it shows up when its page loads.
            if partial, items[item.id] == nil, isOutsideWindow(item) { break }
            let previous = items[item.id]
            items[item.id] = item
            if item.type == "run_interrupt_request" || previous?.type == "run_interrupt_request" {
                recomputeVisibility()
            }
            upsertRow(item, partial: partial)
            if partial, item.ordinal > (history.latestLocalTurnOrdinal ?? Int.min) {
                history.latestLocalTurnOrdinal = item.ordinal
            }
        default:
            break
        }
        return true
    }

    private mutating func upsertRow(_ item: TurnItem, partial: Bool) {
        let existing = rows.firstIndex { $0.visibility == "local" && $0.item.id == item.id }
        guard isVisible(item) else {
            if let existing { rows.remove(at: existing) }
            return
        }
        if existing == nil, partial, isOutsideWindow(item) { return }
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

    /// `shouldDropMissingPartialTurnItem`: not a visible row, and at or below the snapshot's
    /// watermark or older than the oldest loaded local row.
    private func isOutsideWindow(_ item: TurnItem) -> Bool {
        if rows.contains(where: { $0.item.id == item.id }) { return false }
        if let watermark = history.latestLocalTurnOrdinal, item.ordinal <= watermark { return true }
        guard let oldest = rows.filter({ $0.visibility == "local" }).map(\.item.ordinal).min() else { return false }
        return item.ordinal < oldest
    }

    // MARK: History pages

    /// Prepends an older page (`OrchestrationV2ThreadHistoryPage`, rows oldest first) as
    /// `mergeOlderHistoryIntoProjection` does: rows already present are skipped, and an item a
    /// live event already changed keeps that version (so a hidden one isn't resurrected).
    mutating func mergeOlder(page: JSON) {
        var keys = Set(rows.map(\.key))
        var prepended: [Row] = []
        for json in page["items"]?.array ?? [] {
            guard var row = Row(json: json), !keys.contains(row.key) else { continue }
            if row.visibility == "local" || row.sourceThreadId == thread.id, let current = items[row.sourceItemId] {
                // Retained interrupt requests live outside the window and join it with their page.
                guard current.type == "run_interrupt_request", isVisible(current) else { continue }
                row.item = current
            }
            keys.insert(row.key)
            prepended.append(row)
        }
        for row in prepended where row.visibility == "local" || row.sourceThreadId == thread.id {
            if items[row.sourceItemId] == nil { items[row.sourceItemId] = row.item }
        }
        rows = prepended + rows
        history.cursor = page["nextCursor"]?.nonNull?.string
        history.hasMore = page["hasMoreHistory"]?.bool ?? false
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
                let message = run.userMessageId.flatMap { messages[$0] }
                return QueuedMessage(
                    id: run.id,
                    text: message?["text"]?.string ?? "",
                    held: run.queueHeld,
                    attachments: (message?["attachments"]?.array ?? []).compactMap(ChatAttachment.init(json:)),
                    context: message?["context"]?.nonNull
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
                let tool = toolItem(forRequest: request.id)
                let detail = tool?.raw["input"]?.string
                    ?? (tool?.raw["changes"]?.array?.compactMap { $0["path"]?.string }.joined(separator: "\n"))
                    ?? tool?.raw["fileName"]?.string
                return PendingRequest(
                    id: request.id,
                    kind: .approval(
                        requestKind: item?.raw["requestKind"]?.string ?? request.kind,
                        prompt: item?.raw["prompt"]?.string,
                        detail: detail,
                        appName: item?.raw["appName"]?.string,
                        options: options
                    ),
                    canRespond: request.responseCapability == "live",
                    createdAt: request.createdAt
                )
            }
    }

    /// The tool call a runtime request is about. Provider request ids embed the native tool id
    /// (`…native-request:<toolId>:…`), the same id the tool's turn item carries.
    func toolItem(forRequest requestId: String) -> TurnItem? {
        guard let range = requestId.range(of: "native-request:") else { return nil }
        let toolId = requestId[range.upperBound...].split(separator: ":").first.map(String.init) ?? ""
        guard !toolId.isEmpty else { return nil }
        return items.values.first {
            $0.type != "approval_request" && $0.id.hasSuffix("native-item:\(toolId)")
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
