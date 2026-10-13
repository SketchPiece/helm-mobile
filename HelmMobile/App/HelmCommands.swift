import SwiftUI

/// What the menu bar and keyboard shortcuts act on: the window in front's router, and the thread
/// open in it.
extension FocusedValues {
    @Entry var router: Router?
    @Entry var openThread: OpenThreadActions?
}

/// The open thread, as the menu bar sees it; published by the thread screen.
struct OpenThreadActions {
    var isWorking: Bool
    var hasChanges: Bool
    var isReviewing: Bool
    var isSettled: Bool
    var isPinned: Bool
    var stop: () -> Void
    var toggleReview: () -> Void
    var perform: (AppModel.ThreadAction) -> Void
    var markUnread: () -> Void
}

/// The iPad menu bar (and the shortcuts a hardware keyboard shows when ⌘ is held). Items that
/// don't apply are disabled rather than hidden, as Apple asks.
struct HelmCommands: Commands {
    @FocusedValue(\.router) private var router
    @FocusedValue(\.openThread) private var thread

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { router?.startNewThread() }
                .keyboardShortcut("n")
                .disabled(router == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router?.showSettings = true }
                .keyboardShortcut(",")
                .disabled(router == nil)
        }
        SidebarCommands()
        CommandMenu("Thread") {
            Button("Stop Agent") { thread?.stop() }
                .keyboardShortcut(".")
                .disabled(thread?.isWorking != true)
            Divider()
            Button(thread?.isReviewing == true ? "Hide Changes" : "Review Changes") { thread?.toggleReview() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(thread?.hasChanges != true)
            Divider()
            Button(thread?.isSettled == true ? "Reopen" : "Settle") {
                thread?.perform(thread?.isSettled == true ? .unsettle : .settle)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(thread == nil)
            Button(thread?.isPinned == true ? "Unpin" : "Pin") {
                thread?.perform(thread?.isPinned == true ? .unpin : .pin)
            }
            .disabled(thread == nil)
            Button("Mark as Unread") { thread?.markUnread() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(thread == nil)
        }
        CommandMenu("Go") {
            Button("Search Threads") { router?.isSearching = true }
                .keyboardShortcut("k")
                .disabled(router == nil)
            Divider()
            Button("Next Thread") { router?.openAdjacent(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(router == nil)
            Button("Previous Thread") { router?.openAdjacent(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(router == nil)
        }
    }
}
