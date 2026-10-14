import SwiftUI

/// Horizontal project filter: "All" plus projects with open threads, most recent first.
struct ProjectChips: View {
    struct Chip: Identifiable {
        var project: Project
        var environment: EnvironmentSession
        var count: Int
        var id: String { project.id }
    }

    enum Action { case newThread, edit, delete }

    let chips: [Chip]
    @Binding var selection: String?
    /// The long-press menu on a project chip; none without it.
    var onAction: ((Chip, Action) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(selected: selection == nil) {
                    Text("All")
                } action: {
                    selection = nil
                }
                ForEach(chips) { chip in
                    let selected = selection == chip.project.id
                    let button = self.chip(selected: selected) {
                        projectLabel(chip)
                    } action: {
                        selection = selected ? nil : chip.project.id
                    }
                    if let onAction {
                        // A context menu inside the list row would belong to the row, so every chip would get
                        // the first one's; a Menu is the chip's own. Tap filters, long press opens it.
                        Menu {
                            Button("New thread", systemImage: "plus") { onAction(chip, .newThread) }
                            Button("Edit project…", systemImage: "pencil") { onAction(chip, .edit) }
                            Divider()
                            Button("Delete project…", systemImage: "trash", role: .destructive) { onAction(chip, .delete) }
                        } label: {
                            styled(projectLabel(chip), selected: selected)
                        } primaryAction: {
                            UISelectionFeedbackGenerator().selectionChanged()
                            withAnimation(.snappy(duration: 0.2)) { selection = selected ? nil : chip.project.id }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    } else {
                        button
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func projectLabel(_ chip: Chip) -> some View {
        HStack(spacing: 6) {
            ProjectIcon(project: chip.project, environment: chip.environment, size: 20)
            Text(chip.project.title).lineLimit(1)
            Text("\(chip.count)").foregroundStyle(Palette.textMuted).monospacedDigit()
        }
    }

    private func styled(_ label: some View, selected: Bool) -> some View {
        label
            .font(Typography.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .foregroundStyle(selected ? Palette.canvas : Palette.text)
            .background(selected ? Palette.text : Palette.surface, in: .capsule)
    }

    private func chip<Label: View>(selected: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            styled(label(), selected: selected)
        }
        .buttonStyle(.plain)
    }
}

/// The iPad sidebar's project filter: one full-width row that says what is shown and opens a
/// menu of every project. Chips scrolling sideways in a 300pt column hid most of them.
/// Equatable on what it shows, so updates from the Mac don't rebuild the menu under the finger.
struct ProjectSwitcher: View, @MainActor Equatable {
    let chips: [ProjectChips.Chip]
    /// The project shown, or nil for all of them.
    let selected: ProjectChips.Chip?
    let total: Int
    let onSelect: (String?) -> Void
    let onAction: (ProjectChips.Chip, ProjectChips.Action) -> Void
    /// Each project's tile as an image: a menu shows images, not views.
    @State private var icons: [String: UIImage] = [:]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chips.map(\.signature) == rhs.chips.map(\.signature)
            && lhs.selected?.signature == rhs.selected?.signature && lhs.total == rhs.total
    }

    var body: some View {
        Menu {
            Section {
                option(nil, title: String(localized: "All projects"), count: total, icon: nil)
                ForEach(chips) { chip in
                    option(chip.project.id, title: chip.project.title, count: chip.count,
                           icon: icons[chip.project.id] ?? ProjectIcon.menuTile(project: chip.project, environment: chip.environment))
                }
            }
            if let selected {
                Section {
                    Button("New thread in \(selected.project.title)", systemImage: "square.and.pencil") { onAction(selected, .newThread) }
                    Button("Edit project…", systemImage: "pencil") { onAction(selected, .edit) }
                    Button("Delete project…", systemImage: "trash", role: .destructive) { onAction(selected, .delete) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                if let selected {
                    ProjectIcon(project: selected.project, environment: selected.environment, size: 24)
                    Text(selected.project.title).lineLimit(1)
                    Text("\(selected.count)").foregroundStyle(Palette.textMuted).monospacedDigit()
                } else {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 24, height: 24)
                    Text("All projects")
                    Text("\(total)").foregroundStyle(Palette.textMuted).monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
            .font(Typography.subheadline.weight(.medium))
            .foregroundStyle(Palette.text)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 44)
            // A step above the sidebar's own surface.
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("projectSwitcher")
        .task(id: chips.map(\.signature)) {
            // Favicons one by one as the cache hands them over; until then the drawn tile shows.
            for chip in chips {
                if let favicon = await ProjectIcon.menuFavicon(project: chip.project, environment: chip.environment) {
                    icons[chip.project.id] = favicon
                }
            }
        }
    }

    /// A toggle, so the menu marks the shown project itself.
    private func option(_ id: String?, title: String, count: Int, icon: UIImage?) -> some View {
        Toggle(isOn: Binding(get: { selected?.project.id == id }, set: { if $0 { onSelect(id) } })) {
            if let icon {
                Image(uiImage: icon)
            } else {
                Image(systemName: "rectangle.stack")
            }
            Text(title)
            Text("\(count) open")
        }
    }
}

extension ProjectChips.Chip {
    /// What the switcher draws from a chip, for its Equatable check.
    var signature: [String] { [project.id, environment.id, project.title, String(count), project.iconKind ?? "", project.iconEmoji ?? ""] }
}

/// Top right: whether the Macs are connected, as a lamp. Tap for Computers.
struct EnvironmentStatusButton: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.showComputers = true
        } label: {
            // The lamp sits on the screen's corner, with a ring cut out of the
            // symbol around it so it reads as a badge on any background.
            Image(systemName: "desktopcomputer")
                .mask {
                    Rectangle()
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .frame(width: 11, height: 11)
                                .offset(x: 2.5, y: -2.5)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(lampColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 0.5, y: -0.5)
                }
        }
        .accessibilityLabel("Computers")
        .accessibilityIdentifier("computers")
    }

    private var lampColor: Color {
        if model.environments.allSatisfy(\.isLive) { return Palette.done }
        if model.environments.contains(where: \.isLive) { return Palette.accent }
        return Palette.error
    }
}

extension EnvironmentSession {
    var statusText: String {
        switch status {
        case .live: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .offline(let reason): reason
        case .unauthorized: String(localized: "Pair again")
        }
    }
}

/// Shown when nothing is connected, with the reason and a retry.
struct ConnectionBanner: View {
    let environment: EnvironmentSession
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: environment.status == .unauthorized ? "key.slash" : "wifi.exclamationmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.label).font(Typography.bodyMedium).foregroundStyle(Palette.text)
                Text(detail).font(Typography.footnote).foregroundStyle(Palette.textMuted).lineLimit(1)
            }
            Spacer()
            if environment.status == .unauthorized {
                Button("Pair") { router.showPairing = true }
                    .buttonStyle(.glass)
            } else if environment.status == .connecting {
                ProgressView()
            } else {
                Button("Retry") { environment.reconnectNow(reason: "Retry button") }
                    .buttonStyle(.glass)
            }
        }
        .padding(14)
        .background(Palette.warningSurface, in: .rect(cornerRadius: 16))
    }

    /// One short line; the raw reason stays in the Connections sheet.
    private var detail: String {
        switch environment.status {
        case .unauthorized:
            String(localized: "Access expired")
        case .offline:
            if let savedAt = environment.shellSavedAt {
                String(localized: "Offline · threads from \(savedAt.asOfDescription)")
            } else {
                String(localized: "Offline. Is it awake?")
            }
        default:
            environment.statusText
        }
    }
}

extension Date {
    /// "14:32" today, "Oct 3, 14:32" before: how old a saved copy is.
    var asOfDescription: String {
        formatted(date: Calendar.current.isDateInToday(self) ? .omitted : .abbreviated, time: .shortened)
    }
}
