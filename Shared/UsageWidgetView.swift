import SwiftUI

/// Bakelite in dark, ivory in light, like the app's default theme.
enum UsageWidgetColors {
    static let background = dynamic(light: 0xFBF6EC, dark: 0x1F1B18)
    static let text = dynamic(light: 0x26211D, dark: 0xEFE7D6)
    static let muted = dynamic(light: 0x5E554B, dark: 0xA3968A)
    static let track = dynamic(light: 0xCFC6B6, dark: 0x302924)
    static let fill = dynamic(light: 0x2E8C80, dark: 0x6CC4B8)
    static let low = dynamic(light: 0xB8321F, dark: 0xEA7862)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// The widget's face; shared with the app so tests can render it.
struct UsageWidgetView: View {
    let snapshot: UsageSnapshot?
    /// systemSmall: one tight window per provider; systemMedium: up to three each.
    let small: Bool

    var body: some View {
        if let snapshot, !snapshot.providers.isEmpty || snapshot.costUsd != nil {
            VStack(alignment: .leading, spacing: small ? 8 : 10) {
                header(snapshot)
                if small {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(snapshot.providers.prefix(2), id: \.driver) { provider in
                            if let tightest = provider.windows.first {
                                WindowBar(title: provider.name, window: tightest, compact: true)
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(snapshot.providers.prefix(2), id: \.driver) { provider in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(provider.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(UsageWidgetColors.text)
                                ForEach(Array(provider.windows.prefix(3).enumerated()), id: \.offset) { _, window in
                                    WindowBar(title: window.label, window: window, compact: false)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                footer(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Usage", systemImage: "chart.bar.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UsageWidgetColors.text)
                Spacer()
                Text("Open Helm to load usage.")
                    .font(.system(size: 13))
                    .foregroundStyle(UsageWidgetColors.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill").font(.system(size: 11, weight: .semibold))
            Text("Usage").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if !small, let mac = snapshot.macLabel {
                Text(mac).font(.system(size: 11)).foregroundStyle(UsageWidgetColors.muted).lineLimit(1)
            }
        }
        .foregroundStyle(UsageWidgetColors.text)
    }

    private func footer(_ snapshot: UsageSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let cost = snapshot.costUsd {
                Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                    .font(.system(size: small ? 15 : 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(UsageWidgetColors.text)
                Text("in 24h").font(.system(size: 11)).foregroundStyle(UsageWidgetColors.muted)
            }
            Spacer(minLength: 0)
            if !small {
                Text(snapshot.updatedAt, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(UsageWidgetColors.muted)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct WindowBar: View {
    let title: String
    let window: UsageSnapshot.Window
    let compact: Bool

    var body: some View {
        let low = window.remainingPercent < 15
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(.system(size: compact ? 12 : 11, weight: compact ? .semibold : .regular))
                    .foregroundStyle(compact ? UsageWidgetColors.text : UsageWidgetColors.muted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(Int(window.remainingPercent))%")
                    .font(.system(size: compact ? 12 : 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(low ? UsageWidgetColors.low : UsageWidgetColors.text)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(UsageWidgetColors.track)
                    Capsule().fill(low ? UsageWidgetColors.low : UsageWidgetColors.fill)
                        .frame(width: max(3, proxy.size.width * window.remainingPercent / 100))
                }
            }
            .frame(height: 4)
            if compact {
                Text(window.label).font(.system(size: 10)).foregroundStyle(UsageWidgetColors.muted).lineLimit(1)
            }
        }
    }
}

extension UsageSnapshot {
    /// Gallery and placeholder data.
    static let preview = UsageSnapshot(
        updatedAt: Date(), macLabel: "MacBook", costUsd: 12.4, tokens: 18_400_000,
        providers: [
            .init(driver: "codex", name: "Codex", windows: [
                .init(label: "5-hour", kind: "session", remainingPercent: 62, resetsAt: Date().addingTimeInterval(7200)),
                .init(label: "Weekly", kind: "weekly", remainingPercent: 81, resetsAt: nil),
            ]),
            .init(driver: "claudeAgent", name: "Claude", windows: [
                .init(label: "Session", kind: "session", remainingPercent: 11, resetsAt: Date().addingTimeInterval(3600)),
                .init(label: "Weekly", kind: "weekly", remainingPercent: 74, resetsAt: nil),
            ]),
        ]
    )
}
