import SwiftUI
import WidgetKit

/// Home-screen "Usage": what's left of each subscription's limits, and the past day's cost.
/// Reads the snapshot the app writes to the app group; redraws at each window's reset.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HelmUsage", provider: UsageTimeline()) { entry in
            UsageWidgetFamilyView(entry: entry)
                .containerBackground(for: .widget) { UsageWidgetColors.background }
                .widgetURL(URL(string: "helm://usage"))
        }
        .configurationDisplayName("Usage")
        .description("Subscription limits left and the past day's cost.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: UsageSnapshot.load() ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        guard let snapshot = UsageSnapshot.load() else {
            completion(Timeline(entries: [UsageEntry(date: now, snapshot: nil)], policy: .never))
            return
        }
        let entries = snapshot.timelineDates(from: now).map { UsageEntry(date: $0, snapshot: snapshot.at($0)) }
        completion(Timeline(entries: entries, policy: .never))
    }
}

private struct UsageWidgetFamilyView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        UsageWidgetView(snapshot: entry.snapshot, small: family == .systemSmall)
    }
}
