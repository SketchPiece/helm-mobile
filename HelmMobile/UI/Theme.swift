import SwiftUI
import UIKit

// Helm's "Bakelite and lamp" palette (packages/shared/src/helmPalette.ts in t3code; the values live
// in HelmTheme.bakelite). Dark is flat bakelite, light is the ivory casing. Amber is the action
// colour, signal red is kept for errors and stop so it never competes with an action.
enum Palette {
    // Themeable roles come from ThemeStore (Bakelite unless Settings → Appearance picks another);
    // reading one inside a view body makes the view follow theme changes.
    static var canvas: Color { ThemeStore.shared.colors[.canvas] }
    static var surface: Color { ThemeStore.shared.colors[.surface] }
    static var surfaceRaised: Color { ThemeStore.shared.colors[.surfaceRaised] }
    static var message: Color { ThemeStore.shared.colors[.message] }
    static var text: Color { ThemeStore.shared.colors[.text] }
    static var textMuted: Color { ThemeStore.shared.colors[.textMuted] }
    static var placeholder: Color { ThemeStore.shared.colors[.placeholder] }
    static var border: Color { ThemeStore.shared.colors[.border] }
    static var input: Color { ThemeStore.shared.colors[.input] }
    static var accent: Color { ThemeStore.shared.colors[.accent] }
    static var accentForeground: Color { ThemeStore.shared.colors[.accentForeground] }
    static var accentText: Color { ThemeStore.shared.colors[.accentText] }
    static var error: Color { ThemeStore.shared.colors[.error] }
    static var errorText: Color { ThemeStore.shared.colors[.errorText] }
    static var errorSurface: Color { ThemeStore.shared.colors[.errorSurface] }
    static var warningSurface: Color { ThemeStore.shared.colors[.warningSurface] }
    static var code: Color { ThemeStore.shared.colors[.code] }
    static var codeText: Color { ThemeStore.shared.colors[.codeText] }
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
    /// An opaque raised panel that floats over the timeline (composer, queue). Glass is too
    /// see-through over text, so these stay solid with a hairline and a soft shadow.
    func floatingSurface(cornerRadius: CGFloat) -> some View {
        background(Palette.surfaceRaised, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
    }

    /// Mono caps section label, as on the desktop sidebar ("SETTLED · 12").
    func sectionLabelStyle() -> some View {
        font(Typography.sectionHeader)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Palette.textMuted)
    }
}
