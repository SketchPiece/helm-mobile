import AppIntents
import UIKit

/// What other parts of the system ask of the app: the "New task" quick action and Shortcuts
/// intent, and shares from other apps. RootView routes the pending request once the thread list
/// is up (after pairing, on a fresh install), like `PushService.pendingThread`.
@MainActor
@Observable
final class LaunchActions {
    static let shared = LaunchActions()

    /// Open New Thread with this (empty for a plain "New task").
    var pendingNewThread: SharedContent?

    static let newTaskShortcut = "com.sketchpiece.helm.new-task"

    /// Shared files land here; the folder belongs to this run and is cleared on the next launch.
    private let inbox = FileManager.default.temporaryDirectory.appending(path: "Shared", directoryHint: .isDirectory)

    private init() {
        try? FileManager.default.removeItem(at: inbox)
    }

    func newThread() {
        pendingNewThread = pendingNewThread ?? SharedContent()
    }

    /// Handles a home-screen quick action; false for one this build doesn't know.
    @discardableResult
    func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == Self.newTaskShortcut else { return false }
        newThread()
        return true
    }

    /// Takes whatever the share extension left in the App Group and asks for New Thread with it.
    func pickUpShares() {
        guard !AppModel.isUnitTestHost, let root = ShareInbox.root else { return }
        let content = ShareInbox.take(from: root, to: inbox)
        guard !content.isEmpty else { return }
        var pending = pendingNewThread ?? SharedContent()
        pending.append(content)
        pendingNewThread = pending
    }
}

/// "Start a Helm task" in Shortcuts, Spotlight and Siri: opens New Thread.
struct StartTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Helm task"
    static let description = IntentDescription("Opens a new thread in Helm.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchActions.shared.newThread()
        return .result()
    }
}

struct HelmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTaskIntent(),
            phrases: ["Start a task in \(.applicationName)", "New \(.applicationName) task"],
            shortTitle: "New task",
            systemImageName: "square.and.pencil"
        )
    }
}
