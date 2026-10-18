import SwiftUI

/// The phone's "Bakelite and lamp" palette, dark side only: the watch is always dark.
enum WatchPalette {
    static let accent = Color(hex: 0xE8A33D)
    static let accentText = Color(hex: 0xF2B550)
    static let accentForeground = Color(hex: 0x161310)
    static let surface = Color(hex: 0x26211D)
    static let textMuted = Color(hex: 0xA79E92)
    static let working = Color(hex: 0x6CC4B8)
    static let question = Color(hex: 0xA99BE0)
    static let error = Color(hex: 0xEA7862)
    static let errorFill = Color(hex: 0xB8321F)

    static func project(_ name: String?) -> Color {
        switch name {
        case "red": Color(hex: 0xD9604C)
        case "orange": Color(hex: 0xE08A3C)
        case "yellow", "amber": accent
        case "green": Color(hex: 0x6FA86A)
        case "teal", "cyan": working
        case "blue": Color(hex: 0x5C8FD6)
        case "purple", "violet", "indigo": question
        case "pink": Color(hex: 0xD678A6)
        default: Color(hex: 0x5A5047)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension WatchPhase {
    var label: String {
        switch self {
        case .approval: String(localized: "Needs approval")
        case .input: String(localized: "Has a question")
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Waiting on subagents")
        case .failed: String(localized: "Failed")
        case .limited: String(localized: "Usage limit")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Idle")
        }
    }

    var color: Color {
        switch self {
        case .approval: WatchPalette.accent
        case .input: WatchPalette.question
        case .working, .waiting: WatchPalette.working
        case .failed, .limited: WatchPalette.error
        case .done: WatchPalette.accentText
        case .idle: WatchPalette.textMuted
        }
    }

    var symbol: String {
        switch self {
        case .approval: "hand.raised.fill"
        case .input: "questionmark.bubble.fill"
        case .working: "circle.dotted"
        case .waiting: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .limited: "gauge.with.dots.needle.100percent"
        case .done: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }

    var needsYou: Bool { self == .approval || self == .input }
}

/// The project's tile, as on the phone: its emoji, or two letters on a colour.
struct ProjectBadge: View {
    let icon: WatchIcon
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(icon.emoji == nil ? WatchPalette.project(icon.color) : WatchPalette.surface)
            if let emoji = icon.emoji {
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                Text(icon.letters)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A phase as a small coloured label; "Working" pulses.
struct PhaseLabel: View {
    let phase: WatchPhase

    var body: some View {
        Label {
            Text(phase.label)
        } icon: {
            Image(systemName: phase.symbol)
                .symbolEffect(.pulse, isActive: phase == .working)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(phase.color)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}
