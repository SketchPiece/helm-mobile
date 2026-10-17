import SwiftUI

@main
struct HelmApp: App {
    @UIApplicationDelegateAdaptor(HelmAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage(PhonePreferences.codeFontSizeKey) private var codeFontSize = 0
    @AppStorage(PhonePreferences.codeWordWrapKey) private var codeWordWrap = false
    @AppStorage(PhonePreferences.diffWordWrapKey) private var diffWordWrap = true

    init() {
        // Navigation titles in IBM Plex, like the rest of the app.
        let bar = UINavigationBar.appearance()
        if let large = UIFont(name: "IBMPlexSans-SemiBold", size: 32),
           let inline = UIFont(name: "IBMPlexSans-SemiBold", size: 17)
        {
            bar.largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: large)]
            bar.titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline)]
        }
    }

    var body: some Scene {
        WindowGroup {
            chrome(RootView())
                .onAppear { PushService.shared.start() }
        }
        .commands { HelmCommands(model: model) }
        // iPad: a thread in a window of its own ("Open in New Window").
        WindowGroup(id: ThreadWindow.id, for: ThreadRef.self) { $ref in
            chrome(ThreadWindow(ref: ref))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                LaunchActions.shared.pickUpShares()
                model.foregrounded()
                PushService.shared.foregrounded()
            } else if phase == .background {
                model.backgrounded()
            }
        }
    }
}

extension HelmApp {
    /// What every window shares: the model, the appearance, code settings and the neutral tint.
    private func chrome(_ content: some View) -> some View {
        content
            .environment(model)
            .preferredColorScheme(appearance.colorScheme)
            .environment(\.codeAppearance, CodeAppearance(fontSize: codeFontSize, wordWrap: codeWordWrap, diffWordWrap: diffWordWrap))
            // Neutral chrome; amber is reserved for the primary action (send, allow, toggles).
            .tint(Palette.text)
            .perfDiagnostics()
            .macAuthRequests()
    }
}

/// Receives the APNs device token and home-screen quick actions.
final class HelmAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushService.shared.didRegister(deviceToken: deviceToken) }
    }

    /// A quick action that launched the app arrives here; one tapped while it runs, in the scene delegate.
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem {
            MainActor.assumeIsolated { _ = LaunchActions.shared.perform(item) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = HelmSceneDelegate.self
        return configuration
    }
}

final class HelmSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        await MainActor.run { LaunchActions.shared.perform(shortcutItem) }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}
