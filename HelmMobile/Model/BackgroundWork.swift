import Foundation

/// Work a thread left running after its turn ended (`OrchestrationV2PendingBackgroundTask`):
/// a subagent it waits on, a background command, a monitor. The server fills the shell's
/// `pendingBackgroundTasks` once the run settles, so the list is empty while a run is active.
struct BackgroundTask: Identifiable, Hashable, Sendable {
    enum Kind: Int, Comparable, Sendable {
        // Raw values order the banner: subagents first, like the desktop.
        case subagent, command, monitor, backgroundTask

        init(wire: String?) {
            switch wire {
            case "subagent": self = .subagent
            case "command": self = .command
            case "monitor": self = .monitor
            // Unknown kinds, and rosters stored before kinds existed.
            default: self = .backgroundTask
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Commands (a dev server left running) don't wake the agent; the rest do.
        var holdsCompletion: Bool { self != .command }
    }

    var id: String
    var kind: Kind
    var description: String?
    var childThreadId: String?

    init?(json: JSON) {
        guard let id = json["taskId"]?.string, !id.isEmpty else { return nil }
        self.id = id
        kind = Kind(wire: json["kind"]?.string)
        let text = json["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        description = text?.isEmpty == false ? text : nil
        childThreadId = kind == .subagent ? json["childThreadId"]?.nonNull?.string : nil
    }

    /// The work's name, without the "Subagent: " prefix or a `/root/…/name` path.
    var name: String? {
        guard var text = description else { return nil }
        guard kind == .subagent else { return text }
        if text.lowercased().hasPrefix("subagent:") {
            text = text.dropFirst("subagent:".count).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("/root/"), let last = text.split(separator: "/").last {
            let words = last.replacingOccurrences(of: "_", with: " ").split(separator: " ")
            let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            if !name.isEmpty { text = name }
        }
        return text.isEmpty ? nil : text
    }
}

extension Array where Element == BackgroundTask {
    /// The thread stays "Waiting" (not done) while any of this will wake the agent.
    var holdsCompletion: Bool { contains { $0.kind.holdsCompletion } }

    /// "Waiting on subagent Review", "Waiting on 2 subagents and 1 command",
    /// or "Running: npm run dev" when only commands remain.
    var title: String? {
        guard !isEmpty else { return nil }
        let waiting = holdsCompletion
        if count == 1, let only = first {
            if let name = only.name {
                switch only.kind {
                case .subagent: return String(localized: "Waiting on subagent \(name)")
                case .monitor: return String(localized: "Waiting on monitor \(name)")
                case .backgroundTask: return String(localized: "Waiting on \(name)")
                case .command: return String(localized: "Running: \(name)")
                }
            }
            switch only.kind {
            case .subagent: return String(localized: "Waiting on a subagent")
            case .monitor: return String(localized: "Waiting on a monitor")
            case .backgroundTask: return String(localized: "Waiting on a background task")
            case .command: return String(localized: "Running a command")
            }
        }
        let counts = Dictionary(grouping: self, by: \.kind).mapValues(\.count)
        let groups = counts.keys.sorted().map { kind -> String in
            let count = counts[kind] ?? 0
            switch kind {
            case .subagent: return String(localized: "\(count) subagents")
            case .command: return String(localized: "\(count) commands")
            case .monitor: return String(localized: "\(count) monitors")
            case .backgroundTask: return String(localized: "\(count) background tasks")
            }
        }
        let list = groups.formatted(.list(type: .and))
        return waiting ? String(localized: "Waiting on \(list)") : String(localized: "Running \(list)")
    }
}
