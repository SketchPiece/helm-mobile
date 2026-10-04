import SwiftUI

@main
struct HelmApp: App {
    @UIApplicationDelegateAdaptor(HelmAppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.system

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
            RootView()
                .environment(model)
                .onAppear { PushService.shared.start() }
                .preferredColorScheme(appearance.colorScheme)
                // Neutral chrome; amber is reserved for the primary action (send, allow, toggles).
                .tint(Palette.text)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.foregrounded()
                PushService.shared.foregrounded()
            }
        }
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
