import Foundation

struct ModelSelection: Hashable, Sendable {
    var instanceId: String
    var model: String
    var options: [String: JSON] = [:]

    init(instanceId: String, model: String, options: [String: JSON] = [:]) {
        self.instanceId = instanceId
        self.model = model
        self.options = options
    }

    init?(json: JSON?) {
        guard let json, let instanceId = json["instanceId"]?.string, let model = json["model"]?.string else { return nil }
        self.instanceId = instanceId
        self.model = model
        for option in json["options"]?.array ?? [] {
            if let id = option["id"]?.string, let value = option["value"] { options[id] = value }
        }
    }

    var json: JSON {
        var object: [String: JSON] = ["instanceId": .string(instanceId), "model": .string(model)]
        if !options.isEmpty {
            object["options"] = .array(options.keys.sorted().map { ["id": .string($0), "value": options[$0]!] })
        }
        return .object(object)
    }
}

struct Project: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var workspaceRoot: String
    var faviconPath: String?
    var iconEmoji: String?
    var iconColor: String?
    var monogram: String?
    var defaultModelSelection: ModelSelection?
    var updatedAt: Date?

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        title = json["title"]?.string ?? "Project"
        workspaceRoot = json["workspaceRoot"]?.string ?? ""
        faviconPath = json["faviconPath"]?.nonNull?.string
        let icon = json["projectIcon"]?.nonNull
        iconEmoji = icon?["emoji"]?.string
        iconColor = icon?["color"]?.string
        monogram = icon?["text"]?.string ?? icon?["monogramText"]?.string
        defaultModelSelection = ModelSelection(json: json["defaultModelSelection"]?.nonNull)
        updatedAt = ISODate.parse(json["updatedAt"]?.string)
    }

    var initials: String {
        if let monogram, !monogram.isEmpty { return String(monogram.prefix(2)) }
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(title.prefix(2)).uppercased()
    }
}

enum ThreadPhase: String, Sendable {
    case approval, input, working, failed, limited, done, idle
}

/// One row of the thread list (`OrchestrationV2ThreadShell`).
struct ThreadSummary: Identifiable, Hashable, Sendable {
    var id: String
    var projectId: String
    var title: String
    var modelSelection: ModelSelection?
    var runtimeMode: String
    var interactionMode: String
    var branch: String?
    var worktreePath: String?
    var status: String
    var activityRunStatus: String?
    var activityRunStartedAt: Date?
    var lastError: String?
    var lastErrorClass: String?
    var pendingRequestKind: String?
    var latestMessageText: String?
    var latestMessageRole: String?
    var hasActionableProposedPlan: Bool
    var createdAt: Date?
    var updatedAt: Date?
    var latestRunCompletedAt: Date?
    var settledOverride: String?
    var settledAt: Date?
    var snoozedUntil: Date?
    var pinnedAt: Date?
    var lastVisitedAt: Date?
    var parentThreadId: String?
    var relationshipToParent: String?
    var pullRequestNumber: Int?
    var pullRequestState: String?

    init?(json: JSON) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        projectId = json["projectId"]?.string ?? ""
        title = json["title"]?.string ?? ""
        modelSelection = ModelSelection(json: json["modelSelection"])
        runtimeMode = json["runtimeMode"]?.string ?? "full-access"
        interactionMode = json["interactionMode"]?.string ?? "default"
        branch = json["branch"]?.nonNull?.string
        worktreePath = json["worktreePath"]?.nonNull?.string
        status = json["status"]?.string ?? "idle"
        activityRunStatus = json["activityRunStatus"]?.nonNull?.string
        activityRunStartedAt = ISODate.parse(json["activityRunStartedAt"]?.nonNull?.string)
        lastError = json["lastError"]?.nonNull?.string
        lastErrorClass = json["lastErrorClass"]?.nonNull?.string
        let pending = json["pendingRuntimeRequest"]?.nonNull
        pendingRequestKind = pending?["kind"]?.string
        let latest = json["latestVisibleMessage"]?.nonNull
        latestMessageText = latest?["text"]?.string
        latestMessageRole = latest?["role"]?.string
        hasActionableProposedPlan = json["hasActionableProposedPlan"]?.bool ?? false
        createdAt = ISODate.parse(json["createdAt"]?.string)
        updatedAt = ISODate.parse(json["updatedAt"]?.string)
        latestRunCompletedAt = ISODate.parse(json["latestRunCompletedAt"]?.nonNull?.string)
        settledOverride = json["settledOverride"]?.nonNull?.string
        settledAt = ISODate.parse(json["settledAt"]?.nonNull?.string)
        snoozedUntil = ISODate.parse(json["snoozedUntil"]?.nonNull?.string)
        pinnedAt = ISODate.parse(json["pinnedAt"]?.nonNull?.string)
        lastVisitedAt = ISODate.parse(json["lastVisitedAt"]?.nonNull?.string)
        parentThreadId = json["lineage"]?["parentThreadId"]?.nonNull?.string
        relationshipToParent = json["lineage"]?["relationshipToParent"]?.nonNull?.string
        let pr = json["branchPullRequest"]?.nonNull ?? json["linkedPullRequest"]?.nonNull
        pullRequestNumber = pr?["number"]?.int
        pullRequestState = pr?["state"]?.string
    }

    var isWorking: Bool {
        activityRunStatus != nil || ["preparing", "queued", "starting", "running", "waiting"].contains(status)
    }

    var phase: ThreadPhase {
        if let kind = pendingRequestKind {
            return kind == "user_input" ? .input : .approval
        }
        if hasActionableProposedPlan { return .input }
        if isWorking { return .working }
        if status == "failed" {
            return lastErrorClass == "usage_limit" ? .limited : .failed
        }
        if isUnseenCompletion { return .done }
        return .idle
    }

    /// Finished since the user last looked at it.
    var isUnseenCompletion: Bool {
        guard let completed = latestRunCompletedAt else { return false }
        // Never-visited threads count as read, so a fresh install doesn't light up history.
        guard let visited = lastVisitedAt else { return false }
        return completed > visited
    }

    var needsAttention: Bool { phase == .approval || phase == .input }

    /// Hidden from the inbox until the wake time, unless it raised its hand meanwhile.
    func isSnoozed(now: Date = Date()) -> Bool {
        guard let snoozedUntil, snoozedUntil > now else { return false }
        return !needsAttention && !isWorking
    }

    /// Settled threads are history: the user (or auto-settle) put them away.
    var isSettled: Bool { settledOverride == "settled" && !isWorking && !needsAttention }

    var isSubagent: Bool { relationshipToParent == "subagent" }

    var displayTitle: String { title.isEmpty ? String(localized: "New thread") : title }
}

/// Projects and active threads for one environment, kept current by the shell stream.
struct ShellState: Sendable {
    var sequence: Int = 0
    var projects: [String: Project] = [:]
    var threads: [String: ThreadSummary] = [:]
    var isSynchronized = false

    /// Mirrors client-runtime's `applyShellStreamEvent`.
    mutating func apply(_ item: JSON) {
        switch item["kind"]?.string {
        case "synchronized":
            isSynchronized = true
        case "snapshot":
            guard let snapshot = item["snapshot"] else { return }
            if item["resolvedRepositoryIdentityRoots"] != nil, !projects.isEmpty {
                // Enrichment frame: projects' repository metadata only, threads are empty.
                for project in (snapshot["projects"]?.array ?? []).compactMap(Project.init(json:)) {
                    projects[project.id] = project
                }
                return
            }
            sequence = snapshot["snapshotSequence"]?.int ?? sequence
            projects = Dictionary(
                (snapshot["projects"]?.array ?? []).compactMap(Project.init(json:)).map { ($0.id, $0) },
                uniquingKeysWith: { _, b in b }
            )
            threads = Dictionary(
                (snapshot["threads"]?.array ?? []).compactMap(ThreadSummary.init(json:)).map { ($0.id, $0) },
                uniquingKeysWith: { _, b in b }
            )
        default:
            guard let seq = item["sequence"]?.int else { return }
            if seq <= sequence { return }
            sequence = seq
            switch item["kind"]?.string {
            case "project.updated":
                if let project = item["project"].flatMap(Project.init(json:)) { projects[project.id] = project }
            case "project.removed":
                if let id = item["projectId"]?.string { projects[id] = nil }
            case "thread.updated":
                guard let thread = item["thread"].flatMap(ThreadSummary.init(json:)) else { return }
                if item["location"]?.string == "archive" {
                    threads[thread.id] = nil
                } else {
                    threads[thread.id] = thread
                }
            case "thread.removed":
                if let id = item["threadId"]?.string { threads[id] = nil }
            default:
                break
            }
        }
    }
}
