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
    /// `repositoryIdentity.displayName` ("acme/app"); `#` pull request search needs it.
    var repositoryName: String?

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
        repositoryName = json["repositoryIdentity"]?.nonNull?["displayName"]?.string
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
    var unsettledAt: Date?
    var pinOrderKey: String?
    var activeOrderKey: String?
    var autoSettleDisabledAt: Date?
    var latestRunId: String?
    /// Kept as sent: limit recovery commands must echo it verbatim (the server compares strings).
    var usageLimitResetAt: String?
    var limitRecovery: LimitRecovery?
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
        unsettledAt = ISODate.parse(json["unsettledAt"]?.nonNull?.string)
        pinOrderKey = json["pinOrderKey"]?.nonNull?.string
        activeOrderKey = json["activeOrderKey"]?.nonNull?.string
        autoSettleDisabledAt = ISODate.parse(json["autoSettleDisabledAt"]?.nonNull?.string)
        latestRunId = json["latestRunId"]?.nonNull?.string
        usageLimitResetAt = json["usageLimitResetAt"]?.nonNull?.string
        limitRecovery = json["limitRecovery"]?.nonNull.flatMap(LimitRecovery.init(json:))
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

    mutating func setOrderKey(_ key: String?, pinned: Bool) {
        if pinned { pinOrderKey = key } else { activeOrderKey = key }
    }

    var displayTitle: String { title.isEmpty ? String(localized: "New thread") : title }

    /// What the user chose for a usage-limit-blocked run (`OrchestrationV2LimitRecovery`).
    struct LimitRecovery: Hashable, Sendable {
        var runId: String
        var resetAt: String
        var autoResume: Bool
        var snooze: Bool

        init?(json: JSON) {
            guard let runId = json["runId"]?.string, let resetAt = json["resetAt"]?.string else { return nil }
            self.runId = runId
            self.resetAt = resetAt
            autoResume = json["autoResume"]?.bool ?? false
            snooze = json["snooze"]?.bool ?? false
        }
    }

    /// The usage-limit card's state (RN `UsageLimitRecoveryCard`). Nil unless the latest run
    /// failed on a usage limit.
    var usageLimitRecovery: UsageLimitRecoveryState? {
        guard status == "failed", lastErrorClass == "usage_limit", let runId = latestRunId else { return nil }
        let reset = ISODate.parse(usageLimitResetAt)
        let ended = latestRunCompletedAt ?? updatedAt ?? .distantPast
        let matches = limitRecovery?.runId == runId && limitRecovery?.resetAt == usageLimitResetAt
        return UsageLimitRecoveryState(
            runId: runId,
            resetAt: usageLimitResetAt,
            resetDate: reset,
            canSchedule: reset.map { $0 > ended } ?? false,
            autoResume: matches && limitRecovery?.autoResume == true,
            snoozed: matches && limitRecovery?.snooze == true && reset != nil && snoozedUntil == reset
        )
    }
}

struct UsageLimitRecoveryState: Hashable, Sendable {
    var runId: String
    var resetAt: String?
    var resetDate: Date?
    /// The provider reported a reset time after the run ended, so recovery can be scheduled.
    var canSchedule: Bool
    var autoResume: Bool
    var snoozed: Bool
}

/// Projects and active threads for one environment, kept current by the shell stream.
struct ShellState: Sendable {
    var sequence: Int = 0
    var projects: [String: Project] = [:]
    var threads: [String: ThreadSummary] = [:]
    var isSynchronized = false
    /// Order keys this phone wrote that the server hasn't echoed yet. The row moves at once and
    /// stays put if an unrelated update for the thread arrives before the echo.
    private(set) var pendingOrderKeys: [String: PendingOrderKey] = [:]

    struct PendingOrderKey: Sendable {
        var pinned: Bool
        var key: String
        /// The latest key the server reported, restored if the write fails.
        var serverKey: String?
    }

    mutating func setPendingOrderKey(threadId: String, pinned: Bool, key: String) {
        guard var thread = threads[threadId] else { return }
        let serverKey = pendingOrderKeys[threadId]?.serverKey ?? (pinned ? thread.pinOrderKey : thread.activeOrderKey)
        pendingOrderKeys[threadId] = PendingOrderKey(pinned: pinned, key: key, serverKey: serverKey)
        thread.setOrderKey(key, pinned: pinned)
        threads[threadId] = thread
    }

    mutating func revertPendingOrderKey(threadId: String) {
        guard let pending = pendingOrderKeys.removeValue(forKey: threadId), var thread = threads[threadId] else { return }
        thread.setOrderKey(pending.serverKey, pinned: pending.pinned)
        threads[threadId] = thread
    }

    /// Keeps a pending key over server rows until the server reports it (or the thread left
    /// the section the key belongs to).
    private mutating func reconcile(_ thread: ThreadSummary) -> ThreadSummary {
        guard var pending = pendingOrderKeys[thread.id] else { return thread }
        let incoming = pending.pinned ? thread.pinOrderKey : thread.activeOrderKey
        let leftSection = pending.pinned ? thread.pinnedAt == nil : (thread.pinnedAt != nil || thread.settledOverride == "settled")
        if incoming == pending.key || leftSection {
            pendingOrderKeys[thread.id] = nil
            return thread
        }
        pending.serverKey = incoming
        pendingOrderKeys[thread.id] = pending
        var overlaid = thread
        overlaid.setOrderKey(pending.key, pinned: pending.pinned)
        return overlaid
    }

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
            let previous = projects
            projects = Dictionary(
                (snapshot["projects"]?.array ?? []).compactMap(Project.init(json:)).map { ($0.id, $0) },
                uniquingKeysWith: { _, b in b }
            )
            // A reconnect snapshot can arrive before the server resolves repositories again.
            for (id, project) in projects where project.repositoryName == nil {
                if let old = previous[id], old.workspaceRoot == project.workspaceRoot {
                    projects[id]?.repositoryName = old.repositoryName
                }
            }
            threads = [:]
            for thread in (snapshot["threads"]?.array ?? []).compactMap(ThreadSummary.init(json:)) {
                threads[thread.id] = reconcile(thread)
            }
            pendingOrderKeys = pendingOrderKeys.filter { threads[$0.key] != nil }
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
                    threads[thread.id] = reconcile(thread)
                }
            case "thread.removed":
                if let id = item["threadId"]?.string { threads[id] = nil }
            default:
                break
            }
        }
    }
}
