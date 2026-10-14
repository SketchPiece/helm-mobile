import GameController
import SwiftUI
import UIKit

/// With a hardware keyboard iPadOS still shows a small bar at the bottom (the language pill) while
/// a text view is focused. It reports a keyboard of zero height but grows the bottom safe area by
/// the bar's height, which lifts the whole screen and leaves an empty strip below the composer.
@MainActor @Observable
final class HardwareKeyboardBar {
    static let shared = HardwareKeyboardBar()

    /// A text view is focused and the keyboard on screen is at most the hardware keyboard's bar.
    private(set) var isShown = false
    /// Any keyboard is up, the bar or the on-screen one.
    private(set) var isActive = false
    /// The window's bottom safe area (the home indicator's). UIKit's safe area leaves the keyboard
    /// out, so this stays right even when SwiftUI's is caught with the bar in it.
    private(set) var windowInset: CGFloat?

    /// The smallest on-screen keyboard is well over this.
    private static let maxBarHeight: CGFloat = 150

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let screen = note.object as? UIScreen
            MainActor.assumeIsolated { Self.shared.update(frame: frame, screen: screen?.bounds) }
        }
        // Moving focus or switching the keyboard's language sends a hide while the bar stays on
        // screen, and the next frame change can come before or after it. With a hardware keyboard
        // the bar is kept ignored through it (as Telegram does, which never reacts to the hide):
        // with nothing at the bottom, ignoring it puts back the same resting inset anyway. Only
        // a frame of the on-screen keyboard stops ignoring it.
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let shared = Self.shared
                if GCKeyboard.coalesced == nil { shared.isShown = false }
                shared.isActive = false
                shared.readWindowInset()
            }
        }
    }

    private func update(frame: CGRect, screen: CGRect?) {
        readWindowInset()
        let overlap = screen.map { frame.intersection($0).height } ?? frame.height
        let shown = overlap < Self.maxBarHeight
        if isShown != shown { isShown = shown }
        if !isActive { isActive = true }
    }

    private func readWindowInset() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let inset = window?.safeAreaInsets.bottom, inset != windowInset else { return }
        windowInset = inset
    }
}

extension View {
    /// Stays put under the hardware keyboard's bar; still rides above the on-screen keyboard.
    func ignoresHardwareKeyboardBar() -> some View {
        modifier(IgnoresHardwareKeyboardBar())
    }
}

private struct IgnoresHardwareKeyboardBar: ViewModifier {
    private var bar = HardwareKeyboardBar.shared
    /// The bottom safe area with no keyboard at all (the home indicator's), put back while the
    /// bar's taller one is ignored. Caught between a hide and the next show it can still hold the
    /// bar, which only ever adds, so the smaller of it and the window's wins.
    /// Unset when the screen opened with a keyboard already up.
    @State private var restInset: CGFloat?

    private var resting: CGFloat {
        [restInset, bar.windowInset].compactMap(\.self).min() ?? 0
    }

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, bar.isShown ? resting : 0)
            .ignoresSafeArea(bar.isShown ? .all : [], edges: .bottom)
            .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.bottom) { inset in
                if !bar.isActive { restInset = inset }
            }
    }
}
