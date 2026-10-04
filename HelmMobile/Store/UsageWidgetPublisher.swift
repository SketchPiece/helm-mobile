import Foundation
import WidgetKit

/// Keeps the "Usage" widget's snapshot current: subscription limits from the live Macs'
/// provider lists, plus the past 24 hours' cost (a transcript scan, so at most every 15 min).
@MainActor
final class UsageWidgetPublisher {
    static let shared = UsageWidgetPublisher()

    private var lastScan: Date?
    private var dayTotals: (cost: Double, tokens: Double)?
    private var publishing = false

    /// Called on foreground, when a Mac connects, and after refreshing the Usage screen.
    func publish(from environments: [EnvironmentSession], force: Bool = false) async {
        guard !AppModel.isUnitTestHost, !publishing else { return }
        let live = environments.filter(\.isLive)
        guard !live.isEmpty else { return }
        publishing = true
        defer { publishing = false }
        if force || lastScan.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
            var cost = 0.0
            var tokens = 0.0
            var answered = false
            for environment in live {
                guard let summary = try? await environment.usageSummary(Usage.window(days: 1)), summary.isCompatible else { continue }
                let totals = Usage.Totals(summary)
                cost += totals.costUsd
                tokens += totals.tokens
                answered = true
            }
            if answered {
                dayTotals = (cost, tokens)
                lastScan = Date()
            }
        }
        let snapshot = Self.snapshot(
            macs: live.map { ($0.label, $0.config?.providers ?? []) },
            dayTotals: dayTotals, now: Date()
        )
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The widget's data: per provider (Codex and Claude first) the windows of the first Mac
    /// that reports them, tightest first, at most four.
    nonisolated static func snapshot(macs: [(label: String, providers: [Provider])], dayTotals: (cost: Double, tokens: Double)?, now: Date) -> UsageSnapshot {
        var seen = Set<String>()
        var providers: [UsageSnapshot.Provider] = []
        for mac in macs {
            for provider in mac.providers where provider.enabled && provider.installed && !seen.contains(provider.driver) {
                guard let limits = provider.usageLimits, !limits.windows.isEmpty else { continue }
                seen.insert(provider.driver)
                providers.append(UsageSnapshot.Provider(
                    driver: provider.driver, name: provider.displayName,
                    windows: limits.windows
                        .sorted { $0.remainingPercent < $1.remainingPercent }
                        .prefix(4)
                        .map { .init(label: $0.label, kind: $0.kind, remainingPercent: $0.remainingPercent.rounded(), resetsAt: $0.resetsAt) }
                ))
            }
        }
        let order = ["codex": 0, "claudeAgent": 1]
        providers.sort { (order[$0.driver] ?? 2, $0.name) < (order[$1.driver] ?? 2, $1.name) }
        return UsageSnapshot(updatedAt: now, macLabel: macs.count == 1 ? macs.first?.label : nil,
                             costUsd: dayTotals?.cost, tokens: dayTotals?.tokens, providers: providers)
    }
}

