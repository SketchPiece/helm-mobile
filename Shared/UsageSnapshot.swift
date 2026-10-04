import Foundation

/// What the "Usage" home-screen widget shows, written by the app into the shared app group
/// whenever it refreshes usage (foreground, the Usage screen) and read by the widget.
/// Display data only: no tokens or addresses leave the app.
struct UsageSnapshot: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        var label: String
        /// session | weekly | monthly | other
        var kind: String
        var remainingPercent: Double
        var resetsAt: Date?
    }

    struct Provider: Codable, Equatable, Sendable {
        /// codex | claudeAgent | …
        var driver: String
        var name: String
        /// Tightest first.
        var windows: [Window]
    }

    var updatedAt: Date
    var macLabel: String?
    /// The past 24 hours at full API rates, summed over the live Macs.
    var costUsd: Double?
    var tokens: Double?
    var providers: [Provider]

    static let appGroup = "group.com.sketchpiece.helm"
    private static let key = "usageSnapshot"

    static func load(from defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> UsageSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    /// The snapshot as of `date`: windows whose reset has passed read as full again.
    func at(_ date: Date) -> UsageSnapshot {
        var copy = self
        copy.providers = providers.map { provider in
            var provider = provider
            provider.windows = provider.windows.map { window in
                guard let reset = window.resetsAt, reset <= date else { return window }
                return Window(label: window.label, kind: window.kind, remainingPercent: 100, resetsAt: nil)
            }
            return provider
        }
        return copy
    }

    /// Times the widget should redraw: now, then every reset in the next day.
    func timelineDates(from now: Date) -> [Date] {
        let resets = providers.flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now && $0 < now.addingTimeInterval(86_400) }
        return [now] + Array(Set(resets)).sorted()
    }
}
