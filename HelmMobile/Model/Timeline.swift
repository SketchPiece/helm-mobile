import Foundation

/// What the thread screen draws: the server's timeline folded into readable blocks. Tool calls,
/// reasoning and other agent work between two messages become one collapsible "work" block, so
/// the conversation reads as a conversation and the details are one tap away.
enum TimelineBlock: Identifiable, Hashable {
    case user(TurnItem)
    case assistant(TurnItem)
    case work(id: String, items: [TurnItem], isLive: Bool)
    case plan(TurnItem)
    case todo(TurnItem)
    case changes(TurnItem)
    case error(TurnItem)
    case notice(TurnItem)
    /// A finished turn's work, folded: "Worked for 3m 12s". `key` toggles it open.
    case fold(key: String, label: String, expanded: Bool)

    var id: String {
        switch self {
        case .user(let item), .assistant(let item), .plan(let item), .todo(let item), .changes(let item),
             .error(let item), .notice(let item):
            item.id
        case .work(let id, _, _):
            "work:\(id)"
        case .fold(let key, _, _):
            "fold:\(key)"
        }
    }

    /// The items a block was built from, for grouping blocks by turn.
    var items: [TurnItem] {
        switch self {
        case .user(let item), .assistant(let item), .plan(let item), .todo(let item), .changes(let item),
             .error(let item), .notice(let item):
            [item]
        case .work(_, let items, _):
            items
        case .fold:
            []
        }
    }
}

enum Timeline {
    static let workTypes: Set<String> = [
        "reasoning", "command_execution", "file_change", "file_search", "web_search", "dynamic_tool",
        "subagent", "compaction", "approval_request", "user_input_request",
    ]

    static let noticeTypes: Set<String> = [
        "system_notice", "run_interrupt_request", "run_interrupt_result", "notification", "handoff", "fork",
        "thread_created",
    ]

    /// Folds visible rows into blocks. `liveRunId` marks the work block of the running turn as live.
    static func blocks(from items: [TurnItem], liveRunId: String?) -> [TimelineBlock] {
        var blocks: [TimelineBlock] = []
        var pendingWork: [TurnItem] = []

        func flushWork() {
            guard let first = pendingWork.first else { return }
            let isLive = liveRunId != nil && pendingWork.contains { $0.runId == liveRunId }
            blocks.append(.work(id: first.id, items: pendingWork, isLive: isLive))
            pendingWork.removeAll()
        }

        for item in items {
            // Nested work (a subagent's own steps) is summarised by its parent row.
            if item.parentItemId != nil { continue }
            // Workspace preparation is plumbing; only a failure is worth showing.
            if item.id.contains("workspace-preparation") {
                if item.status == "failed" {
                    flushWork()
                    blocks.append(.error(item))
                }
                continue
            }
            switch item.type {
            case "user_message":
                flushWork()
                blocks.append(.user(item))
            case "assistant_message":
                // Empty assistant placeholders while the model starts don't deserve a bubble.
                if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                flushWork()
                blocks.append(.assistant(item))
            case "proposed_plan":
                flushWork()
                blocks.append(.plan(item))
            case "todo_list":
                flushWork()
                blocks.append(.todo(item))
            case "checkpoint":
                guard !(item.raw["files"]?.array ?? []).isEmpty else { continue }
                flushWork()
                blocks.append(.changes(item))
            case "error":
                flushWork()
                blocks.append(.error(item))
            case _ where noticeTypes.contains(item.type):
                // Notices about the parent fork/thread creation are noise in a phone timeline.
                if item.type == "thread_created" || item.type == "fork" { continue }
                flushWork()
                blocks.append(.notice(item))
            default:
                pendingWork.append(item)
            }
        }
        flushWork()

        // Keep only the latest todo list; earlier versions are the same list in progress.
        if let lastTodo = blocks.lastIndex(where: { if case .todo = $0 { true } else { false } }) {
            blocks = blocks.enumerated().filter { index, block in
                if case .todo = block { return index == lastTodo }
                return true
            }.map(\.element)
        }
        return blocks
    }

    /// Folds every finished turn like the T3 Code clients do (`threadActivity.ts`
    /// `deriveThreadFeedRunFolds`): the first and the final agent message stay, everything in
    /// between hides behind "Worked for …" until opened. The running turn, a stopped or failed
    /// one, and one still streaming stay open. Turns without a run (imported history) fold per prompt.
    static func folded(_ blocks: [TimelineBlock], runs: [String: Run], activeRunId: String?, isWorking: Bool,
                       expanded: Set<String>) -> [TimelineBlock] {
        struct Group {
            var key: String
            var indices: [Int] = []
            var startedAt: Date?
        }
        var groups: [Group] = []
        var groupIndex: [String: Int] = [:]
        var runlessKey: String?
        var promptAt: Date?
        for (index, block) in blocks.enumerated() {
            if case .user(let item) = block {
                runlessKey = item.runId == nil ? "runless:\(item.id)" : nil
                promptAt = item.startedAt ?? item.completedAt
                continue
            }
            guard let key = block.items.first(where: { $0.runId != nil })?.runId ?? runlessKey else { continue }
            if let existing = groupIndex[key] {
                groups[existing].indices.append(index)
            } else {
                groupIndex[key] = groups.count
                groups.append(Group(key: key, indices: [index], startedAt: promptAt))
                promptAt = nil
            }
        }

        var hidden: Set<Int> = []
        var foldAt: [Int: TimelineBlock] = [:]
        for (position, group) in groups.enumerated() {
            let isLast = position == groups.count - 1
            if group.key == activeRunId || (isWorking && isLast) { continue }
            let groupBlocks = group.indices.map { blocks[$0] }
            let stopped = groupBlocks.contains { block in
                if case .error = block { return true }
                if case .notice(let item) = block { return item.type == "run_interrupt_result" || item.type == "run_interrupt_request" }
                if case .assistant(let item) = block { return item.isStreaming }
                return false
            }
            if stopped || runs[group.key]?.status == "failed" { continue }
            let assistants = group.indices.filter { if case .assistant = blocks[$0] { true } else { false } }
            let keep = Set([assistants.first, assistants.last].compactMap { $0 })
            let toHide = group.indices.filter { index in
                if keep.contains(index) { return false }
                switch blocks[index] {
                case .changes, .plan: return false
                case .notice(let item): return !(item.type == "notification" || item.type == "handoff")
                default: return true
                }
            }
            // Only worth a fold when real work hides behind it.
            guard let first = toHide.first,
                  toHide.contains(where: { if case .work = blocks[$0] { true } else { false } } ) || toHide.count > 1
            else { continue }
            let isOpen = expanded.contains(group.key)
            if !isOpen { hidden.formUnion(toHide) }
            foldAt[first] = .fold(key: group.key, label: foldLabel(promptAt: group.startedAt, blocks: groupBlocks, run: runs[group.key]), expanded: isOpen)
        }

        var result: [TimelineBlock] = []
        for (index, block) in blocks.enumerated() {
            if let fold = foldAt[index] { result.append(fold) }
            if !hidden.contains(index) { result.append(block) }
        }
        return result
    }

    private static func foldLabel(promptAt: Date?, blocks: [TimelineBlock], run: Run?) -> String {
        let items = blocks.flatMap(\.items)
        let start = run?.startedAt ?? run?.requestedAt ?? promptAt ?? items.compactMap(\.startedAt).min()
        let end = run?.completedAt ?? items.compactMap { $0.completedAt ?? $0.startedAt }.max()
        guard let start, let end, end > start else { return String(localized: "Worked") }
        return String(localized: "Worked for \(duration(end.timeIntervalSince(start)))")
    }

    /// "45s", "3m 12s", "1h 5m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return String(localized: "\(total)s") }
        if total < 3600 { return String(localized: "\(total / 60)m \(total % 60)s") }
        return String(localized: "\(total / 3600)h \((total % 3600) / 60)m")
    }

    /// One line describing a work item, e.g. "Ran `npm test`" or "Edited Shell.swift".
    static func summary(of item: TurnItem) -> (symbol: String, text: String, detail: String?) {
        let raw = item.raw
        switch item.type {
        case "reasoning":
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .replacingOccurrences(of: "**", with: "")
            return ("brain", item.isRunning ? String(localized: "Thinking") : (firstLine ?? String(localized: "Thought")), nil)
        case "command_execution":
            let command = raw["input"]?.string ?? item.title ?? ""
            var detail: String?
            if let exit = raw["exitCode"]?.int, exit != 0 { detail = String(localized: "exit \(exit)") }
            return ("terminal", command, detail)
        case "file_change":
            let name = raw["fileName"]?.string ?? item.title ?? String(localized: "file")
            let adds = raw["additions"]?.int
            let dels = raw["deletions"]?.int
            let detail = (adds != nil || dels != nil) ? "+\(adds ?? 0) −\(dels ?? 0)" : nil
            return ("pencil", (name as NSString).lastPathComponent, detail)
        case "file_search":
            let pattern = raw["pattern"]?.string ?? item.title ?? ""
            let count = raw["results"]?.array?.count
            return ("magnifyingglass", pattern, count.map { String(localized: "\($0) found") })
        case "web_search":
            let query = raw["patterns"]?.array?.compactMap(\.string).joined(separator: ", ") ?? item.title ?? ""
            return ("globe", query, nil)
        case "dynamic_tool":
            let name = raw["toolName"]?.string ?? item.title ?? String(localized: "Tool")
            return ("wrench.and.screwdriver", item.title ?? name, nil)
        case "subagent":
            let title = raw["prompt"]?.string?.split(whereSeparator: \.isNewline).first.map(String.init)
            return ("person.2", item.title ?? title ?? String(localized: "Subagent"), nil)
        case "compaction":
            return ("arrow.down.right.and.arrow.up.left", String(localized: "Compacted the conversation"), nil)
        case "approval_request":
            return ("hand.raised", raw["prompt"]?.string ?? item.title ?? String(localized: "Asked for approval"), nil)
        case "user_input_request":
            let question = raw["questions"]?[0]?["question"]?.string
            return ("questionmark.bubble", question ?? String(localized: "Asked a question"), nil)
        default:
            return ("circle.dotted", item.title ?? item.type.replacingOccurrences(of: "_", with: " "), nil)
        }
    }

    /// "Ran 3 commands, edited 2 files" for a collapsed work block.
    static func groupSummary(_ items: [TurnItem]) -> String {
        var commands = 0, edits = 0, searches = 0, tools = 0, agents = 0
        var thoughts = 0, questions = 0, approvals = 0
        for item in items {
            switch item.type {
            case "user_input_request": questions += 1
            case "approval_request": approvals += 1
            case "dynamic_tool" where item.raw["toolName"]?.string == "AskUserQuestion": continue
            case "command_execution": commands += 1
            case "file_change": edits += 1
            case "file_search", "web_search": searches += 1
            case "subagent": agents += 1
            case "reasoning": thoughts += 1
            default: tools += 1
            }
        }
        var parts: [String] = []
        if commands > 0 { parts.append(String(localized: "\(commands) commands")) }
        if edits > 0 { parts.append(String(localized: "\(edits) edits")) }
        if searches > 0 { parts.append(String(localized: "\(searches) searches")) }
        if agents > 0 { parts.append(String(localized: "\(agents) agents")) }
        if tools > 0 { parts.append(String(localized: "\(tools) tools")) }
        if questions > 0 { parts.append(String(localized: "\(questions) questions")) }
        if approvals > 0 { parts.append(String(localized: "\(approvals) approvals")) }
        if parts.isEmpty, thoughts > 0 { return String(localized: "Thought") }
        return parts.joined(separator: " · ")
    }
}
