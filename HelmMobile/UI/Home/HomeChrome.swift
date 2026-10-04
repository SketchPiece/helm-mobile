import SwiftUI

/// Horizontal project filter: "All" plus projects with open threads, most recent first.
struct ProjectChips: View {
    struct Chip: Identifiable {
        var project: Project
        var environment: EnvironmentSession
        var count: Int
        var id: String { project.id }
    }

    let chips: [Chip]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(selected: selection == nil) {
                    Text("All")
                } action: {
                    selection = nil
                }
                ForEach(chips) { chip in
                    self.chip(selected: selection == chip.project.id) {
                        HStack(spacing: 6) {
                            ProjectIcon(project: chip.project, environment: chip.environment, size: 20)
                            Text(chip.project.title).lineLimit(1)
                            Text("\(chip.count)").foregroundStyle(Palette.textMuted).monospacedDigit()
                        }
                    } action: {
                        selection = selection == chip.project.id ? nil : chip.project.id
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chip<Label: View>(selected: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            label()
                .font(Typography.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .foregroundStyle(selected ? Palette.canvas : Palette.text)
                .background(selected ? Palette.text : Palette.surface, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Bottom-left: which Macs are connected. Tap for the list and quick reconnect.
struct EnvironmentStatusButton: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Menu {
            ForEach(model.environments) { environment in
                Button {
                    environment.reconnectNow()
                } label: {
                    Label {
                        Text(environment.label)
                        Text(environment.statusText)
                    } icon: {
                        Image(systemName: environment.isLive ? "checkmark.circle.fill" : "exclamationmark.circle")
                    }
                }
            }
            Divider()
            Button {
                router.showPairing = true
            } label: {
                Label("Connect another Mac", systemImage: "plus")
            }
            Button {
                router.showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "desktopcomputer")
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(lampColor)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -3)
                }
        }
        .accessibilityLabel("Connections")
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
                Text(detail).font(Typography.footnote).foregroundStyle(Palette.textMuted).lineLimit(2)
                if let savedAt = environment.shellSavedAt {
                    Text("Threads as of \(savedAt.asOfDescription)")
                        .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                }
            }
            Spacer()
            if environment.status == .unauthorized {
                Button("Pair") { router.showPairing = true }
                    .buttonStyle(.glass)
            } else if environment.status == .connecting {
                ProgressView()
            } else {
                Button("Retry") { environment.reconnectNow() }
                    .buttonStyle(.glass)
            }
        }
        .padding(14)
        .background(Palette.warningSurface, in: .rect(cornerRadius: 16))
    }

    private var detail: String {
        switch environment.status {
        case .unauthorized:
            String(localized: "This phone's access expired or was removed. Pair it again.")
        case .offline(let reason):
            String(localized: "Can't reach the Mac. Is it awake and is Tailscale on? (\(reason))")
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
