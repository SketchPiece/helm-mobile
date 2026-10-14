import SwiftUI

/// Switches in Settings → Performance that take parts of the thread view away, to find which of
/// them makes scrolling (with a trackpad most of all) expensive. Recordings name the ones on.
enum PerfExperiments {
    /// A lazy stack: rows off screen aren't built, laid out or hit-tested.
    static let lazyKey = "perf.lazyTimeline"
    /// Blocks drawn before "show more"; 0 draws them all.
    static let windowKey = "perf.timelineWindow"
    /// No tap-anywhere-to-hide-the-keyboard gesture over the conversation.
    static let noTapKey = "perf.noTapGesture"
    /// Read at launch (they sit on every message), so they need a restart.
    static let noTextSelectionKey = "perf.noTextSelection"
    static let noContextMenusKey = "perf.noContextMenus"

    static let noTextSelection = UserDefaults.standard.bool(forKey: noTextSelectionKey)
    static let noContextMenus = UserDefaults.standard.bool(forKey: noContextMenusKey)

    static var summary: String {
        let defaults = UserDefaults.standard
        var on: [String] = []
        if defaults.bool(forKey: lazyKey) { on.append("lazy") }
        let window = defaults.object(forKey: windowKey) as? Int ?? 30
        on.append("window \(window == 0 ? "all" : String(window))")
        if defaults.bool(forKey: noTapKey) { on.append("no tap gesture") }
        if noTextSelection { on.append("no text selection") }
        if noContextMenus { on.append("no context menus") }
        return on.joined(separator: ", ")
    }
}

extension View {
    /// `.textSelection(.enabled)`, unless the experiment turned it off.
    @ViewBuilder
    func selectableText() -> some View {
        if PerfExperiments.noTextSelection { textSelection(.disabled) } else { textSelection(.enabled) }
    }

    /// `.contextMenu`, unless the experiment turned context menus off.
    @ViewBuilder
    func messageContextMenu<Menu: View>(@ViewBuilder _ menu: () -> Menu) -> some View {
        if PerfExperiments.noContextMenus { self } else { contextMenu(menuItems: menu) }
    }
}
