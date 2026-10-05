import SwiftUI

// Pieces shared by the thread composer and the new-thread composer: the glass they sit in, and the
// chips in the card's bottom row (model, access mode) and the new thread's "where" row.

extension View {
    /// Liquid glass for the composer, tinted so the timeline behind it blurs out instead of
    /// reading through. Interactive: it swells and lights up under the finger.
    func composerGlass(cornerRadius: CGFloat = 26) -> some View {
        glassEffect(.regular.tint(Palette.surfaceRaised.opacity(0.6)).interactive(),
                    in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The spring the composer opens, closes and rearranges with.
extension Animation {
    static let composer = Animation.spring(response: 0.38, dampingFraction: 0.82)
}

/// A chip in the composer card: icon, title, chevron. `folded` leaves only the icon.
struct ComposerChipLabel<Icon: View>: View {
    let title: String
    var detail: String?
    var folded = false
    var highlighted = false
    var mono = false
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 6) {
            icon()
            if !folded {
                Text(title)
                    .font(mono ? Typography.mono(13) : Typography.footnote.weight(.medium))
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(Typography.footnote).foregroundStyle(Palette.textMuted).lineLimit(1)
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.textMuted)
        }
        .foregroundStyle(highlighted ? Palette.accentText : Palette.text)
        .padding(.horizontal, folded ? 8 : 10)
        .frame(height: 30)
        .background(highlighted ? Palette.accent.opacity(0.16) : Palette.text.opacity(0.07), in: .capsule)
        .contentShape(.capsule)
    }
}

/// The model chip: picks a model right from the chip; "More options" opens the full settings
/// (reasoning options, older models).
struct ModelChip: View {
    let config: ServerConfig?
    let selection: ModelSelection?
    let interactionMode: String
    let onSelection: (ModelSelection) -> Void
    let onMore: () -> Void

    var body: some View {
        Menu {
            if let config {
                ForEach(config.usableProviders) { provider in
                    let models = provider.models.filter { !$0.isLegacy || $0.slug == selection?.model }
                    if !models.isEmpty {
                        Section(provider.displayName) {
                            ForEach(models) { model in
                                Button {
                                    onSelection(ModelSelection(instanceId: provider.instanceId, model: model.slug))
                                } label: {
                                    if selection?.instanceId == provider.instanceId && selection?.model == model.slug {
                                        Label(model.name, systemImage: "checkmark")
                                    } else {
                                        Text(model.name)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button(action: onMore) { Label("More options", systemImage: "slider.horizontal.3") }
            }
        } label: {
            let provider = selection.flatMap { config?.provider($0.instanceId) }
            ComposerChipLabel(title: config?.modelLabel(for: selection) ?? String(localized: "Model"),
                              detail: interactionMode == "plan" ? String(localized: "· Plan") : nil) {
                ProviderIcon(driver: provider?.driver, iconUrl: provider?.iconUrl, size: 14)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityIdentifier("modelChip")
    }
}

/// The access mode chip, with Plan first as a switch in the same menu (when the provider has it).
struct RuntimeModeChip: View {
    let config: ServerConfig?
    let selection: ModelSelection?
    let runtimeMode: String
    let interactionMode: String
    var folded = false
    let onRuntimeMode: (String) -> Void
    let onInteractionMode: (String) -> Void

    private var mode: RuntimeMode { RuntimeMode(rawValue: runtimeMode) ?? .fullAccess }
    private var provider: Provider? { selection.flatMap { config?.provider($0.instanceId) } }

    var body: some View {
        Menu {
            let supported = provider?.supportedRuntimeModes ?? RuntimeMode.allCases.map(\.rawValue)
            // Toggles, so the menu marks the current mode itself and every row keeps the icon the chip
            // shows, plus a line on what the mode does.
            Section {
                ForEach(RuntimeMode.allCases.filter { supported.contains($0.rawValue) }) { option in
                    Toggle(isOn: Binding(get: { option == mode }, set: { if $0 { onRuntimeMode(option.rawValue) } })) {
                        Image(systemName: option.symbol)
                        Text(option.title)
                        Text(option.detail)
                    }
                }
            }
            if provider?.showInteractionModeToggle ?? false {
                Section {
                    Toggle(isOn: Binding(get: { interactionMode == "plan" },
                                         set: { onInteractionMode($0 ? "plan" : "default") })) {
                        Label("Plan first", systemImage: "list.bullet.clipboard")
                    }
                }
            }
        } label: {
            ComposerChipLabel(title: mode.title, folded: folded) {
                Image(systemName: mode.symbol).font(.system(size: 13))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Access: \(mode.title)")
        .accessibilityIdentifier("modeChip")
    }
}

/// Model and mode side by side. The mode folds to its icon when the row also holds send or stop
/// beside the microphone; a long model name then truncates rather than pushing them out.
/// (Decided here rather than measured with ViewThatFits: inside the interactive glass that kept
/// re-measuring and hung the app.)
struct ComposerSettingsChips: View {
    let config: ServerConfig?
    let selection: ModelSelection?
    let runtimeMode: String
    let interactionMode: String
    var foldMode = false
    let onSelection: (ModelSelection) -> Void
    let onRuntimeMode: (String) -> Void
    let onInteractionMode: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ModelChip(config: config, selection: selection, interactionMode: interactionMode,
                      onSelection: onSelection, onMore: onMore)
            RuntimeModeChip(config: config, selection: selection, runtimeMode: runtimeMode,
                            interactionMode: interactionMode, folded: foldMode,
                            onRuntimeMode: onRuntimeMode, onInteractionMode: onInteractionMode)
                .fixedSize()
        }
    }
}
