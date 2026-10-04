import Foundation

/// A prompt Helm runs on a schedule in a project (`scheduledTasks.*`, contracts/scheduledTask.ts).
struct ScheduledTask: Identifiable, Hashable, Sendable {
    enum Schedule: Hashable, Sendable {
        case interval(everyMs: Int)
        /// "HH:MM" in the Mac's time zone; weekdays 0 = Sunday … 6 = Saturday, nil for every day.
        case fixedTime(timeOfDay: String, weekdays: [Int]?)

        init?(json: JSON?) {
            switch json?["type"]?.string {
            case "interval":
                guard let every = json?["everyMs"]?.int else { return nil }
                self = .interval(everyMs: every)
            case "fixed_time":
                guard let time = json?["timeOfDay"]?.string else { return nil }
                self = .fixedTime(timeOfDay: time, weekdays: json?["weekdays"]?.array?.compactMap(\.int))
            default:
                return nil
            }
        }

        var json: JSON {
            switch self {
            case .interval(let every): ["type": "interval", "everyMs": .number(Double(every))]
            case let .fixedTime(time, weekdays):
                if let weekdays { ["type": "fixed_time", "timeOfDay": .string(time), "weekdays": .array(weekdays.map { .number(Double($0)) })] }
                else { ["type": "fixed_time", "timeOfDay": .string(time)] }
            }
        }
    }

    /// Where a run happens: the project's checkout, a new worktree from a base branch, or a
    /// specific existing checkout. `branch` is kept as-is when editing.
    enum Workspace: Hashable, Sendable {
        case root(branch: String?)
        case existingWorktree(path: String, branch: String?)
        case worktree(baseRef: String, branch: String?, startFromOrigin: Bool?)

        init?(json: JSON?) {
            let branch = json?["branch"]?.string
            switch json?["type"]?.string {
            case "root": self = .root(branch: branch)
            case "existing_worktree":
                guard let path = json?["worktreePath"]?.string else { return nil }
                self = .existingWorktree(path: path, branch: branch)
            case "worktree":
                guard let base = json?["baseRef"]?.string else { return nil }
                self = .worktree(baseRef: base, branch: branch, startFromOrigin: json?["startFromOrigin"]?.bool)
            default: return nil
            }
        }

        var json: JSON {
            var object: [String: JSON]
            let branch: String?
            switch self {
            case .root(let value):
                object = ["type": "root"]
                branch = value
            case let .existingWorktree(path, value):
                object = ["type": "existing_worktree", "worktreePath": .string(path)]
                branch = value
            case let .worktree(base, value, startFromOrigin):
                object = ["type": "worktree", "baseRef": .string(base)]
                if let startFromOrigin { object["startFromOrigin"] = .bool(startFromOrigin) }
                branch = value
            }
            if let branch { object["branch"] = .string(branch) }
            return .object(object)
        }
    }

    var id: String
    var title: String
    var prompt: String
    var enabled: Bool
    var schedule: Schedule
    var projectId: String
    var threadId: String?
    var workspace: Workspace
    var modelSelection: ModelSelection
    var runtimeMode: String
    var interactionMode: String
    var creationSource: String?
    var nextRunAt: Date?
    var lastRunAt: Date?
    /// never | running | succeeded | failed
    var lastRunStatus: String
    var lastRunError: String?
    var runCount: Int

    init?(json: JSON) {
        guard let id = json["id"]?.string, let title = json["title"]?.string, let prompt = json["prompt"]?.string,
              let schedule = Schedule(json: json["schedule"]), let projectId = json["projectId"]?.string,
              let workspace = Workspace(json: json["workspaceStrategy"]),
              let modelSelection = ModelSelection(json: json["modelSelection"])
        else { return nil }
        self.id = id
        self.title = title
        self.prompt = prompt
        self.schedule = schedule
        self.projectId = projectId
        self.workspace = workspace
        self.modelSelection = modelSelection
        enabled = json["enabled"]?.bool ?? false
        threadId = json["threadId"]?.nonNull?.string
        runtimeMode = json["runtimeMode"]?.string ?? "full-access"
        interactionMode = json["interactionMode"]?.string ?? "default"
        creationSource = json["creationSource"]?.string
        nextRunAt = ISODate.parse(json["nextRunAt"]?.nonNull?.string)
        lastRunAt = ISODate.parse(json["lastRunAt"]?.nonNull?.string)
        lastRunStatus = json["lastRunStatus"]?.string ?? "never"
        lastRunError = json["lastRunError"]?.nonNull?.string
        runCount = json["runCount"]?.int ?? 0
    }

    /// `scheduledTasks.list` / `.subscribe` results: `{tasks: [...]}`, skipping rows this build can't read.
    static func list(_ json: JSON) -> [ScheduledTask] {
        (json["tasks"]?.array ?? []).compactMap(ScheduledTask.init(json:))
    }
}

/// The editor's form, mirroring RN's `scheduledTaskDraft.ts`: defaults for a new task, the
/// fields of an existing one, and the `scheduledTasks.upsert` payload.
struct ScheduledTaskDraft: Equatable {
    enum ScheduleMode: Hashable { case fixedTime, interval }
    enum WorkspaceMode: String, CaseIterable, Identifiable, Hashable {
        case worktree, root, existingWorktree
        var id: String { rawValue }
        var title: String {
            switch self {
            case .worktree: String(localized: "New worktree")
            case .root: String(localized: "Project checkout")
            case .existingWorktree: String(localized: "Specific checkout")
            }
        }
    }

    var task: ScheduledTask?
    var title = ""
    var prompt = ""
    var projectId: String?
    var modelSelection: ModelSelection?
    /// Once the user picks a model, changing the project no longer resets it.
    var modelSelectionIsExplicit = false
    var scheduleMode = ScheduleMode.fixedTime
    var timeOfDay = "09:00"
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var intervalMinutes = "15"
    var workspace = WorkspaceMode.worktree
    var baseRef = "main"
    var checkoutPath = ""
    var enabled = true
    var startFromOrigin = true
    var runtimeMode = "full-access"
    var interactionMode = "default"

    init(projectId: String?, modelSelection: ModelSelection?) {
        self.projectId = projectId
        self.modelSelection = modelSelection
    }

    init(editing task: ScheduledTask) {
        self.task = task
        title = task.title
        prompt = task.prompt
        projectId = task.projectId
        modelSelection = task.modelSelection
        modelSelectionIsExplicit = true
        switch task.schedule {
        case let .fixedTime(time, days):
            timeOfDay = time
            weekdays = days.flatMap { $0.isEmpty ? nil : Set($0) } ?? Set(0...6)
        case .interval(let every):
            scheduleMode = .interval
            intervalMinutes = Self.minutesText(max(1, Double(every) / 60_000))
        }
        switch task.workspace {
        case .root: workspace = .root
        case .existingWorktree(let path, _):
            workspace = .existingWorktree
            checkoutPath = path
        case let .worktree(base, _, origin):
            workspace = .worktree
            baseRef = base
            startFromOrigin = origin ?? false
        }
        enabled = task.enabled
        runtimeMode = task.runtimeMode
        interactionMode = task.interactionMode
    }

    private static func minutesText(_ minutes: Double) -> String {
        minutes.rounded() == minutes ? String(Int(minutes)) : String(minutes)
    }

    /// The schedule to save, or nil when the time, days or interval are invalid.
    var schedule: ScheduledTask.Schedule? {
        switch scheduleMode {
        case .interval:
            guard let minutes = Double(intervalMinutes.replacingOccurrences(of: ",", with: ".")), minutes >= 1 else { return nil }
            // Rounding undoes float noise from showing existing millisecond intervals as minutes.
            let every = (minutes * 60_000).rounded()
            guard every < 9_007_199_254_740_991 else { return nil }
            return .interval(everyMs: Int(every))
        case .fixedTime:
            guard timeOfDay.range(of: #"^([01]?\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil,
                  !weekdays.isEmpty, weekdays.allSatisfy({ (0...6).contains($0) })
            else { return nil }
            return .fixedTime(timeOfDay: timeOfDay, weekdays: weekdays.count == 7 ? nil : weekdays.sorted())
        }
    }

    enum Problem: Error, Equatable {
        case incomplete
        case projectUnavailable
    }

    /// `scheduledTasks.upsert` input. Edits carry `id` + `requireExisting` so a task deleted
    /// elsewhere is not recreated.
    func upsertPayload(knownProjectIds: Set<String>) throws(Problem) -> JSON {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = checkoutPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !prompt.isEmpty, let projectId, let modelSelection, let schedule,
              workspace != .existingWorktree || !path.isEmpty
        else { throw .incomplete }
        guard knownProjectIds.contains(projectId) else { throw .projectUnavailable }
        let strategy: ScheduledTask.Workspace = switch workspace {
        case .root: .root(branch: nil)
        case .existingWorktree: .existingWorktree(path: path, branch: nil)
        case .worktree:
            .worktree(baseRef: baseRef.trimmingCharacters(in: .whitespaces).isEmpty ? "main" : baseRef.trimmingCharacters(in: .whitespaces),
                      branch: nil, startFromOrigin: startFromOrigin)
        }
        var payload: [String: JSON] = [
            "title": .string(title),
            "prompt": .string(prompt),
            "projectId": .string(projectId),
            "modelSelection": modelSelection.json,
            "schedule": schedule.json,
            "enabled": .bool(enabled),
            "threadId": task?.threadId.map(JSON.string) ?? .null,
            "workspaceStrategy": strategy.json,
            "runtimeMode": .string(runtimeMode),
            "interactionMode": .string(interactionMode),
            "creationSource": .string(task?.creationSource ?? "mobile"),
        ]
        if let task {
            payload["id"] = .string(task.id)
            payload["requireExisting"] = true
        }
        return .object(payload)
    }
}

/// How the list and editor describe a schedule (RN `scheduledTaskPresentation.ts`).
enum ScheduledTaskText {
    /// Monday first, as the RN picker lists them.
    static let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]

    static func weekdayShort(_ day: Int, calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols  // Sunday first
        return symbols[(day % 7 + 7) % 7]
    }

    static func repeatLabel(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        if weekdays.count == 7 { return String(localized: "Every day") }
        if weekdays == [1, 2, 3, 4, 5] { return String(localized: "Weekdays") }
        if weekdays.isEmpty { return String(localized: "Choose days") }
        return weekdayOrder.filter(weekdays.contains).map { weekdayShort($0, calendar: calendar) }.joined(separator: ", ")
    }

    /// "Weekdays at 9:00", "Every 15 minutes".
    static func describe(_ schedule: ScheduledTask.Schedule, calendar: Calendar = .current) -> String {
        switch schedule {
        case .interval(let every): return interval(every)
        case let .fixedTime(time, weekdays):
            let days = weekdays.flatMap { $0.isEmpty ? nil : Set($0) }.map { repeatLabel($0, calendar: calendar) } ?? String(localized: "Every day")
            return String(localized: "\(days) at \(timeLabel(time, calendar: calendar))")
        }
    }

    static func timeLabel(_ timeOfDay: String, calendar: Calendar = .current) -> String {
        let parts = timeOfDay.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date()) else { return timeOfDay }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current,
                                               calendar: calendar, timeZone: calendar.timeZone))
    }

    /// "Every hour", "Every 1 day, 6 hours".
    static func interval(_ everyMs: Int) -> String {
        let seconds = Double(everyMs) / 1000
        switch seconds {
        case 60: return String(localized: "Every minute")
        case 3600: return String(localized: "Every hour")
        case 86_400: return String(localized: "Every day")
        case 604_800: return String(localized: "Every week")
        default:
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.weekOfMonth, .day, .hour, .minute, .second]
            let text = formatter.string(from: seconds) ?? "\(Int(seconds)) s"
            return String(localized: "Every \(text)")
        }
    }

    /// "Next run in 5 minutes", "Next run tomorrow at 9:00", "Next run Monday at 9:00", "Next run Oct 12 at 9:00".
    static func nextRun(_ next: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let remaining = next.timeIntervalSince(now)
        if remaining <= 0 { return String(localized: "Next run due") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: next)).day ?? 0
        if days == 0 {
            if remaining < 60 { return String(localized: "Next run in less than a minute") }
            if remaining < 3600 { return String(localized: "Next run in \(Int((remaining / 60).rounded())) minutes") }
            return String(localized: "Next run in \(Int((remaining / 3600).rounded())) hours")
        }
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let time = next.formatted(style)
        if days == 1 { return String(localized: "Next run tomorrow at \(time)") }
        if days <= 7 {
            let weekday = next.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
            return String(localized: "Next run \(weekday) at \(time)")
        }
        var dateStyle = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: next) != calendar.component(.year, from: now) { dateStyle = dateStyle.year() }
        return String(localized: "Next run \(next.formatted(dateStyle)) at \(time)")
    }
}
