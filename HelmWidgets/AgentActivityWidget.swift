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

private let cardBackground = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x10 / 255)

/// Helm's Live Activity: whoever waits on you leads; other work is a row each. States are glyphs,
/// timers sit in fixed slots, and the lock screen card stays under iOS's 160 pt.
struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            AgentActivityBanner(model: CardModel(context.state, stale: context.isStale))
                .activityBackgroundTint(cardBackground)
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
                    CardBody(model: model, titleSize: 15, timerSize: 12)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .widgetURL(model.link)
                }
            } compactLeading: {
                Mark(size: 20)
            } compactTrailing: {
                Counts(model: model, compact: true)
            } minimal: {
                PhaseGlyph(phase: model.heroPhase, size: 18)
            }
            .widgetURL(model.link)
        }
    }
}

struct AgentActivityBanner: View {
    let model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Mark(size: 18)
                Text("Helm").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer(minLength: 6)
                Counts(model: model)
            }
            CardBody(model: model, titleSize: 17, timerSize: 13)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .widgetURL(model.link)
    }
}

/// The hero and as many rows as fit; "+N more" for the rest.
struct CardBody: View {
    let model: CardModel
    let titleSize: CGFloat
    let timerSize: CGFloat

    var body: some View {
        let shown = Array(model.rest.prefix(model.hero == nil ? 3 : 2))
        let hidden = model.rest.count - shown.count
        VStack(alignment: .leading, spacing: 8) {
            if let hero = model.hero {
                HeroBlock(row: hero, titleSize: titleSize, timerSize: timerSize, lines: shown.isEmpty ? 2 : 1)
            }
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                        RowView(row: row, showsProject: model.allDone, timerSize: timerSize)
                    }
                }
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, -4)
            }
        }
    }
}

/// A state as a glyph: a hand for approval, a bubble for a question, a check or a cross when
/// finished, play while working: one filled-circle family from start to end.
struct PhaseGlyph: View {
    let phase: String
    var size: CGFloat = 14

    var body: some View {
        let tint = phase == "stale" ? Color.white.opacity(0.45) : PhaseTint.color(phase, dark: true)
        Group {
            switch phase {
            case "waiting_for_approval": symbol("hand.raised.fill")
            case "waiting_for_input": symbol("questionmark.bubble.fill")
            case "completed": symbol("checkmark.circle.fill")
            case "failed": symbol("xmark.circle.fill")
            default: symbol("play.circle.fill")
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: size * 0.92, weight: .semibold))
    }
}

/// Time since a row entered its phase, right-aligned in a slot that fits "1:02:05". A timer
/// interval (not `.timer` style) keeps its shape in Always On: the seconds turn into "––" in place
/// instead of the text becoming "2 min", so nothing around it moves.
struct TimerSlot: View {
    let since: Date
    var size: CGFloat = 13
    var tint: Color = .white.opacity(0.6)

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .font(.system(size: size, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(tint)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .frame(width: size * 4.5, alignment: .trailing)
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

/// Glyph and count for who waits on you and who works; one glyph when all is finished.
struct Counts: View {
    let model: CardModel
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if model.stale {
                Image(systemName: "clock")
                if !compact { Text("Out of date") }
            } else if model.allDone {
                PhaseGlyph(phase: model.failed ? "failed" : "completed", size: compact ? 18 : 20)
            } else {
                if model.waiting > 0 { count(model.waiting, phase: model.waitingPhase) }
                if model.working > 0 { count(model.working, phase: "running") }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
    }

    private func count(_ value: Int, phase: String) -> some View {
        HStack(spacing: 4) {
            PhaseGlyph(phase: phase, size: 14)
            Text(verbatim: "\(value)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(PhaseTint.color(phase, dark: true))
    }
}

struct HeroBlock: View {
    let row: AgentAggregate.Row
    let titleSize: CGFloat
    let timerSize: CGFloat
    let lines: Int

    var body: some View {
        let tint = PhaseTint.color(row.phase, dark: true)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                PhaseGlyph(phase: row.phase, size: 14)
                (Text(CardModel.label(row.phase)).fontWeight(.semibold).foregroundStyle(tint)
                    + Text(verbatim: " · \(row.projectTitle)").foregroundStyle(.white.opacity(0.6)))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if row.phase != "failed", let date = ISO8601DateFormatter.helmDate(row.updatedAt) {
                    TimerSlot(since: date, size: timerSize, tint: tint)
                }
            }
            Text(row.threadTitle)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(lines)
        }
    }
}

struct RowView: View {
    let row: AgentAggregate.Row
    /// A finished card names the project where a running row has its timer.
    let showsProject: Bool
    let timerSize: CGFloat

    var body: some View {
        let finished = row.phase == "completed"
        HStack(alignment: .center, spacing: 9) {
            PhaseGlyph(phase: row.phase, size: 14)
            Text(row.threadTitle)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(finished && !showsProject ? 0.6 : 1))
                .lineLimit(1)
            Spacer(minLength: 8)
            if ["running", "starting"].contains(row.phase), let date = ISO8601DateFormatter.helmDate(row.updatedAt) {
                TimerSlot(since: date, size: timerSize).layoutPriority(1)
            } else if showsProject {
                Text(row.projectTitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }
}
