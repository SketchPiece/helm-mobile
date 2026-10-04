import Observation
import SwiftUI
import Synchronization
import UIKit

/// The colours `Palette` hands out. A theme may recolour any of these; whatever it leaves out
/// stays Bakelite. `serverRole` is the matching key in a published theme's `ThemeColors`.
enum PaletteRole: String, CaseIterable, Codable, Sendable {
    case canvas, surface, surfaceRaised, message, text, textMuted, placeholder, border, input
    case accent, accentForeground, accentText, error, errorText, errorSurface, warningSurface, code, codeText

    var serverRole: String {
        switch self {
        case .message: "messageSurface"
        case .accentText: "focus"
        case .errorText: "errorForeground"
        case .code: "codeBackground"
        case .codeText: "codeForeground"
        default: rawValue
        }
    }
}

/// An sRGB colour with alpha, as themes store it.
struct RGBA: Codable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    /// The CSS colours theme files use: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()/rgba()` and `oklch()`.
    init?(css: String) {
        let value = css.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
            if digits.count == 8 {
                self.init(r: Double((number >> 24) & 0xFF) / 255, g: Double((number >> 16) & 0xFF) / 255,
                          b: Double((number >> 8) & 0xFF) / 255, a: Double(number & 0xFF) / 255)
            } else {
                self.init(hex: UInt32(number))
            }
            return
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        let body = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = body.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "/", with: " / ")
            .split(separator: " ").map(String.init)
        let alphaIndex = parts.firstIndex(of: "/")
        let channels = alphaIndex.map { Array(parts[..<$0]) } ?? Array(parts.prefix(3))
        var alpha = 1.0
        if let alphaIndex, alphaIndex + 1 < parts.count { alpha = Self.number(parts[alphaIndex + 1], percentOf: 1) ?? 1 }
        else if alphaIndex == nil, parts.count == 4 { alpha = Self.number(parts[3], percentOf: 1) ?? 1 }
        guard channels.count == 3 else { return nil }
        switch name {
        case "rgb", "rgba":
            guard let r = Self.number(channels[0], percentOf: 255), let g = Self.number(channels[1], percentOf: 255),
                  let b = Self.number(channels[2], percentOf: 255) else { return nil }
            self.init(r: r / 255, g: g / 255, b: b / 255, a: alpha)
        case "oklch":
            guard let l = Self.number(channels[0], percentOf: 1), let c = Self.number(channels[1], percentOf: 0.4),
                  let h = Double(channels[2].replacingOccurrences(of: "deg", with: "")) else { return nil }
            self = Self.oklch(l: l, c: c, h: h, alpha: alpha)
        default:
            return nil
        }
    }

    private static func number(_ text: String, percentOf full: Double) -> Double? {
        if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 * full } }
        return Double(text)
    }

    /// OKLCH → sRGB (Björn Ottosson's matrices), gamut-clipped.
    static func oklch(l: Double, c: Double, h: Double, alpha: Double = 1) -> RGBA {
        let radians = h * .pi / 180
        let a = c * cos(radians), b = c * sin(radians)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (lc, mc, sc) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        let linear = (
            4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
            -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
            -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        )
        func gamma(_ x: Double) -> Double {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(1, max(0, v))
        }
        return RGBA(r: gamma(linear.0), g: gamma(linear.1), b: gamma(linear.2), a: alpha)
    }
}

/// A palette the app can wear: Bakelite (built in) or one a Mac publishes. Each appearance is
/// optional; an appearance the theme doesn't describe stays Bakelite.
struct HelmTheme: Identifiable, Codable, Hashable, Sendable {
    static let bakeliteId = "bakelite"

    var id: String
    var name: String
    /// The Mac that publishes it; nil for the built-in theme.
    var source: String?
    var light: [PaletteRole: RGBA]?
    var dark: [PaletteRole: RGBA]?

    static let bakelite = HelmTheme(id: bakeliteId, name: "Bakelite", source: nil, light: bakeliteLight, dark: bakeliteDark)

    func color(_ role: PaletteRole, dark isDark: Bool) -> RGBA {
        (isDark ? dark : light)?[role] ?? (isDark ? Self.bakeliteDark : Self.bakeliteLight)[role] ?? RGBA(hex: 0xFF00FF)
    }

    // Helm's "Bakelite and lamp" (packages/shared/src/helmPalette.ts in t3code).
    static let bakeliteLight: [PaletteRole: RGBA] = [
        .canvas: RGBA(hex: 0xE7E0D2), .surface: RGBA(hex: 0xFBF6EC), .surfaceRaised: RGBA(hex: 0xFBF6EC),
        .message: RGBA(hex: 0xDDD5C6), .text: RGBA(hex: 0x26211D), .textMuted: RGBA(hex: 0x5E554B),
        .placeholder: RGBA(hex: 0x6E655A), .border: RGBA(hex: 0xCFC6B6), .input: RGBA(hex: 0xBFB6A6),
        .accent: RGBA(hex: 0xE8A33D), .accentForeground: RGBA(hex: 0x26211D), .accentText: RGBA(hex: 0x9C7A45),
        .error: RGBA(hex: 0xB8321F), .errorText: RGBA(hex: 0x8E2415), .errorSurface: RGBA(hex: 0xF0D6CC),
        .warningSurface: RGBA(hex: 0xEFE3C8), .code: RGBA(hex: 0x1F1B18), .codeText: RGBA(hex: 0xEFE7D6),
    ]
    static let bakeliteDark: [PaletteRole: RGBA] = [
        .canvas: RGBA(hex: 0x161310), .surface: RGBA(hex: 0x1F1B18), .surfaceRaised: RGBA(hex: 0x26211D),
        .message: RGBA(hex: 0x221E1A), .text: RGBA(hex: 0xEFE7D6), .textMuted: RGBA(hex: 0xA3968A),
        .placeholder: RGBA(hex: 0x8F8376), .border: RGBA(hex: 0x2A2420), .input: RGBA(hex: 0x302924),
        .accent: RGBA(hex: 0xE8A33D), .accentForeground: RGBA(hex: 0x161310), .accentText: RGBA(hex: 0xF2B550),
        .error: RGBA(hex: 0xB8321F), .errorText: RGBA(hex: 0xEA7862), .errorSurface: RGBA(hex: 0x3A1F19),
        .warningSurface: RGBA(hex: 0x3A2C18), .code: RGBA(hex: 0x100E0C), .codeText: RGBA(hex: 0xEFE7D6),
    ]

    /// Ids web and the RN app reserve for their built-ins; a published file can't claim them.
    static let reservedIds: Set<String> = [
        "system", "light", "dark", "t3-code", "t3-chat-dark", "t3-grove", "t3-ocean", "t3-ember", "material-you",
    ]

    /// The themes a Mac publishes (`environmentThemesUpdated`), like RN's `resolvePublishedMobileThemes`:
    /// only explicit palettes (the seeded short form needs web's generator), reserved ids skipped.
    static func published(_ json: JSON, source: String) -> [HelmTheme] {
        (json.array ?? []).compactMap { theme in
            guard let id = theme["id"]?.string, !reservedIds.contains(id), let name = theme["name"]?.string else { return nil }
            let appearance = theme["appearance"]?.string == "light" ? "light" : "dark"
            let other = appearance == "dark" ? "light" : "dark"
            let own = palette(theme["colors"])
            let variant = palette(theme["variants"]?[other])
            guard own != nil || variant != nil else { return nil }
            return HelmTheme(id: "published:\(id)", name: name, source: source,
                             light: appearance == "light" ? own : variant, dark: appearance == "dark" ? own : variant)
        }
    }

    private static func palette(_ colors: JSON?) -> [PaletteRole: RGBA]? {
        guard let colors = colors?.object else { return nil }
        var palette: [PaletteRole: RGBA] = [:]
        for role in PaletteRole.allCases {
            if let value = colors[role.serverRole]?.string, let color = RGBA(css: value) { palette[role] = color }
        }
        return palette.isEmpty ? nil : palette
    }
}

/// The theme the app wears. `Palette` reads its colours from here, and because reads are
/// observation-tracked, every view that drew with `Palette` redraws when the theme changes.
/// Thread-safe: colours can be read from any thread; the choice persists in UserDefaults.
final class ThemeStore: Observable, Sendable {
    static let shared = ThemeStore()

    /// Resolved SwiftUI colours, each dynamic over light and dark.
    struct Colors: Sendable {
        fileprivate var values: [PaletteRole: Color]
        subscript(role: PaletteRole) -> Color { values[role] ?? .pink }
    }

    private struct State {
        var theme: HelmTheme
        var colors: Colors
    }

    private static let defaultsKey = "theme"
    private let registrar = ObservationRegistrar()
    private let state: Mutex<State>
    // UserDefaults is thread-safe; it just isn't marked Sendable.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(HelmTheme.self, from: $0) }
        let theme = saved ?? .bakelite
        state = Mutex(State(theme: theme, colors: Self.resolve(theme)))
    }

    var colors: Colors {
        registrar.access(self, keyPath: \.colors)
        return state.withLock { $0.colors }
    }

    var theme: HelmTheme {
        registrar.access(self, keyPath: \.colors)
        return state.withLock { $0.theme }
    }

    /// Wears `theme` and remembers it (published themes are cached, so they survive the Mac going offline).
    func apply(_ theme: HelmTheme) {
        let colors = Self.resolve(theme)
        registrar.withMutation(of: self, keyPath: \.colors) {
            state.withLock { $0 = State(theme: theme, colors: colors) }
        }
        if let data = try? JSONEncoder().encode(theme) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// A Mac republished its themes: follow edits to the one in use.
    func update(from published: [HelmTheme]) {
        let current = state.withLock { $0.theme }
        if let fresh = published.first(where: { $0.id == current.id }), fresh != current { apply(fresh) }
    }

    private static func resolve(_ theme: HelmTheme) -> Colors {
        var values: [PaletteRole: Color] = [:]
        for role in PaletteRole.allCases {
            let light = theme.color(role, dark: false).uiColor
            let dark = theme.color(role, dark: true).uiColor
            values[role] = Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
        return Colors(values: values)
    }
}
