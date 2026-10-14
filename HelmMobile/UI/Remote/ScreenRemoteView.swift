import GameController
import SwiftUI
import UIKit

/// The computer's screen, driven like Chrome Remote Desktop's trackpad mode: a finger anywhere
/// moves the cursor, the view keeps the cursor in the middle and slides the screen under it
/// (stopping at the screen's edges), a tap clicks, pinching zooms around the cursor.
struct ScreenRemoteView: View {
    @State private var remote: ScreenRemote
    @State private var viewport = ScreenViewport()
    @State private var showsNotice = true
    /// Which side of the screen the toolbar lives on; the mini map takes the other one.
    @AppStorage(PhonePreferences.screenToolbarLeadingKey) private var toolbarLeading = false
    @Environment(\.scenePhase) private var scenePhase
    private let close: () -> Void

    init(environment: EnvironmentSession, close: @escaping () -> Void) {
        _remote = State(initialValue: ScreenRemote(environment: environment))
        self.close = close
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
        .overlay(alignment: toolbarLeading ? .topTrailing : .topLeading) {
            if viewport.isZoomedIn, remote.desktopSize != .zero {
                ScreenMiniMap(desktop: remote.desktopSize, visible: viewport.visibleRect)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if showsNotice, let notice = remote.notice { noticeBanner(notice) }
        }
        .overlay {
            if !viewport.keyboardShown {
                ScreenToolbarDock(remote: remote, viewport: viewport, leading: $toolbarLeading) { close() }
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: Bindable(viewport).showsWindows) {
            ScreenWindowPicker(remote: remote)
        }
        .onChange(of: remote.notice) { showsNotice = true }
        .animation(.easeInOut(duration: 0.2), value: viewport.isZoomedIn)
        .animation(.easeInOut(duration: 0.2), value: toolbarLeading)
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
            if remote.isAway {
                Label("Away from home: a lighter picture", systemImage: "antenna.radiowaves.left.and.right")
                    .font(Typography.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button("Close") { close() }
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
                Button("Close") { close() }
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
    /// The screen covers the phone's (in portrait, its height does).
    var fillZoom: CGFloat = 0
    /// Settings' choice of how the screen opens.
    let openZoom = UserDefaults.standard.string(forKey: PhonePreferences.screenOpenZoomKey)
        .flatMap(ScreenOpenZoom.init(rawValue:)) ?? .fill
    /// Settings' cursor speed, scroll direction and click feedback, read when the screen opens.
    let cursorSpeed = (UserDefaults.standard.string(forKey: PhonePreferences.screenCursorSpeedKey)
        .flatMap(ScreenCursorSpeed.init(rawValue:)) ?? .normal).factor
    let scrollSign: CGFloat = UserDefaults.standard.bool(forKey: PhonePreferences.screenReverseScrollKey) ? -1 : 1
    let clickFeedback = UserDefaults.standard.object(forKey: PhonePreferences.screenClickFeedbackKey) as? Bool ?? true
    /// Trackpad or touch: settings' choice, switched from the toolbar while open.
    var inputMode = UserDefaults.standard.string(forKey: PhonePreferences.screenInputModeKey)
        .flatMap(ScreenInputMode.init(rawValue:)) ?? .trackpad
    /// Touch mode: the computer's point in the middle of the view (fingers pan and pinch it).
    var touchCenter = CGPoint.zero
    /// The part of the computer's screen on view, in its points.
    var visibleRect = CGRect.zero
    var keyboardShown = false
    /// The toolbar folds into a tab on its edge once the screen is touched; the tab brings it back.
    var toolbarHidden = false
    /// Asks the canvas to show or hide the keyboard (it owns the first responder).
    var wantsKeyboard = false
    /// Mac modifiers held for the next key (the accessory row's ⌘ ⌥ ⌃ ⇧).
    var modifiers: Set<ScreenRemote.Modifier> = []
    /// The list of the other displays' windows, to bring one to this iPad's.
    var showsWindows = false

    var maxZoom: CGFloat { max(fitZoom, 2.5) }
    var isZoomedIn: Bool { fitZoom > 0 && zoom > fitZoom * 1.05 }

    /// Where a screen opens, and a display switched to.
    var openingZoom: CGFloat {
        switch openZoom {
        case .fill: min(fillZoom, maxZoom)
        case .fit: fitZoom
        case .actual: min(max(1, fitZoom), maxZoom)
        }
    }

    /// The toolbar's zoom button: the whole screen, or the phone covered.
    func toggleFit() {
        zoom = isZoomedIn ? fitZoom : min(maxZoom, max(fillZoom, fitZoom * 2))
    }
}

// MARK: Presenting

/// Shows the screen remote over everything. A UIKit controller rather than a SwiftUI cover: only a
/// controller UIKit asks can lock the pointer, which on an iPad with a trackpad or mouse hides
/// its pointer and hands the moves and clicks to the Mac (GameController's GCMouse).
@MainActor
enum ScreenRemotePresenter {
    static func present(_ environment: EnvironmentSession) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = ScreenRemoteController(environment: environment)
        top.present(controller, animated: true)
    }
}

final class ScreenRemoteController: UIViewController {
    private let environment: EnvironmentSession

    init(environment: EnvironmentSession) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let host = UIHostingController(rootView: ScreenRemoteView(environment: environment) { [weak self] in
            self?.dismiss(animated: true)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.backgroundColor = .black
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfPrefersPointerLocked()
    }

    /// Trackpad mode: the iPad's pointer is hidden and its raw motion drives the computer's.
    var locksPointer = true {
        didSet { if locksPointer != oldValue { setNeedsUpdateOfPrefersPointerLocked() } }
    }

    override var prefersPointerLocked: Bool { locksPointer }
    override var prefersStatusBarHidden: Bool { true }
    // The toolbar lives on a side, so the bottom edge stays the system's and its indicator fades.
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { nil }
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
        _ = (remote.cursor, remote.desktopSize, remote.cursorShape, viewport.zoom, viewport.touchCenter)
        view.setNeedsLayout()
        view.apply(wantsKeyboard: viewport.wantsKeyboard)
        view.apply(inputMode: viewport.inputMode)
    }
}

/// The video, the cursor drawn over it, the gestures and the keyboard.
///
/// Two ways to drive it. Trackpad: the whole screen is a trackpad, the view keeps the cursor in
/// the middle, an iPad's trackpad or mouse moves the cursor by its raw motion (pointer locked).
/// Touch: a tap clicks where it lands, a finger scrolls, touch and hold drags, two fingers pan
/// a zoomed-in screen, and an iPad's own pointer points straight at the computer's screen.
/// In both, Apple Pencil is a mouse, scrolls glide with momentum the computer shows as a real
/// trackpad's, and three fingers swipe for Mission Control, App Exposé and Spaces.
final class ScreenCanvasView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private let remote: ScreenRemote
    private let viewport: ScreenViewport
    private let desktop = CALayer()
    private let cursorView = UIImageView(image: ScreenCanvasView.cursorImage)
    /// Where the cursor's tip is on the phone's screen.
    private var cursorTip = CGPoint.zero
    /// Pinned to the keyboard's top so its coming and going lays the view out again.
    private let keyboardEdge = UIView()
    private var fling: CADisplayLink?
    private var flingVelocity = CGPoint.zero
    private var momentum: CADisplayLink?
    private var momentumVelocity = CGPoint.zero
    private var momentumStarted = false
    private var dragLocation = CGPoint.zero
    private var pinchActive = false
    /// A two-finger scroll that turned into a pinch doesn't glide.
    private var scrollPinched = false
    /// Where the computer's screen sits in the view and at what zoom, as last laid out.
    private var desktopOrigin = CGPoint.zero
    private var laidOutZoom: CGFloat = 1
    /// The computer's screen size the zoom was last set for; another display opens afresh.
    private var laidOutDesktop = CGSize.zero
    private var shownShape: ScreenRemote.CursorShape?
    /// The button an iPad's pointer or Apple Pencil holds down.
    private var pointerButton: ScreenRemote.Button?
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
        addInteraction(UIPointerInteraction(delegate: self))
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(mouseConnected(_:)), name: .GCMouseDidConnect, object: nil)
        center.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: .GCKeyboardDidConnect, object: nil)
        GCMouse.mice().forEach(attach)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        hardwareKeyboardChanged()
        apply(inputMode: viewport.inputMode, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Three fingers are the computer's, not iPadOS's undo and copy gestures.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private var touchMode: Bool { viewport.inputMode == .touch }
    private var appliedMode: ScreenInputMode?

    /// Trackpad mode locks the iPad's pointer so its raw motion drives the cursor; touch mode
    /// lets it point at the screen.
    func apply(inputMode: ScreenInputMode, force: Bool = false) {
        guard force || inputMode != appliedMode else { return }
        appliedMode = inputMode
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? ScreenRemoteController {
                controller.locksPointer = inputMode == .trackpad
                return
            }
            responder = next
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        remote.viewSizeChanged(bounds.size)
        let size = remote.desktopSize
        guard size.width > 0, size.height > 0, bounds.width > 0 else { return }
        // Above the keyboard when it's up: the cursor should never sit under the keys.
        let keyboardTop = keyboardLayoutGuide.layoutFrame.minY
        let available = CGSize(width: bounds.width, height: min(bounds.height, keyboardTop > 0 ? keyboardTop : bounds.height))
        let fit = min(available.width / size.width, available.height / size.height)
        let fill = max(available.width / size.width, available.height / size.height)
        let newScreen = size != laidOutDesktop
        if viewport.fitZoom != fit || newScreen {
            // Opens as settings say; the whole screen stays whole across rotation.
            let wasFit = viewport.zoom > 0 && viewport.zoom <= viewport.fitZoom * 1.01
            let opening = viewport.zoom == 0 || newScreen
            laidOutDesktop = size
            viewport.fitZoom = fit
            viewport.fillZoom = fill
            if opening {
                viewport.zoom = viewport.openingZoom
                viewport.touchCenter = CGPoint(x: size.width / 2, y: size.height / 2)
            } else if wasFit {
                viewport.zoom = fit
            }
        }
        let zoom = min(max(viewport.zoom, fit), viewport.maxZoom)
        let scaled = CGSize(width: size.width * zoom, height: size.height * zoom)
        let cursor = remote.cursor
        // Trackpad: the cursor in the middle; touch: wherever the fingers moved the view. Never
        // past the screen's edge.
        let center = touchMode ? viewport.touchCenter : cursor
        func origin(_ length: CGFloat, _ room: CGFloat, _ at: CGFloat) -> CGFloat {
            if length <= room { return (room - length) / 2 }
            return min(0, max(room - length, room / 2 - at * zoom))
        }
        let originPoint = CGPoint(x: origin(scaled.width, available.width, center.x),
                                  y: origin(scaled.height, available.height, center.y))
        desktopOrigin = originPoint
        laidOutZoom = zoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desktop.frame = CGRect(origin: originPoint, size: scaled)
        remote.layer.frame = desktop.bounds
        CATransaction.commit()
        cursorTip = CGPoint(x: originPoint.x + cursor.x * zoom, y: originPoint.y + cursor.y * zoom)
        if let shape = remote.cursorShape {
            // The computer's own arrow (an I-beam over text, a hand over a link), at its size
            // on the screen, within reason; its hot spot on the cursor.
            if shownShape != shape {
                shownShape = shape
                cursorView.image = shape.image
            }
            let scale = min(max(zoom, 0.6), 1.25)
            cursorView.frame = CGRect(x: cursorTip.x - shape.hotSpot.x * scale, y: cursorTip.y - shape.hotSpot.y * scale,
                                      width: shape.size.width * scale, height: shape.size.height * scale)
        } else {
            // The arrow at the size the computer draws it, scaled with the screen (the Mac's is
            // about 24 points tall, the image's 29), never so small it gets lost; its tip (3, 2) on the cursor.
            let arrowScale = min(max(zoom * 24 / 29, 0.4), 1)
            cursorView.frame = CGRect(x: cursorTip.x - 3 * arrowScale, y: cursorTip.y - 2 * arrowScale,
                                      width: 26 * arrowScale, height: 34 * arrowScale)
        }
        let visible = CGRect(x: -originPoint.x / zoom, y: -originPoint.y / zoom,
                             width: available.width / zoom, height: available.height / zoom)
            .intersection(CGRect(origin: .zero, size: size))
        if viewport.visibleRect != visible { viewport.visibleRect = visible }
        // Keep the touch view's center on what's shown, so panning back starts at once.
        if touchMode, visible.width > 0 {
            let shownCenter = CGPoint(x: visible.midX, y: visible.midY)
            if hypot(shownCenter.x - viewport.touchCenter.x, shownCenter.y - viewport.touchCenter.y) > 0.5 {
                viewport.touchCenter = shownCenter
            }
        }
        let keyboardUp = keyboardTop > 0 && keyboardTop < bounds.height - 1
        if viewport.keyboardShown != keyboardUp { viewport.keyboardShown = keyboardUp }
    }

    private var zoom: CGFloat { max(viewport.zoom, 0.01) }

    /// A point in this view as a point on the computer's screen.
    private func desktopPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - desktopOrigin.x) / laidOutZoom, y: (point.y - desktopOrigin.y) / laidOutZoom)
    }

    // MARK: Gestures

    private func addGestures() {
        let move = UIPanGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
        move.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(threeFingers(_:)))
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 3
        // A trackpad's two-finger scroll (it glides) or a mouse wheel's clicks: no touches, only scroll events.
        let trackpadScroll = UIPanGestureRecognizer(target: self, action: #selector(trackpadScroll(_:)))
        trackpadScroll.allowedScrollTypesMask = .continuous
        trackpadScroll.allowedTouchTypes = []
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheel(_:)))
        wheel.allowedScrollTypesMask = .discrete
        wheel.allowedTouchTypes = []
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        rightClick.numberOfTouchesRequired = 2
        let click = UITapGestureRecognizer(target: self, action: #selector(click(_:)))
        click.require(toFail: rightClick)
        // Hold still, then move: drags with the button down (selecting text, moving windows).
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        drag.minimumPressDuration = 0.35
        drag.allowableMovement = 12
        for recognizer in [move, scroll, swipe, pinch, rightClick, click, drag] as [UIGestureRecognizer] {
            recognizer.delegate = self
            // Fingers only: a trackpad or mouse drives the cursor through GCMouse (trackpad mode)
            // or as a pointer (touch mode), and Apple Pencil as a mouse; see the touch handlers.
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(recognizer)
        }
        addGestureRecognizer(trackpadScroll)
        addGestureRecognizer(wheel)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two fingers both scroll and pinch; which one wins is decided by how far they spread.
        let pair = [gestureRecognizer, other]
        return pair.contains { $0 is UIPinchGestureRecognizer }
            && pair.contains { ($0 as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2 }
    }

    /// One finger: the cursor (trackpad) or a scroll (touch).
    @objc private func moveCursor(_ pan: UIPanGestureRecognizer) {
        if touchMode {
            // The content follows the finger, one to one.
            scrollGesture(pan, factor: viewport.scrollSign / laidOutZoom)
            return
        }
        switch pan.state {
        case .began:
            stopFling()
            stopMomentum()
            hideToolbar()
        case .changed:
            let delta = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            let speed = viewport.cursorSpeed
            remote.moveCursor(by: CGPoint(x: delta.x * speed / zoom, y: delta.y * speed / zoom))
        case .ended:
            let velocity = pan.velocity(in: self)
            let speed = viewport.cursorSpeed
            if hypot(velocity.x, velocity.y) > 300 { startFling(CGPoint(x: velocity.x * speed, y: velocity.y * speed)) }
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

    /// Working on the screen puts the toolbar away.
    private func hideToolbar() {
        if !viewport.toolbarHidden { viewport.toolbarHidden = true }
    }

    /// Two fingers: a scroll, or in touch mode on a zoomed-in screen, moving the view.
    @objc private func scroll(_ pan: UIPanGestureRecognizer) {
        if touchMode, viewport.isZoomedIn {
            if pan.state == .began { hideToolbar() }
            guard pan.state == .changed, !pinchActive else {
                pan.setTranslation(.zero, in: self)
                return
            }
            let delta = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            viewport.touchCenter = CGPoint(x: viewport.touchCenter.x - delta.x / laidOutZoom,
                                           y: viewport.touchCenter.y - delta.y / laidOutZoom)
            return
        }
        // The content follows the fingers (unless settings reverse it), at the computer's own scale.
        scrollGesture(pan, factor: 2 * viewport.scrollSign / zoom.squareRoot())
    }

    @objc private func trackpadScroll(_ pan: UIPanGestureRecognizer) {
        scrollGesture(pan, factor: 2 * viewport.scrollSign)
    }

    @objc private func wheel(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .changed else { return }
        let delta = pan.translation(in: self)
        pan.setTranslation(.zero, in: self)
        remote.scroll(dx: delta.x * 2 * viewport.scrollSign, dy: delta.y * 2 * viewport.scrollSign)
    }

    /// A scroll as a trackpad's gesture: began, the moves, ended, then a glide worked out here
    /// (macOS adds momentum below where posted events enter), so apps glide and rubber-band.
    private func scrollGesture(_ pan: UIPanGestureRecognizer, factor: CGFloat) {
        switch pan.state {
        case .began:
            stopMomentum()
            stopFling()
            hideToolbar()
            scrollPinched = false
            pan.setTranslation(.zero, in: self)
            remote.scroll(dx: 0, dy: 0, phase: .began)
        case .changed:
            let delta = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
            if pinchActive {
                scrollPinched = true
                return
            }
            remote.scroll(dx: delta.x * factor, dy: delta.y * factor, phase: .changed)
        case .ended:
            remote.scroll(dx: 0, dy: 0, phase: .ended)
            if !scrollPinched {
                let velocity = pan.velocity(in: self)
                startMomentum(CGPoint(x: velocity.x * factor, y: velocity.y * factor))
            }
        default:
            remote.scroll(dx: 0, dy: 0, phase: .ended)
        }
    }

    /// The glide after the fingers lift: 60 times a second, losing 4% each time (as Sill, after
    /// macOS's own feel), in the computer's pixels a second.
    private func startMomentum(_ velocity: CGPoint) {
        stopMomentum()
        guard hypot(velocity.x, velocity.y) > 150 else { return }
        momentumVelocity = velocity
        momentumStarted = false
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        remote.scroll(dx: momentumVelocity.x * dt, dy: momentumVelocity.y * dt,
                      phase: momentumStarted ? .momentum : .momentumBegan)
        momentumStarted = true
        let decay = pow(0.96, dt * 60)
        momentumVelocity = CGPoint(x: momentumVelocity.x * decay, y: momentumVelocity.y * decay)
        if hypot(momentumVelocity.x, momentumVelocity.y) < 18 { stopMomentum() }
    }

    private func stopMomentum() {
        guard let momentum else { return }
        momentum.invalidate()
        self.momentum = nil
        if momentumStarted { remote.scroll(dx: 0, dy: 0, phase: .momentumEnded) }
        momentumStarted = false
    }

    /// Three fingers swipe as on a Mac's trackpad: up Mission Control, down App Exposé, sideways
    /// the next or previous Space (through the computer's own shortcuts).
    @objc private func threeFingers(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            stopMomentum()
            hideToolbar()
        }
        guard pan.state == .ended else { return }
        let travel = pan.translation(in: self)
        guard max(abs(travel.x), abs(travel.y)) > 50 else { return }
        if abs(travel.y) > abs(travel.x) {
            remote.key(travel.y < 0 ? MacKeyCode.up : MacKeyCode.down, modifiers: [.ctrl])
        } else {
            remote.key(travel.x < 0 ? MacKeyCode.right : MacKeyCode.left, modifiers: [.ctrl])
        }
        if viewport.clickFeedback { haptic.impactOccurred() }
    }

    @objc private func pinch(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            pinchActive = false
            stopMomentum()
            hideToolbar()
        case .changed:
            // Small spreads are a two-finger scroll; past that it's a zoom.
            if !pinchActive, abs(pinch.scale - 1) < 0.08 { return }
            pinchActive = true
            let old = laidOutZoom
            let new = min(max(viewport.zoom * pinch.scale, viewport.fitZoom), viewport.maxZoom)
            if touchMode {
                // The point between the fingers stays under them.
                let location = pinch.location(in: self)
                let pinned = desktopPoint(location)
                let room = CGPoint(x: bounds.midX, y: bounds.midY)
                let centerOffset = CGPoint(x: (room.x - location.x) / new, y: (room.y - location.y) / new)
                if old > 0 { viewport.touchCenter = CGPoint(x: pinned.x + centerOffset.x, y: pinned.y + centerOffset.y) }
            }
            viewport.zoom = new
            pinch.scale = 1
        default: pinchActive = false
        }
    }

    @objc private func click(_ tap: UITapGestureRecognizer) {
        stopFling()
        stopMomentum()
        hideToolbar()
        if touchMode { remote.moveCursor(to: desktopPoint(tap.location(in: self))) }
        remote.click()
        guard viewport.clickFeedback else { return }
        haptic.impactOccurred(intensity: 0.6)
        ripple()
    }

    @objc private func rightClick(_ tap: UITapGestureRecognizer) {
        stopMomentum()
        if touchMode { remote.moveCursor(to: desktopPoint(tap.location(in: self))) }
        remote.click(.right)
        guard viewport.clickFeedback else { return }
        haptic.impactOccurred()
        ripple()
    }

    @objc private func drag(_ press: UILongPressGestureRecognizer) {
        let location = press.location(in: self)
        switch press.state {
        case .began:
            stopFling()
            stopMomentum()
            dragLocation = location
            hideToolbar()
            if touchMode { remote.moveCursor(to: desktopPoint(location)) }
            remote.press(down: true)
            if viewport.clickFeedback { haptic.impactOccurred(intensity: 1) }
        case .changed:
            if touchMode {
                remote.moveCursor(to: desktopPoint(location))
            } else {
                remote.moveCursor(by: CGPoint(x: (location.x - dragLocation.x) / zoom, y: (location.y - dragLocation.y) / zoom))
            }
            dragLocation = location
        default:
            remote.press(down: false)
        }
    }

    // MARK: Pencil and pointer

    /// Apple Pencil hovering, or in touch mode an iPad's pointer: the cursor goes where it points.
    @objc private func hover(_ hover: UIHoverGestureRecognizer) {
        guard hover.state == .began || hover.state == .changed else { return }
        let pencil = hover.zOffset > 0 || hover.altitudeAngle > 0
        guard pencil || touchMode else { return }
        remote.moveCursor(to: desktopPoint(hover.location(in: self)))
    }

    /// Apple Pencil, and in touch mode an iPad's trackpad or mouse clicks, are the computer's
    /// mouse: down where they touch, dragging, up. (Fingers go to the gestures above.)
    private func pointerTouches(_ touches: Set<UITouch>, _ event: UIEvent?) -> UITouch? {
        touches.first { $0.type == .pencil || ($0.type == .indirectPointer && touchMode) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = pointerTouches(touches, event) {
            stopMomentum()
            hideToolbar()
            let button: ScreenRemote.Button = event?.buttonMask.contains(.secondary) == true ? .right : .left
            pointerButton = button
            remote.moveCursor(to: desktopPoint(touch.location(in: self)))
            remote.press(button, down: true)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if pointerButton != nil, let touch = pointerTouches(touches, event) {
            remote.moveCursor(to: desktopPoint(touch.location(in: self)))
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        releasePointer(touches, event)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releasePointer(touches, event)
        super.touchesCancelled(touches, with: event)
    }

    private func releasePointer(_ touches: Set<UITouch>, _ event: UIEvent?) {
        guard let button = pointerButton, pointerTouches(touches, event) != nil else { return }
        pointerButton = nil
        remote.press(button, down: false)
    }

    /// A ring at the cursor, so a click is seen even when the screen doesn't change.
    private func ripple() {
        let ring = CAShapeLayer()
        let tip = cursorTip
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

    private var lastWantsKeyboard = false

    /// The toolbar's keyboard button and the key row's hide button, acted on when they change
    /// (a hardware keyboard keeps the view first responder on its own).
    func apply(wantsKeyboard: Bool) {
        guard wantsKeyboard != lastWantsKeyboard else { return }
        lastWantsKeyboard = wantsKeyboard
        if wantsKeyboard {
            becomeFirstResponder()
            reloadInputViews()
        } else if !hasHardwareKeyboard {
            _ = resignFirstResponder()
        } else {
            reloadInputViews()
        }
    }

    private var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    /// With a keyboard attached the view listens from the start, so typing goes to the Mac.
    @objc private func hardwareKeyboardChanged() {
        guard window != nil, hasHardwareKeyboard, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let code = MacKeyCode.code(forHID: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            // The physical key with its modifiers, like a keyboard plugged into the Mac
            // (its own layout applies there). iPadOS keeps a few for itself: ⌘Tab, ⌘Space, 🌐.
            var modifiers = Set<ScreenRemote.Modifier>()
            if key.modifierFlags.contains(.command) { modifiers.insert(.cmd) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.ctrl) }
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            remote.key(code, modifiers: modifiers.union(viewport.modifiers))
            viewport.modifiers = []
            startRepeat(press, code: code, modifiers: modifiers)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press === repeatingPress { stopRepeat() }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeat()
        super.pressesCancelled(presses, with: event)
    }

    private weak var repeatingPress: UIPress?
    private var repeatTimer: Timer?

    /// A held key repeats, as on the Mac: after half a second, then 25 times a second.
    private func startRepeat(_ press: UIPress, code: Int, modifiers: Set<ScreenRemote.Modifier>) {
        stopRepeat()
        repeatingPress = press
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.remote.key(code, modifiers: modifiers) }
                }
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingPress = nil
    }

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
        // A hardware keyboard has the Mac keys already; the row only shows when asked for.
        if hasHardwareKeyboard, !viewport.wantsKeyboard { return nil }
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

    // MARK: Trackpad and mouse

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func mouseConnected(_ note: Notification) {
        guard let mouse = note.object as? GCMouse else { return }
        attach(mouse)
    }

    /// Raw moves and buttons of an iPad's trackpad or mouse go to the Mac's cursor. While the
    /// controller holds the pointer lock the iPad's own pointer is gone; otherwise it's hidden
    /// over the screen (the pointer interaction below).
    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            Task { @MainActor in self?.mouseMoved(dx: CGFloat(dx), dy: CGFloat(dy)) }
        }
        let buttons: [(GCControllerButtonInput?, ScreenRemote.Button)] = [
            (input.leftButton, .left), (input.rightButton, .right), (input.middleButton, .middle),
        ]
        for (button, name) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                Task { @MainActor in
                    // In touch mode the pointer's clicks come as touches, where it points.
                    guard let self, !self.touchMode else { return }
                    self.remote.press(name, down: pressed)
                }
            }
        }
    }

    private func mouseMoved(dx: CGFloat, dy: CGFloat) {
        guard window != nil, !touchMode else { return }
        stopFling()
        hideToolbar()
        // Raw counts get a little acceleration, like the Mac's own: slow moves stay precise.
        let speed = hypot(dx, dy)
        let gain = (1 + min(speed / 6, 2.5)) * viewport.cursorSpeed
        remote.moveCursor(by: CGPoint(x: dx * gain, y: -dy * gain))
    }

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

/// Keyboard, zoom, a few Mac-only keys and close, in a column; the dock gives it its glass.
private struct ScreenToolbar: View {
    let remote: ScreenRemote
    let viewport: ScreenViewport
    let close: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            button("keyboard", label: "Keyboard") { viewport.wantsKeyboard = true }
            button(viewport.isZoomedIn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   label: viewport.isZoomedIn ? "Whole screen" : "Zoom in") {
                withAnimation(.snappy) { viewport.toggleFit() }
            }
            // Trackpad or touch, for this time; settings choose how it opens.
            button(viewport.inputMode == .touch ? "hand.tap.fill" : "hand.tap",
                   label: viewport.inputMode == .touch ? "Use as a trackpad" : "Touch to click") {
                viewport.inputMode = viewport.inputMode == .touch ? .trackpad : .touch
            }
            if remote.displays.count > 1 || (remote.canAddVirtual && remote.virtualDisplay == nil) {
                ScreenDisplaysMenu(remote: remote, displays: remote.displays, shown: remote.shown)
                    .equatable()
            }
            if remote.virtualDisplay != nil {
                button("macwindow.badge.plus", label: "Bring a window here") { viewport.showsWindows = true }
            }
            ScreenKeysMenu(remote: remote)
                .equatable()
            button("xmark", label: "Close") { close() }
        }
        .padding(6)
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

/// The toolbar on a side of the screen, put away like picture in picture: once the screen is
/// touched the column slides off past the edge and leaves a tab with a chevron. Pulling the tab
/// brings the column out under the finger (let go past halfway and it opens), a tap opens it
/// outright, and the tab drags along the edge, or across to the other one.
private struct ScreenToolbarDock: View {
    let remote: ScreenRemote
    let viewport: ScreenViewport
    @Binding var leading: Bool
    let close: () -> Void
    /// The tab's height on the edge, as a fraction of the screen's.
    @AppStorage(PhonePreferences.screenToolbarPositionKey) private var position = 0.5
    /// A finger on the tab: how far the column is out (0 put away, 1 open) and how far it moved
    /// along the edge. A cancelled drag lets go by itself.
    @GestureState(resetTransaction: Transaction(animation: Self.spring)) private var pull: Pull?
    @State private var columnHeight: CGFloat = 320

    private struct Pull: Equatable {
        var out: CGFloat
        var down: CGFloat
    }

    private static let tab = CGSize(width: 22, height: 76)
    /// The tab's touch area reaches further in than it's drawn.
    private static let tabTouch = CGSize(width: 44, height: 110)
    private static let columnWidth: CGFloat = 60
    private static let margin: CGFloat = 12
    private static let spring = Animation.spring(duration: 0.45, bounce: 0.2)

    var body: some View {
        // The whole screen, edges included; the column keeps out of the safe area's sides itself.
        GeometryReader { safe in
            let insets = safe.safeAreaInsets
            GeometryReader { proxy in
                content(size: proxy.size, insets: insets)
            }
            .ignoresSafeArea()
        }
        .animation(Self.spring, value: viewport.toolbarHidden)
    }

    private func content(size: CGSize, insets: EdgeInsets) -> some View {
        let out = pull?.out ?? (viewport.toolbarHidden ? 0 : 1)
        let y = clamped(position * size.height + (pull?.down ?? 0), half: columnHeight / 2, in: size.height)
        let tabY = clamped(position * size.height + (pull?.down ?? 0), half: Self.tabTouch.height / 2, in: size.height)
        let inset = leading ? insets.leading : insets.trailing
        // From just past the edge to its place beside it.
        let travel = inset + Self.margin + Self.columnWidth + 8
        let edgeX = leading ? 0 : size.width
        let columnX = edgeX + (leading ? 1 : -1) * (out * travel - Self.columnWidth / 2 - 8)
        return ZStack {
            ScreenToolbar(remote: remote, viewport: viewport, close: close)
                .glassEffect(.regular, in: .capsule)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
                .allowsHitTesting(out > 0.99)
                .position(x: columnX, y: y)
            tab(at: CGPoint(x: edgeX, y: tabY), travel: travel, size: size)
                .opacity(max(0, 1 - out * 2.5))
                .allowsHitTesting(out < 0.01 || pull != nil)
        }
        .coordinateSpace(.named("dock"))
    }

    /// Flush with the edge, square against it, a chevron pointing in.
    private func tab(at edge: CGPoint, travel: CGFloat, size: CGSize) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: leading ? 0 : 11, bottomLeadingRadius: leading ? 0 : 11,
            bottomTrailingRadius: leading ? 11 : 0, topTrailingRadius: leading ? 11 : 0)
        return Image(systemName: leading ? "chevron.compact.right" : "chevron.compact.left")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: Self.tab.width, height: Self.tab.height)
            .glassEffect(.regular, in: shape)
            .frame(width: Self.tabTouch.width, height: Self.tabTouch.height, alignment: leading ? .leading : .trailing)
            .contentShape(.rect)
            .position(x: edge.x + (leading ? 1 : -1) * Self.tabTouch.width / 2, y: edge.y)
            .onTapGesture { viewport.toolbarHidden = false }
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("dock"))
                .updating($pull) { drag, pull, _ in
                    let inward = leading ? drag.translation.width : -drag.translation.width
                    pull = Pull(out: min(max(inward / travel, 0), 1), down: drag.translation.height)
                }
                .onEnded { drag in drop(drag, travel: travel, in: size) })
            .accessibilityElement()
            .accessibilityLabel("Show toolbar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { viewport.toolbarHidden = false }
    }

    /// Thrown or pulled past halfway, it opens; carried past the screen's middle, it moves to the
    /// other edge; otherwise it goes back, at the new height.
    private func drop(_ drag: DragGesture.Value, travel: CGFloat, in size: CGSize) {
        let across = leading ? drag.location.x > size.width / 2 : drag.location.x < size.width / 2
        let inward = leading ? drag.predictedEndTranslation.width : -drag.predictedEndTranslation.width
        let y = (position * size.height + drag.translation.height) / max(size.height, 1)
        withAnimation(Self.spring) {
            position = min(max(y, 0), 1)
            if across {
                leading.toggle()
            } else if inward > travel / 2 {
                viewport.toolbarHidden = false
            }
        }
    }

    private func clamped(_ y: CGFloat, half: CGFloat, in height: CGFloat) -> CGFloat {
        min(max(y, half + Self.margin), max(height - half - Self.margin, half + Self.margin))
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
            if remote.sharesClipboard {
                Button("Paste from this \(UIDevice.current.localizedModel)", systemImage: "doc.on.clipboard") { remote.pasteFromDevice() }
            }
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

/// The computer's displays: one of them, all side by side, or one added for this iPad. Equatable
/// on what it lists, so a cursor move doesn't rebuild the menu under the finger (AGENTS.md).
private struct ScreenDisplaysMenu: View, @MainActor Equatable {
    let remote: ScreenRemote
    let displays: [ScreenRemote.Display]
    let shown: ScreenRemote.Shown?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.remote === rhs.remote && lhs.displays == rhs.displays && lhs.shown == rhs.shown
    }

    var body: some View {
        Menu {
            Picker("Display", selection: Binding(get: { shown }, set: { if let target = $0 { remote.show(target) } })) {
                ForEach(displays) { display in
                    Label(display.name, systemImage: display.isVirtual ? "ipad.landscape" : display.isMain ? "menubar.dockrectangle" : "display")
                        .tag(Optional(ScreenRemote.Shown.display(display.id)))
                }
                if displays.count > 1 {
                    Label("All displays", systemImage: "rectangle.split.3x1")
                        .tag(Optional(ScreenRemote.Shown.all))
                }
            }
            .pickerStyle(.inline)
            if UIDevice.current.userInterfaceIdiom == .pad, !displays.contains(where: \.isVirtual) {
                Button("Add a display for this iPad", systemImage: "plus.rectangle.on.rectangle") { remote.show(.virtual) }
            }
        } label: {
            Image(systemName: "display.2")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .contentShape(.rect)
        }
        .accessibilityLabel("Displays")
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

/// The other displays' windows with a small picture of each; a tap moves one onto this iPad's
/// display, and the computer puts it back when the display goes.
private struct ScreenWindowPicker: View {
    let remote: ScreenRemote
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let windows = remote.windows {
                    if windows.isEmpty {
                        ContentUnavailableView("No windows on the other displays", systemImage: "macwindow")
                    } else {
                        list(windows)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Bring a window here")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { remote.listWindows() }
    }

    /// Grouped by display, in the computer's order.
    private func list(_ windows: [ScreenRemote.RemoteWindow]) -> some View {
        let displays = remote.displays.filter { display in windows.contains { $0.display == display.id } }
        return List {
            ForEach(displays) { display in
                Section(display.name) {
                    ForEach(windows.filter { $0.display == display.id }) { window in
                        Button {
                            remote.bringWindow(window)
                            dismiss()
                        } label: {
                            row(window)
                        }
                        .foregroundStyle(Palette.text)
                    }
                }
            }
        }
        .refreshable { remote.listWindows() }
    }

    private func row(_ window: ScreenRemote.RemoteWindow) -> some View {
        HStack(spacing: 14) {
            Group {
                if let picture = remote.windowPictures[window.id] {
                    Image(uiImage: picture).resizable().scaledToFit()
                } else if let icon = remote.windowIcons[window.pid] {
                    Image(uiImage: icon).resizable().scaledToFit().padding(14)
                }
            }
            .frame(width: 112, height: 70)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: 8))
            .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let icon = remote.windowIcons[window.pid] {
                        Image(uiImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(window.app)
                        .font(Typography.sans(13, relativeTo: .footnote))
                        .foregroundStyle(Palette.textMuted)
                }
                Text(window.title.isEmpty ? window.app : window.title)
                    .font(Typography.body)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
