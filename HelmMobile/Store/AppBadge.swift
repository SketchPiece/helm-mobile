import SwiftUI
import UserNotifications

/// The number on the app icon: threads waiting on you (an approval, a question or a plan to
/// confirm), like the desktop's dock badge. It follows the thread list while the app runs and
/// keeps the last count when it goes to the background.
@MainActor
enum AppBadge {
    static let enabledKey = "appIconBadge"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private static var shown: Int?

    static func count(in model: AppModel) -> Int {
        model.allThreads().count { $0.thread.needsAttention }
    }

    static func update(count: Int) {
        guard !AppModel.isUnitTestHost else { return }
        let value = isEnabled ? count : 0
        guard value != shown else { return }
        shown = value
        UNUserNotificationCenter.current().setBadgeCount(value)
    }

    /// Turning the badge on in a build without notifications still needs iOS's permission for it.
    static func requestPermissionIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
    }
}
