import SwiftUI

/// Settings → Appearance: light, dark or the phone's setting, and the theme: Helm's Bakelite or
/// one a connected Mac publishes. A published theme that describes only one appearance leaves
/// the other one Bakelite.
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = Appearance.system

    private var store: ThemeStore { .shared }

    /// Bakelite, then each Mac's themes (first Mac wins on a shared id), then the saved choice
    /// if its Mac is offline right now.
    private var themes: [HelmTheme] {
        var seen: Set<String> = [HelmTheme.bakeliteId]
        var list = [HelmTheme.bakelite]
        for environment in model.environments {
            for theme in environment.themes where seen.insert(theme.id).inserted { list.append(theme) }
        }
        let current = store.theme
        if seen.insert(current.id).inserted { list.append(current) }
        return list
    }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearanceMode")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Section {
                ForEach(themes) { theme in
                    ThemeRow(theme: theme, selected: theme.id == store.theme.id, offline: isOffline(theme)) {
                        store.apply(theme)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            } header: {
                Text("Theme").sectionLabelStyle()
            } footer: {
                Text("Computers publish themes from Helm's themes folder. A theme made for dark mode leaves light mode as it was.")
                    .font(Typography.footnote)
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func isOffline(_ theme: HelmTheme) -> Bool {
        theme.source != nil && !model.environments.contains { $0.themes.contains { $0.id == theme.id } }
    }
}

private struct ThemeRow: View {
    let theme: HelmTheme
    let selected: Bool
    let offline: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Swatch(theme: theme, dark: colorScheme == .dark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name).foregroundStyle(Palette.text).lineLimit(1)
                    Text(subtitle).font(Typography.footnote).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accentText) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("theme-\(theme.id)")
    }

    private var subtitle: String {
        let modes = [theme.light != nil ? String(localized: "Light") : nil, theme.dark != nil ? String(localized: "Dark") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        guard let source = theme.source else { return String(localized: "Helm's default · Light · Dark") }
        return offline ? String(localized: "From \(source) · saved") : String(localized: "From \(source) · \(modes)")
    }
}

/// The theme's canvas with its surface, text and accent, as drawn in the current appearance.
private struct Swatch: View {
    let theme: HelmTheme
    let dark: Bool

    var body: some View {
        let color = { (role: PaletteRole) in Color(uiColor: theme.color(role, dark: dark).uiColor) }
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color(.canvas))
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(color(.text)).frame(width: 18, height: 3)
                Capsule().fill(color(.textMuted)).frame(width: 12, height: 3)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Circle().fill(color(.accent)).frame(width: 10, height: 10).padding(5)
        }
        .frame(width: 44, height: 32)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
