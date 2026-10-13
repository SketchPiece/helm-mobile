import SwiftUI

/// Settings, split the way the app is: this phone, the connected computers, and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage(PhonePreferences.followUpKey) private var followUp = FollowUpBehavior.queue
    @AppStorage(PhonePreferences.returnKeyKey) private var returnKey = ReturnKeyBehavior.standard
    @AppStorage(PhonePreferences.afterStartKey) private var afterStart = AfterStartBehavior.open
    @AppStorage(PhonePreferences.codeFontSizeKey) private var codeFontSize = 0
    @AppStorage(PhonePreferences.codeWordWrapKey) private var codeWordWrap = false
    @AppStorage(PhonePreferences.screenRemoteKey) private var screenRemote = false

    private var projectCount: Int {
        model.allProjects().count { $0.environment.config?.isScratch($0.project) != true }
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.settingsPath) {
            Form {
                Section {
                    ForEach(model.environments) { environment in
                        NavigationLink {
                            EnvironmentDetailView(environment: environment)
                        } label: {
                            SettingsRow(environment.label, symbol: "laptopcomputer") {
                                StatusValue(text: environment.statusText, isOn: environment.isLive)
                            }
                        }
                    }
                    Button {
                        router.showPairing = true
                    } label: {
                        SettingsRow(String(localized: "Connect a computer"), symbol: "plus")
                            .foregroundStyle(Palette.accentText)
                    }
                } header: {
                    Text("Computers").sectionLabelStyle()
                }

                Section {
                    NavigationLink {
                        ProjectsListView()
                    } label: {
                        SettingsRow(String(localized: "Projects"), symbol: "folder") {
                            Text("\(projectCount)").foregroundStyle(Palette.textMuted).monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("projects")
                    NavigationLink {
                        ArchivedThreadsView()
                    } label: {
                        SettingsRow(String(localized: "Archived threads"), symbol: "archivebox")
                    }
                    NavigationLink {
                        ScheduledTasksView()
                    } label: {
                        SettingsRow(String(localized: "Scheduled tasks"), symbol: "calendar")
                    }
                    .accessibilityIdentifier("scheduledTasks")
                    NavigationLink {
                        UsageView()
                    } label: {
                        SettingsRow(String(localized: "Usage"), symbol: "chart.bar")
                    }
                    .accessibilityIdentifier("usage")
                } header: {
                    Text("Work").sectionLabelStyle()
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
                    valueLink(String(localized: "New threads"), value: afterStart.title, symbol: "square.and.pencil") {
                        AfterStartSettingsView()
                    }
                    .accessibilityIdentifier("afterStartSettings")
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
                        SettingsRow(String(localized: "Language and text size"), symbol: "textformat.size") {
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(Palette.textMuted)
                        }
                    }
                } header: {
                    Text("This phone").sectionLabelStyle()
                }

                Section {
                    Toggle(isOn: $screenRemote) {
                        SettingsRow(String(localized: "Screen remote"), symbol: "display")
                    }
                    .tint(Palette.accent)
                    .accessibilityIdentifier("screenRemote")
                } header: {
                    Text("Experimental").sectionLabelStyle()
                } footer: {
                    Text("The computer's screen on the phone, driven like a trackpad.")
                        .font(Typography.footnote)
                }

                Section {
                    NavigationLink {
                        TailscaleSettingsView()
                    } label: {
                        SettingsRow(String(localized: "Tailscale"), symbol: "network") {
                            Text(model.tailscale.isRunning ? String(localized: "Built-in") : String(localized: "VPN app"))
                                .font(Typography.footnote)
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    .accessibilityIdentifier("tailscaleSettings")
                    NavigationLink {
                        ConnectionLogView()
                    } label: {
                        SettingsRow(String(localized: "Connection log"), symbol: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Network").sectionLabelStyle()
                } footer: {
                    HStack(spacing: 8) {
                        HelmMark(size: 18)
                        Text("Helm \(version) · built on T3 Code's open protocol")
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
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
            SettingsRow(title, symbol: symbol) {
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

/// One settings row: an icon in a fixed column so every title starts at the same x, the title,
/// and an optional trailing value.
struct SettingsRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let trailing: Trailing

    init(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 26)
            Text(title)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// A status as a dot and a grey word, the same for computers and notifications.
struct StatusValue: View {
    let text: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOn ? Palette.done : Palette.textMuted)
                .frame(width: 7, height: 7)
            Text(text)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textMuted)
        }
    }
}

struct EnvironmentDetailView: View {
    let environment: EnvironmentSession
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @AppStorage(PhonePreferences.screenRemoteKey) private var screenRemoteOn = false
    @State private var showingScreen = false

    var body: some View {
        Form {
            if screenRemoteOn, environment.config?.capability("screenRemote") == true {
                Section {
                    Button {
                        showingScreen = true
                    } label: {
                        SettingsRow(String(localized: "Control the computer"), symbol: "display")
                            .foregroundStyle(Palette.accentText)
                    }
                    .accessibilityIdentifier("showScreen")
                }
                .fullScreenCover(isPresented: $showingScreen) {
                    ScreenRemoteView(environment: environment)
                }
            }
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
                Button("Reconnect") { environment.reconnectNow(reason: "Reconnect button") }
                NavigationLink("Connection log") { ConnectionLogView() }
                Button("Pair again") { router.showPairing = true }
                Button("Remove this computer", role: .destructive) { confirmRemove = true }
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
            Text("This phone forgets the computer. Threads stay on the computer.")
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
    @AppStorage(AppBadge.enabledKey) private var appIconBadge = true

    var body: some View {
        Section {
            if !push.isAvailable {
                Text("This build can't receive notifications.")
                    .foregroundStyle(Palette.textMuted)
            } else {
                SettingsRow(String(localized: "Notifications"), symbol: "bell") {
                    StatusValue(text: statusText, isOn: push.registered && push.authorization == .authorized)
                }
                if push.authorization == .denied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        SettingsRow(String(localized: "Allow in iOS Settings"), symbol: "arrow.up.forward.app")
                            .foregroundStyle(Palette.accentText)
                    }
                }
                Toggle(isOn: $push.liveActivitiesEnabled) {
                    SettingsRow(String(localized: "Live Activity"), symbol: "capsule")
                }
                    .tint(Palette.accent)
                if let error = push.lastError {
                    Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                }
            }
            Toggle(isOn: $appIconBadge) {
                SettingsRow(String(localized: "Badge on the app icon"), symbol: "app.badge")
            }
                .tint(Palette.accent)
                .onChange(of: appIconBadge) { _, on in
                    if on { Task { await AppBadge.requestPermissionIfNeeded() } }
                }
                .accessibilityIdentifier("appIconBadge")
        } header: {
            Text("Notifications").sectionLabelStyle()
        } footer: {
            Text("Approvals, questions and finished work. The badge counts threads waiting on you.")
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
