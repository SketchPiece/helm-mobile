import SwiftUI
import UIKit

/// The computer's screen, driven like Chrome Remote Desktop's trackpad mode: a finger anywhere
/// moves the cursor, the view keeps the cursor in the middle and slides the screen under it
/// (stopping at the screen's edges), a tap clicks, pinching zooms around the cursor.
struct ScreenRemoteView: View {
    @State private var remote: ScreenRemote
    @State private var viewport = ScreenViewport()
    @State private var showsNotice = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(environment: EnvironmentSession) {
        _remote = State(initialValue: ScreenRemote(environment: environment))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScreenCanvas(remote: remote, viewport: viewport)
                .ignoresSafeArea()
                .opacity(remote.framesShown > 0 ? 1 : 0)
            switch remote.phase {
            case .connecting: connecting
            case .failed(let message): failure(message)
            case .live where remote.framesShown == 0: connecting
            case .live: EmptyView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if viewport.isZoomedIn, remote.desktopSize != .zero {
                ScreenMiniMap(desktop: remote.desktopSize, visible: viewport.visibleRect)
                    .padding(.trailing, 14)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if showsNotice, let notice = remote.notice { noticeBanner(notice) }
        }
        .overlay(alignment: .bottom) {
            if !viewport.keyboardShown {
                ScreenToolbar(remote: remote, viewport: viewport) { dismiss() }
                    .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewport.isZoomedIn)
        .animation(.easeInOut(duration: 0.2), value: viewport.keyboardShown)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task { await remote.connect() }
        .onDisappear { remote.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            // Nobody watches a phone in a pocket: the computer stops capturing until it's back.
            switch phase {
            case .background: remote.disconnect()
            case .active where remote.phase != .live: Task { await remote.connect() }
            default: break
            }
        }
    }

    private var connecting: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white)
            Text("Connecting to \(remote.environment.label)…")
                .font(Typography.subheadline)
                .foregroundStyle(.white.opacity(0.8))
            Button("Close") { dismiss() }
                .buttonStyle(.glass)
                .padding(.top, 10)
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(Typography.body)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                Button("Try again") { Task { await remote.connect() } }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
            }
        }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised")
            Text(notice).font(Typography.footnote)
            Spacer(minLength: 0)
            Button { showsNotice = false } label: { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

/// How the computer's screen sits on the phone's: zoom (phone points per computer point) and
/// what part of the screen shows. The canvas owns the math; the overlays read it.
@MainActor
@Observable
final class ScreenViewport {
    /// Phone points per computer point; 0 until the screen's size is known.
    var zoom: CGFloat = 0
    /// The whole screen fits.
    var fitZoom: CGFloat = 0
    /// The screen covers the phone's (in portrait, its height does): where it opens, as in the design's A.
    var fillZoom: CGFloat = 0
    /// The part of the computer's screen on view, in its points.
    var visibleRect = CGRect.zero
    var keyboardShown = false
    /// Asks the canvas to show or hide the keyboard (it owns the first responder).
    var wantsKeyboard = false
    /// Mac modifiers held for the next key (the accessory row's ⌘ ⌥ ⌃ ⇧).
    var modifiers: Set<ScreenRemote.Modifier> = []

    var maxZoom: CGFloat { max(fitZoom, 2.5) }
    var isZoomedIn: Bool { fitZoom > 0 && zoom > fitZoom * 1.05 }

    /// The toolbar's zoom button: the whole screen, or the phone covered.
    func toggleFit() {
        zoom = isZoomedIn ? fitZoom : min(maxZoom, max(fillZoom, fitZoom * 2))
    }
}

// MARK: Canvas

private struct ScreenCanvas: UIViewRepresentable {
    let remote: ScreenRemote
    let viewport: ScreenViewport

    func makeUIView(context: Context) -> ScreenCanvasView {
        ScreenCanvasView(remote: remote, viewport: viewport)
    }

    func updateUIView(_ view: ScreenCanvasView, context: Context) {
        // Read so SwiftUI calls back when they change; the view lays itself out from them.
        _ = (remote.cursor, remote.desktopSize, viewport.zoom)
        view.setNeedsLayout()
        if viewport.wantsKeyboard != view.isFirstResponder {
            _ = viewport.wantsKeyboard ? view.becomeFirstResponder() : view.resignFirstResponder()
        }
    }
}

/// The video, the cursor drawn over it, the gestures and the keyboard.
final class ScreenCanvasView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    private let remote: ScreenRemote
    private let viewport: ScreenViewport
    private let desktop = CALayer()
    private let cursorView = UIImageView(image: ScreenCanvasView.cursorImage)
    /// Pinned to the keyboard's top so its coming and going lays the view out again.
    private let keyboardEdge = UIView()
    private var fling: CADisplayLink?
    private var flingVelocity = CGPoint.zero
    private var dragLocation = CGPoint.zero
    private var pinchActive = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(remote: ScreenRemote, viewport: ScreenViewport) {
        self.remote = remote
        self.viewport = viewport
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(desktop)
        desktop.addSublayer(remote.layer)
        desktop.backgroundColor = UIColor(white: 0.08, alpha: 1).cgColor
        addSubview(cursorView)
        keyboardEdge.isHidden = true
        addSubview(keyboardEdge)
        keyboardEdge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keyboardEdge.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            keyboardEdge.heightAnchor.constraint(equalToConstant: 1),
            keyboardEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardEdge.widthAnchor.constraint(equalToConstant: 1),
        ])
        keyboardLayoutGuide.usesBottomSafeArea = false
        addGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = remote.desktopSize
        guard size.width > 0, size.height > 0, bounds.width > 0 else { return }
        // Above the keyboard when it's up: the cursor should never sit under the keys.
        let keyboardTop = keyboardLayoutGuide.layoutFrame.minY
        let available = CGSize(width: bounds.width, height: min(bounds.height, keyboardTop > 0 ? keyboardTop : bounds.height))
        let fit = min(available.width / size.width, available.height / size.height)
        let fill = max(available.width / size.width, available.height / size.height)
        if viewport.fitZoom != fit {
            // Opens covering the phone; the whole screen stays whole across rotation.
            let wasFit = viewport.zoom > 0 && viewport.zoom <= viewport.fitZoom * 1.01
            let opening = viewport.zoom == 0
            viewport.fitZoom = fit
            viewport.fillZoom = fill
            if opening { viewport.zoom = min(fill, viewport.maxZoom) } else if wasFit { viewport.zoom = fit }
        }
        let zoom = min(max(viewport.zoom, fit), viewport.maxZoom)
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let cursor = remote.cursor
        // The cursor in the middle, unless that would show past the screen's edge.
        func origin(_ length: CGFloat, _ room: CGFloat, _ at: CGFloat) -> CGFloat {
            if length <= room { return (room - length) / 2 }
            return min(0, max(room - length, room / 2 - at * zoom))
        }
        let originPoint = CGPoint(x: origin(scaled.width, available.width, cursor.x),
                                  y: origin(scaled.height, available.height, cursor.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desktop.frame = CGRect(origin: originPoint, size: scaled)
        remote.layer.frame = desktop.bounds
        CATransaction.commit()
        // The arrow's tip (3, 2 in the image) on the cursor.
        cursorView.frame.origin = CGPoint(x: originPoint.x + cursor.x * zoom - 3, y: originPoint.y + cursor.y * zoom - 2)
        let visible = CGRect(x: -originPoint.x / zoom, y: -originPoint.y / zoom,
                             width: available.width / zoom, height: available.height / zoom)
            .intersection(CGRect(origin: .zero, size: size))
        if viewport.visibleRect != visible { viewport.visibleRect = visible }
        let keyboardUp = keyboardTop > 0 && keyboardTop < bounds.height - 1
        if viewport.keyboardShown != keyboardUp { viewport.keyboardShown = keyboardUp }
    }

    private var zoom: CGFloat { max(viewport.zoom, 0.01) }

    // MARK: Gestures

    private func addGestures() {
        let move = UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.allowedScrollTypesMask = .all
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClick))
        rightClick.numberOfTouchesRequired = 2
        let click = UITapGestureRecognizer(target: self, action: #selector(click))
        click.require(toFail: rightClick)
        // Hold still, then move: drags with the button down (selecting text, moving windows).
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        drag.minimumPressDuration = 0.35
        drag.allowableMovement = 12
        for recognizer in [move, scroll, pinch, rightClick, click, drag] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two fingers both scroll and pinch; which one wins is decided by how far they spread.
        let pair = [gestureRecognizer, other]
        return pair.contains { $0 is UIPinchGestureRecognizer }
            && pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
    }

    @objc private func moveCursor(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopFling()
        case .changed:
            let delta = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            remote.moveCursor(by: CGPoint(x: delta.x / zoom, y: delta.y / zoom))
        case .ended:
            let velocity = pan.velocity(in: self)
            if hypot(velocity.x, velocity.y) > 300 { startFling(velocity) }
        default: break
        }
    }

    /// A flick keeps the cursor gliding and slowing down, like a laptop's trackpad.
    private func startFling(_ velocity: CGPoint) {
        flingVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(stepFling(_:)))
        link.add(to: .main, forMode: .common)
        fling = link
    }

    @objc private func stepFling(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        remote.moveCursor(by: CGPoint(x: flingVelocity.x * dt / zoom, y: flingVelocity.y * dt / zoom))
        let decay = pow(0.05, dt)  // loses 95% of its speed a second
        flingVelocity = CGPoint(x: flingVelocity.x * decay, y: flingVelocity.y * decay)
        if hypot(flingVelocity.x, flingVelocity.y) < 40 { stopFling() }
    }

    private func stopFling() {
        fling?.invalidate()
        fling = nil
    }

    @objc private func scroll(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .changed, !pinchActive else {
            pan.setTranslation(.zero, in: self)
            return
        }
        let delta = pan.translation(in: self)
        pan.setTranslation(.zero, in: self)
        // The content follows the fingers, at the computer's own scale.
        remote.scroll(dx: delta.x * 2 / zoom.squareRoot(), dy: delta.y * 2 / zoom.squareRoot())
    }

    @objc private func pinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began: pinchActive = false
        case .changed:
            // Small spreads are a two-finger scroll; past that it's a zoom.
            if !pinchActive, abs(pinch.scale - 1) < 0.08 { return }
            pinchActive = true
            viewport.zoom = min(max(viewport.zoom * pinch.scale, viewport.fitZoom), viewport.maxZoom)
            pinch.scale = 1
        default: pinchActive = false
        }
    }

    @objc private func click() {
        stopFling()
        remote.click()
        haptic.impactOccurred(intensity: 0.6)
        ripple()
    }

    @objc private func rightClick() {
        remote.click(.right)
        haptic.impactOccurred()
        ripple()
    }

    @objc private func drag(_ press: UILongPressGestureRecognizer) {
        let location = press.location(in: self)
        switch press.state {
        case .began:
            stopFling()
            dragLocation = location
            remote.press(down: true)
            haptic.impactOccurred(intensity: 1)
        case .changed:
            remote.moveCursor(by: CGPoint(x: (location.x - dragLocation.x) / zoom, y: (location.y - dragLocation.y) / zoom))
            dragLocation = location
        default:
            remote.press(down: false)
        }
    }

    /// A ring at the cursor, so a click is seen even when the screen doesn't change.
    private func ripple() {
        let ring = CAShapeLayer()
        let tip = CGPoint(x: cursorView.frame.minX + 3, y: cursorView.frame.minY + 2)
        ring.path = UIBezierPath(ovalIn: CGRect(x: -20, y: -20, width: 40, height: 40)).cgPath
        ring.position = tip
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(Palette.accent).cgColor
        ring.lineWidth = 2
        layer.insertSublayer(ring, below: cursorView.layer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.35
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, viewport.wantsKeyboard { viewport.wantsKeyboard = false }
        return resigned
    }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark

    func insertText(_ text: String) {
        // With ⌘ ⌥ or ⌃ held, a key is a shortcut (⌘C), sent by its key code; otherwise text.
        let shortcut = !viewport.modifiers.subtracting([.shift]).isEmpty
        if shortcut || (text.count == 1 && text != "\n" && !viewport.modifiers.isEmpty) {
            if let character = text.first, let code = MacKeyCode.code(for: character) {
                remote.key(code, modifiers: viewport.modifiers)
            }
            viewport.modifiers = []
        } else if text == "\n" {
            remote.key(MacKeyCode.returnKey)
        } else {
            remote.type(text)
        }
    }

    func deleteBackward() {
        remote.key(MacKeyCode.delete, modifiers: viewport.modifiers)
        viewport.modifiers = []
    }

    override var inputAccessoryView: UIView? {
        if let accessory { return accessory }
        let host = UIHostingController(rootView: ScreenKeyRow(remote: remote, viewport: viewport))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 50), inputViewStyle: .keyboard)
        container.allowsSelfSizing = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        accessory = container
        return container
    }

    private var accessory: UIView?

    // MARK: Cursor

    /// The Mac's arrow, drawn here: white outline, black fill, tip at (3, 2).
    private static let cursorImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 26, height: 34))
        return renderer.image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 3, y: 2))
            path.addLine(to: CGPoint(x: 3, y: 27))
            path.addLine(to: CGPoint(x: 9.5, y: 21))
            path.addLine(to: CGPoint(x: 13.7, y: 30.6))
            path.addLine(to: CGPoint(x: 17.7, y: 28.8))
            path.addLine(to: CGPoint(x: 13.6, y: 19.5))
            path.addLine(to: CGPoint(x: 22, y: 19.5))
            path.close()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.5).cgColor)
            UIColor.black.setFill()
            path.fill()
            context.cgContext.setShadow(offset: .zero, blur: 0)
            UIColor.white.setStroke()
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            path.stroke()
        }
    }()
}

// MARK: Overlays

/// Where the view is on the whole screen, while zoomed in.
private struct ScreenMiniMap: View {
    let desktop: CGSize
    let visible: CGRect

    var body: some View {
        let width: CGFloat = 92
        let scale = width / desktop.width
        RoundedRectangle(cornerRadius: 6)
            .fill(.black.opacity(0.35))
            .frame(width: width, height: desktop.height * scale)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Palette.accent, lineWidth: 1.5)
                    .frame(width: max(4, visible.width * scale), height: max(4, visible.height * scale))
                    .offset(x: visible.minX * scale, y: visible.minY * scale)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 7))
    }
}

/// Keyboard, zoom, a few Mac-only keys and close, floating at the bottom.
private struct ScreenToolbar: View {
    let remote: ScreenRemote
    let viewport: ScreenViewport
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            button("keyboard", label: "Keyboard") { viewport.wantsKeyboard = true }
            button(viewport.isZoomedIn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   label: viewport.isZoomedIn ? "Whole screen" : "Zoom in") {
                withAnimation(.snappy) { viewport.toggleFit() }
            }
            ScreenKeysMenu(remote: remote)
                .equatable()
            button("xmark", label: "Close") { close() }
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
        .accessibilityLabel(Text(label))
    }
}

/// Mac shortcuts with no key on the phone. Its own equatable view so a cursor move doesn't
/// rebuild the menu under the finger (AGENTS.md).
private struct ScreenKeysMenu: View, @MainActor Equatable {
    let remote: ScreenRemote

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.remote === rhs.remote }

    var body: some View {
        Menu {
            Button("Right click", systemImage: "cursorarrow.click.2") { remote.click(.right) }
            Button("Escape", systemImage: "escape") { remote.key(MacKeyCode.escape) }
            Button("Switch app (⌘Tab)", systemImage: "square.on.square") { remote.key(MacKeyCode.tab, modifiers: [.cmd]) }
            Button("Spotlight (⌘Space)", systemImage: "magnifyingglass") { remote.key(MacKeyCode.space, modifiers: [.cmd]) }
            Button("Mission Control", systemImage: "rectangle.3.group") { remote.key(MacKeyCode.up, modifiers: [.ctrl]) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
        .accessibilityLabel("More keys")
    }
}

/// Above the keyboard: the Mac keys a phone keyboard lacks. Modifiers stay held for the next key.
private struct ScreenKeyRow: View {
    let remote: ScreenRemote
    let viewport: ScreenViewport

    var body: some View {
        HStack(spacing: 6) {
            key("esc") { remote.key(MacKeyCode.escape, modifiers: take()) }
            key("tab") { remote.key(MacKeyCode.tab, modifiers: take()) }
            modifier("⌘", .cmd)
            modifier("⌥", .alt)
            modifier("⌃", .ctrl)
            modifier("⇧", .shift)
            key("←") { remote.key(MacKeyCode.left, modifiers: take()) }
            key("↑") { remote.key(MacKeyCode.up, modifiers: take()) }
            key("↓") { remote.key(MacKeyCode.down, modifiers: take()) }
            key("→") { remote.key(MacKeyCode.right, modifiers: take()) }
            Button { viewport.wantsKeyboard = false } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .frame(width: 34, height: 36)
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Hide the keyboard")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func take() -> Set<ScreenRemote.Modifier> {
        defer { viewport.modifiers = [] }
        return viewport.modifiers
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.white.opacity(0.18), in: .rect(cornerRadius: 7))
        }
        .foregroundStyle(.white)
    }

    private func modifier(_ title: String, _ modifier: ScreenRemote.Modifier) -> some View {
        let on = viewport.modifiers.contains(modifier)
        return Button {
            if on { viewport.modifiers.remove(modifier) } else { viewport.modifiers.insert(modifier) }
        } label: {
            Text(verbatim: title)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(on ? Palette.accent : Color.white.opacity(0.18), in: .rect(cornerRadius: 7))
                .foregroundStyle(on ? Palette.accentForeground : .white)
        }
    }
}
