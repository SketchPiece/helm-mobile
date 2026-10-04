import SwiftUI

/// Settings, split the way the app is: this phone, the connected Macs, and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage(PhonePreferences.followUpKey) private var followUp = FollowUpBehavior.queue
    @AppStorage(PhonePreferences.returnKeyKey) private var returnKey = ReturnKeyBehavior.newline
    @AppStorage(PhonePreferences.codeFontSizeKey) private var codeFontSize = 0
    @AppStorage(PhonePreferences.codeWordWrapKey) private var codeWordWrap = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.settingsPath) {
            Form {
                Section {
                    ForEach(model.environments) { environment in
                        NavigationLink {
                            EnvironmentDetailView(environment: environment)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer")
                                    .foregroundStyle(Palette.textMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(environment.label).font(Typography.body)
                                    Text(environment.statusText)
                                        .font(Typography.footnote)
                                        .foregroundStyle(environment.isLive ? Palette.done : Palette.textMuted)
                                }
                            }
                        }
                    }
                    Button {
                        router.showPairing = true
                    } label: {
                        Label("Connect a Mac", systemImage: "plus")
                    }
                    NavigationLink {
                        TailscaleSettingsView()
                    } label: {
                        HStack {
                            Label("Tailscale", systemImage: "network")
                            Spacer()
                            Text(model.tailscale.isRunning ? String(localized: "Built-in") : String(localized: "VPN app"))
                                .font(Typography.footnote)
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    .accessibilityIdentifier("tailscaleSettings")
                } header: {
                    Text("Macs").sectionLabelStyle()
                }

                Section {
                    NavigationLink {
                        ArchivedThreadsView()
                    } label: {
                        Label("Archived threads", systemImage: "archivebox")
                    }
                } header: {
                    Text("Threads").sectionLabelStyle()
                }

                Section {
                    NavigationLink {
                        ScheduledTasksView()
                    } label: {
                        Label("Scheduled tasks", systemImage: "calendar.badge.clock")
                    }
                    .accessibilityIdentifier("scheduledTasks")
                    NavigationLink {
                        UsageView()
                    } label: {
                        Label("Usage", systemImage: "chart.bar")
                    }
                    .accessibilityIdentifier("usage")
                } header: {
                    Text("Agents").sectionLabelStyle()
                }

                NotificationsSection()

                Section {
                    valueLink(String(localized: "Appearance"), value: "\(appearance.title) · \(ThemeStore.shared.theme.name)",
                              symbol: "paintpalette") {
                        AppearanceSettingsView()
                    }
                    .accessibilityIdentifier("appearanceSettings")
                    valueLink(String(localized: "Follow-ups"), value: followUp.title, symbol: "text.line.first.and.arrowtriangle.forward") {
                        FollowUpSettingsView()
                    }
                    .accessibilityIdentifier("followUpSettings")
                    valueLink(String(localized: "Keyboard"), value: returnKey == .send ? String(localized: "Return sends") : String(localized: "Return adds a line"),
                              symbol: "keyboard") {
                        KeyboardSettingsView()
                    }
                    .accessibilityIdentifier("keyboardSettings")
                    valueLink(String(localized: "Code and diffs"), value: CodeAppearance(fontSize: codeFontSize, wordWrap: codeWordWrap).summary,
                              symbol: "chevron.left.forwardslash.chevron.right") {
                        CodeSettingsView()
                    }
                    .accessibilityIdentifier("codeSettings")
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        HStack {
                            Text("Language and text size").foregroundStyle(Palette.text)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(Palette.textMuted)
                        }
                    }
                } header: {
                    Text("This phone").sectionLabelStyle()
                } footer: {
                    Text("Helm follows the phone's language and Dynamic Type text size.")
                        .font(Typography.footnote)
                }

                Section {
                    HStack(spacing: 12) {
                        HelmMark(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Helm").font(Typography.wordmark)
                            Text("Version \(version)")
                                .font(Typography.footnote)
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("About").sectionLabelStyle()
                } footer: {
                    Text("A native client for Helm, built on T3 Code's open protocol.")
                        .font(Typography.footnote)
                }
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .usage: UsageView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private func valueLink(_ title: String, value: String, symbol: String, @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink(destination: destination) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(value)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textMuted)
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

struct EnvironmentDetailView: View {
    let environment: EnvironmentSession
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                row(String(localized: "Status"), environment.statusText)
                row(String(localized: "Address"), environment.saved.baseURL.absoluteString, mono: true)
                if let version = environment.config?.serverVersion {
                    row(String(localized: "Helm version"), version, mono: true)
                }
                row(String(localized: "Paired"), environment.saved.pairedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let config = environment.config {
                Section {
                    ForEach(config.providers) { provider in
                        HStack(spacing: 10) {
                            ProviderIcon(driver: provider.driver, iconUrl: provider.iconUrl, size: 18)
                                .frame(width: 22)
                            Text(provider.displayName)
                            Spacer()
                            Text(provider.isUsable ? String(localized: "Ready") : String(localized: "Unavailable"))
                                .font(Typography.footnote)
                                .foregroundStyle(provider.isUsable ? Palette.done : Palette.textMuted)
                        }
                    }
                } header: {
                    Text("Agents").sectionLabelStyle()
                }
            }
            Section {
                Button("Reconnect") { environment.reconnectNow() }
                Button("Pair again") { router.showPairing = true }
                Button("Remove this Mac", role: .destructive) { confirmRemove = true }
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle(environment.label)
        .confirmationDialog("Remove \(environment.label)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.remove(environment)
                dismiss()
            }
        } message: {
            Text("This phone forgets the Mac. Threads stay on the Mac.")
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.text)
            Spacer()
            Text(value)
                .font(mono ? Typography.mono(13) : Typography.body)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Alerts and the Live Activity, delivered by the Volna core when agents need you or finish.
struct NotificationsSection: View {
    @Bindable private var push = PushService.shared

    var body: some View {
        Section {
            if !push.isAvailable {
                Text("This build can't receive notifications.")
                    .foregroundStyle(Palette.textMuted)
            } else {
                HStack {
                    Text("Notifications")
                    Spacer()
                    Text(statusText)
                        .font(Typography.footnote)
                        .foregroundStyle(push.registered && push.authorization == .authorized ? Palette.done : Palette.textMuted)
                }
                if push.authorization == .denied {
                    Button("Allow in iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Toggle("Live Activity", isOn: $push.liveActivitiesEnabled)
                    .tint(Palette.accent)
                if let error = push.lastError {
                    Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                }
            }
        } header: {
            Text("Notifications").sectionLabelStyle()
        } footer: {
            Text("When an agent asks for approval, has a question, finishes or fails. The Live Activity shows work in progress on the lock screen and in the Dynamic Island.")
                .font(Typography.footnote)
        }
    }

    private var statusText: String {
        switch push.authorization {
        case .authorized, .provisional, .ephemeral:
            push.registered ? String(localized: "On") : String(localized: "Connecting…")
        case .denied: String(localized: "Off in iOS Settings")
        default: String(localized: "Not asked yet")
        }
    }
}
