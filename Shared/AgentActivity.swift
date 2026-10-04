import ActivityKit
import Foundation
import SwiftUI

/// The Live Activity type. Its shape is fixed by what the Volna core pushes (it was built for
/// expo-widgets): content-state `{name: "AgentActivity", props: "<aggregate JSON as a string>"}`.
/// Keep the name and fields; the core never sends `attributes-type`, but upstream relays do.
struct LiveActivityAttributes: ActivityAttributes {
    var url: String?

    struct ContentState: Codable, Hashable {
        var name: String
        var props: String?
    }
}

/// The aggregate the core computes over all agent work (`Volna core/src/helm/aggregate.ts`).
struct AgentAggregate: Codable, Hashable {
    var title: String
    var subtitle: String
    var activeCount: Int
    var updatedAt: String
    var activities: [Row]

    struct Row: Codable, Hashable {
        var environmentId: String
        var threadId: String
        var projectTitle: String
        var threadTitle: String
        var modelTitle: String
        var phase: String
        var status: String
        var updatedAt: String
        var deepLink: String
    }

    init(title: String, subtitle: String, activeCount: Int, updatedAt: String, activities: [Row]) {
        self.title = title
        self.subtitle = subtitle
        self.activeCount = activeCount
        self.updatedAt = updatedAt
        self.activities = activities
    }

    init?(state: LiveActivityAttributes.ContentState) {
        guard let props = state.props, let data = props.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AgentAggregate.self, from: data)
        else { return nil }
        self = decoded
    }

    var contentState: LiveActivityAttributes.ContentState {
        let json = (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
        return .init(name: "AgentActivity", props: json)
    }

    /// The card a local send starts with; the core repaints it within seconds.
    static func placeholder(projectTitle: String, threadTitle: String) -> AgentAggregate {
        let now = ISO8601DateFormatter.helmFractional.string(from: Date())
        return AgentAggregate(
            title: "Helm", subtitle: "Agent work in progress", activeCount: 1, updatedAt: now,
            activities: [Row(environmentId: "", threadId: "", projectTitle: projectTitle, threadTitle: threadTitle,
                             modelTitle: "", phase: "starting", status: "Connecting", updatedAt: now, deepLink: "/")]
        )
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let helmFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let helmPlain = ISO8601DateFormatter()

    static func helmDate(_ string: String) -> Date? {
        helmFractional.date(from: string) ?? helmPlain.date(from: string)
    }
}

/// Deep links shared by notifications, the Live Activity and the app.
enum HelmLink {
    static let scheme = "helm"

    /// `/threads/<env>/<thread>` (the core's deepLink) → app URL, or nil for "/".
    static func url(forPath path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.count > 1 else { return nil }
        return URL(string: "\(scheme):/\(path)")
    }

    /// Parses `helm://threads/<env>/<thread>`, `t3code://threads/…` or a bare `/threads/…` path.
    static func thread(from url: URL) -> (environmentId: String, threadId: String)? {
        var parts = url.path(percentEncoded: true).split(separator: "/").map(String.init)
        if let host = url.host(percentEncoded: true), !host.isEmpty { parts.insert(host, at: 0) }
        return thread(fromParts: parts)
    }

    static func thread(fromPath path: String) -> (environmentId: String, threadId: String)? {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"), !path.contains("#") else { return nil }
        return thread(fromParts: path.split(separator: "/").map(String.init))
    }

    private static func thread(fromParts parts: [String]) -> (environmentId: String, threadId: String)? {
        guard parts.count == 3, parts[0] == "threads",
              let environment = parts[1].removingPercentEncoding, let thread = parts[2].removingPercentEncoding,
              !environment.isEmpty, !thread.isEmpty
        else { return nil }
        return (environment, thread)
    }
}

/// Lamp colours per phase (Helm Live Activity, variant A).
enum PhaseTint {
    static func color(_ phase: String, dark: Bool) -> Color {
        let hex: UInt32 = switch phase {
        case "waiting_for_approval": dark ? 0xF2B550 : 0x9C6A1B
        case "waiting_for_input": dark ? 0xB9A6EF : 0x6B55B8
        case "failed": dark ? 0xEA7862 : 0xB8321F
        case "completed": dark ? 0x8FC56A : 0x3E7A2E
        default: dark ? 0x6FC9C1 : 0x257A73
        }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The Helm signal trace, as a shape for any size (the mark's amber line).
struct HelmSignal: Shape {
    func path(in rect: CGRect) -> Path {
        // Drawn on the mark's 120-unit grid, x 26…93, y 47…73; scaled into `rect`.
        let sx = rect.width / 67, sy = rect.height / 26
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + (x - 26) * sx, y: rect.minY + (y - 47) * sy) }
        var path = Path()
        path.move(to: p(26, 60))
        path.addQuadCurve(to: p(34, 60), control: p(30, 50))
        path.addQuadCurve(to: p(42, 60), control: p(38, 70))
        path.addQuadCurve(to: p(50, 60), control: p(46, 50))
        path.addQuadCurve(to: p(58, 60), control: p(54, 70))
        path.addLine(to: p(58, 47))
        path.addLine(to: p(70, 47))
        path.addLine(to: p(70, 73))
        path.addLine(to: p(82, 73))
        path.addLine(to: p(82, 60))
        path.addLine(to: p(93, 60))
        return path
    }
}

/// What the regions read, derived once from the pushed aggregate.
struct CardModel {
    var ordered: [AgentAggregate.Row]
    var hero: AgentAggregate.Row?
    var rest: [AgentAggregate.Row]
    var waiting: Int
    var working: Int
    var allDone: Bool
    var failed: Bool
    var link: URL?

    init(_ state: LiveActivityAttributes.ContentState, stale: Bool) {
        let aggregate = AgentAggregate(state: state)
        var rows = aggregate?.activities ?? []
        if stale {
            rows = rows.map { row in
                guard !["completed", "failed"].contains(row.phase) else { return row }
                var copy = row
                copy.phase = "stale"
                copy.status = "Out of date"
                return copy
            }
        }
        func priority(_ phase: String) -> Int {
            switch phase {
            case "waiting_for_approval", "waiting_for_input": 0
            case "failed": 1
            case "running", "starting": 2
            default: 3
            }
        }
        let ordered = rows.enumerated()
            .sorted { (priority($0.element.phase), $0.offset) < (priority($1.element.phase), $1.offset) }
            .map(\.element)
        let hero = ordered.first { priority($0.phase) <= 1 }
        self.ordered = ordered
        self.hero = hero
        rest = ordered.filter { $0 != hero }
        waiting = rows.filter { priority($0.phase) == 0 }.count
        working = rows.filter { priority($0.phase) == 2 }.count
        allDone = (aggregate?.activeCount ?? 0) == 0
        failed = rows.contains { $0.phase == "failed" }
        link = (hero ?? ordered.first).flatMap { HelmLink.url(forPath: $0.deepLink) }
    }

    var heroPhase: String {
        hero?.phase ?? (allDone ? (failed ? "failed" : "completed") : "running")
    }

    var compactLabel: String {
        if let hero { return CardModel.label(hero.phase) }
        if allDone { return failed ? String(localized: "Failed") : String(localized: "Done") }
        return "\(working)"
    }

    static func label(_ phase: String) -> String {
        switch phase {
        case "waiting_for_approval": String(localized: "Needs approval")
        case "waiting_for_input": String(localized: "Needs input")
        case "failed": String(localized: "Failed")
        case "completed": String(localized: "Done")
        case "starting": String(localized: "Starting")
        case "stale": String(localized: "Out of date")
        default: String(localized: "Working")
        }
    }
}
