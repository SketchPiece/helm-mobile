import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HelmWidgetsBundle: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
        UsageWidget()
    }
}

/// Helm's Live Activity, variant A: whoever waits on you leads; other work is a row each.
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            AgentActivityBanner(model: CardModel(context.state, stale: context.isStale))
                .activityBackgroundTint(Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x10 / 255))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let model = CardModel(context.state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Mark(size: 20).padding(.leading, 4).padding(.vertical, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Counts(model: model).padding(.trailing, 6).padding(.vertical, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let hero = model.hero { HeroBlock(row: hero, titleSize: 15) }
                        ForEach(Array(model.rest.prefix(model.hero == nil ? 3 : 2).enumerated()), id: \.offset) { _, row in
                            RowView(row: row)
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .widgetURL(model.link)
                }
            } compactLeading: {
                Mark(size: 20)
            } compactTrailing: {
                HStack(spacing: 5) {
                    Lamp(phase: model.heroPhase)
                    Text(model.compactLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PhaseTint.color(model.heroPhase, dark: true))
                }
            } minimal: {
                Lamp(phase: model.heroPhase, size: 11)
            }
            .widgetURL(model.link)
        }
    }
}

struct AgentActivityBanner: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Mark(size: 18)
                Text("Helm").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 6)
                Counts(model: model)
            }
            if let hero = model.hero { HeroBlock(row: hero, titleSize: 17) }
            ForEach(Array(model.rest.prefix(model.hero == nil ? 4 : 3).enumerated()), id: \.offset) { _, row in
                RowView(row: row)
            }
        }
        .padding(14)
        .widgetURL(model.link)
    }
}

struct Lamp: View {
    let phase: String
    var size: CGFloat = 7
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let tint = phase == "stale" || dimmed ? Color.secondary : PhaseTint.color(phase, dark: true)
        Circle()
            .fill(tint)
            .frame(width: size, height: size)
            .shadow(color: phase == "completed" || phase == "stale" || dimmed ? .clear : tint, radius: 3)
    }
}

struct Mark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(red: 0x26 / 255, green: 0x21 / 255, blue: 0x1D / 255))
            HelmSignal()
                .stroke(Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255),
                        style: StrokeStyle(lineWidth: max(1.5, size * 0.09), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 0.3)
        }
        .frame(width: size, height: size)
    }
}

struct Counts: View {
    let model: CardModel

    var body: some View {
        HStack(spacing: 10) {
            if model.allDone {
                Text(model.failed ? String(localized: "failed") : String(localized: "✓ done"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PhaseTint.color(model.failed ? "failed" : "completed", dark: true))
            } else {
                if model.waiting > 0 {
                    Text("● \(model.waiting)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(PhaseTint.color("waiting_for_approval", dark: true))
                }
                if model.working > 0 {
                    Text("● \(model.working)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(PhaseTint.color("running", dark: true))
                }
            }
        }
    }
}

struct HeroBlock: View {
    let row: AgentAggregate.Row
    let titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Lamp(phase: row.phase)
                Text("\(CardModel.label(row.phase).uppercased()) · \(row.projectTitle.uppercased())")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(PhaseTint.color(row.phase, dark: true))
                    .lineLimit(1)
            }
            Text(row.threadTitle)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            let detail = row.phase == "failed" ? row.status : row.modelTitle
            if !detail.isEmpty {
                Text(detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }
}

struct RowView: View {
    let row: AgentAggregate.Row

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Lamp(phase: row.phase)
            Text(row.threadTitle).font(.system(size: 14)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            if ["running", "starting"].contains(row.phase), let date = ISO8601DateFormatter.helmDate(row.updatedAt) {
                Text(date, style: .timer)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
                    .layoutPriority(1)
            } else {
                Text(CardModel.label(row.phase).lowercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PhaseTint.color(row.phase, dark: true))
            }
        }
    }
}
