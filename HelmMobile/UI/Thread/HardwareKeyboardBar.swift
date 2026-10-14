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

    /// The smallest on-screen keyboard is well over this.
    private static let maxBarHeight: CGFloat = 150

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let screen = note.object as? UIScreen
            MainActor.assumeIsolated { Self.shared.update(frame: frame, screen: screen?.bounds) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Self.shared.isShown = false
                Self.shared.isActive = false
            }
        }
    }

    private func update(frame: CGRect, screen: CGRect?) {
        let overlap = screen.map { frame.intersection($0).height } ?? frame.height
        let shown = overlap < Self.maxBarHeight
        if isShown != shown { isShown = shown }
        if !isActive { isActive = true }
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
    /// bar's taller one is ignored.
    @State private var restInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, bar.isShown ? restInset : 0)
            .ignoresSafeArea(bar.isShown ? .all : [], edges: .bottom)
            .onGeometryChange(for: CGFloat.self, of: \.safeAreaInsets.bottom) { inset in
                if !bar.isActive { restInset = inset }
            }
    }
}
