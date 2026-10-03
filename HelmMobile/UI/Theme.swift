import SwiftUI
import UIKit

// Helm's "Bakelite and lamp" palette (mirrors packages/shared/src/helmPalette.ts in t3code).
// Dark is flat bakelite, light is the ivory casing. Amber is the action colour, signal red is
// kept for errors and stop so it never competes with an action.
enum Palette {
    static let canvas = dynamic(light: 0xE7E0D2, dark: 0x161310)
    static let surface = dynamic(light: 0xFBF6EC, dark: 0x1F1B18)
    static let surfaceRaised = dynamic(light: 0xFBF6EC, dark: 0x26211D)
    static let message = dynamic(light: 0xDDD5C6, dark: 0x221E1A)
    static let text = dynamic(light: 0x26211D, dark: 0xEFE7D6)
    static let textMuted = dynamic(light: 0x5E554B, dark: 0xA3968A)
    static let placeholder = dynamic(light: 0x6E655A, dark: 0x8F8376)
    static let border = dynamic(light: 0xCFC6B6, dark: 0x2A2420)
    static let input = dynamic(light: 0xBFB6A6, dark: 0x302924)
    static let accent = Color(hex: 0xE8A33D)
    static let accentForeground = dynamic(light: 0x26211D, dark: 0x161310)
    static let accentText = dynamic(light: 0x9C7A45, dark: 0xF2B550)
    static let error = Color(hex: 0xB8321F)
    static let errorText = dynamic(light: 0x8E2415, dark: 0xEA7862)
    static let errorSurface = dynamic(light: 0xF0D6CC, dark: 0x3A1F19)
    static let warningSurface = dynamic(light: 0xEFE3C8, dark: 0x3A2C18)
    static let code = dynamic(light: 0x1F1B18, dark: 0x100E0C)
    static let codeText = Color(hex: 0xEFE7D6)
    static let working = dynamic(light: 0x2E8C80, dark: 0x6CC4B8)
    static let question = dynamic(light: 0x6E5BB0, dark: 0xA99BE0)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// IBM Plex everywhere, scaled with Dynamic Type so the phone's text size setting is the
// accessibility control (no in-app slider). Unbounded is only for the Helm wordmark.
enum Typography {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name = switch weight {
        case .semibold, .bold, .heavy, .black: "IBMPlexSans-SemiBold"
        case .medium: "IBMPlexSans-Medium"
        default: "IBMPlexSans-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle = .footnote) -> Font {
        .custom("IBMPlexMono-Regular", size: size, relativeTo: style)
    }

    static let wordmark = Font.custom("Unbounded-SemiBold", size: 22, relativeTo: .title2)
    static let body = sans(17)
    static let bodyMedium = sans(17, .medium)
    static let headline = sans(17, .semibold, relativeTo: .headline)
    static let subheadline = sans(15, relativeTo: .subheadline)
    static let footnote = sans(13, relativeTo: .footnote)
    static let caption = sans(12, relativeTo: .caption)
    static let sectionHeader = mono(12, relativeTo: .caption)
    static let code = mono(13)
}

extension View {
    /// Mono caps section label, as on the desktop sidebar ("SETTLED · 12").
    func sectionLabelStyle() -> some View {
        font(Typography.sectionHeader)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Palette.textMuted)
    }
}
