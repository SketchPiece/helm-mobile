import SwiftUI

/// Navigation for the whole app: the thread list is home; threads and New Thread push onto it.
@MainActor
@Observable
final class Router {
    enum Route: Hashable {
        case thread(ThreadRef)
        case newThread
    }

    var path: [Route] = []
    var showSettings = false
    var showPairing = false
    /// What New Thread should start with (shared text and files), taken by it when it opens.
    var newThreadSeed: SharedContent?
    /// New Thread's attachments outlive the screen, so going back keeps them with the draft.
    let newThreadComposer = ComposerDraft()
    /// What New Thread was left holding, listed on top of Home.
    private(set) var newThreadDraft = NewThreadDraft.load()

    /// New Thread, right on top of Home; what was left in it is still there.
    func startNewThread() {
        showSettings = false
        if path != [.newThread] { path = [.newThread] }
    }

    /// New Thread, prefilled with `seed` on top of what it already holds.
    func startNewThread(with seed: SharedContent) {
        if !seed.isEmpty {
            var merged = newThreadSeed ?? SharedContent()
            merged.append(seed)
            newThreadSeed = merged
        }
        startNewThread()
    }

    /// Re-reads the new-thread draft after New Thread closes. Attachments alone count as a draft too.
    func refreshNewThreadDraft() {
        newThreadDraft = NewThreadDraft.load(hasAttachments: !newThreadComposer.attachments.isEmpty)
    }

    /// Throws the new-thread draft away: text, project and attachments.
    func discardNewThreadDraft() {
        NewThreadDraft.clear()
        newThreadComposer.reset()
        newThreadDraft = nil
    }

    /// Screens pushed inside Settings, for links such as the Usage widget's.
    var settingsPath: [SettingsDestination] = []

    func open(_ ref: ThreadRef) {
        if path.last != .thread(ref) { path = [.thread(ref)] }
    }

    /// Opens a related thread (a subagent's) on top of the current one, so Back returns.
    func push(_ ref: ThreadRef) {
        if path.last != .thread(ref) { path.append(.thread(ref)) }
    }
}

enum SettingsDestination: Hashable { case usage }

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()

    var body: some View {
        Group {
            if model.hasEnvironments && !UserDefaults.standard.bool(forKey: "showWelcome") {
                NavigationStack(path: $router.path) {
                    HomeView()
                        .navigationDestination(for: Router.Route.self) { route in
                            switch route {
                            case .thread(let ref): ThreadScreen(ref: ref)
                            case .newThread: NewThreadView()
                            }
                        }
                }
                .sheet(isPresented: $router.showSettings, onDismiss: { router.settingsPath = [] }) {
                    SettingsView()
                }
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $router.showPairing) {
            NavigationStack { PairingView() }
        }
        .environment(router)
        .background(Palette.canvas)
        .task { await pairFromLaunchArguments() }
        // Live Activity taps and other links: helm://threads/<env>/<thread>.
        .onOpenURL { url in
            if url.scheme == ShareInbox.openURL.scheme, url.host() == ShareInbox.openURL.host() {
                LaunchActions.shared.pickUpShares()
            } else if let target = HelmLink.thread(from: url) {
                router.open(ThreadRef(environmentId: target.environmentId, threadId: target.threadId))
            } else if url.scheme == "helm", url.host() == "usage" {
                router.settingsPath = [.usage]
                router.showSettings = true
            }
        }
        // Notification taps.
        .onChange(of: PushService.shared.pendingThread) { _, ref in
            guard let ref else { return }
            router.showSettings = false
            router.open(ref)
            PushService.shared.pendingThread = nil
        }
        // Quick action, Shortcuts and shares; held until a Mac is paired.
        .onChange(of: LaunchActions.shared.pendingNewThread) { routeNewThread() }
        .onChange(of: model.hasEnvironments) { routeNewThread() }
        .onAppear(perform: routeNewThread)
    }

    private func routeNewThread() {
        guard model.hasEnvironments, let seed = LaunchActions.shared.pendingNewThread else { return }
        LaunchActions.shared.pendingNewThread = nil
        router.startNewThread(with: seed)
    }

    /// `-pairURL <link>` (or HELM_PAIR_URL) pairs on launch; used by UI tests and simulator runs.
    private func pairFromLaunchArguments() async {
        let defaults = UserDefaults.standard
        guard let link = defaults.string(forKey: "pairURL") ?? ProcessInfo.processInfo.environment["HELM_PAIR_URL"],
              let target = PairingTarget.parse(link: link)
        else { return }
        if ProcessInfo.processInfo.arguments.contains("-resetState") {
            for environment in model.environments { model.remove(environment) }
        }
        guard !model.environments.contains(where: { $0.saved.baseURL == target.baseURL }) else { return }
        _ = try? await model.pair(target)
    }
}

/// First launch: what Helm is and how to connect it.
struct WelcomeView: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HelmMark(size: 88)
            Text("Helm")
                .font(Typography.wordmark)
                .foregroundStyle(Palette.text)
                .padding(.top, 20)
            Text("Your coding agents, from your pocket.")
                .font(Typography.body)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                step(1, String(localized: "Open Helm on your Mac."))
                step(2, String(localized: "Settings → Connections → turn on Network access."))
                step(3, String(localized: "Pair a device, then scan the code or paste the link here."))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: 20))
            .padding(.horizontal, 20)
            Button {
                router.showPairing = true
            } label: {
                Text("Connect to Helm")
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .foregroundStyle(Palette.accentForeground)
            .accessibilityIdentifier("connectToHelm")
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(Typography.mono(13))
                .foregroundStyle(Palette.accentText)
                .frame(width: 18)
            Text(text)
                .font(Typography.subheadline)
                .foregroundStyle(Palette.text)
        }
    }
}

/// The Helm mark: a dark rounded screen with an amber signal trace.
struct HelmMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 120
            let rect = CGRect(origin: .zero, size: canvasSize)
            context.fill(Path(roundedRect: rect, cornerRadius: 26 * scale), with: .color(Color(hex: 0x26211D)))
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: 2 * scale, dy: 2 * scale), cornerRadius: 24 * scale),
                with: .color(Color(hex: 0xEFE7D6).opacity(0.18)), lineWidth: 4 * scale
            )
            var path = Path()
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            path.move(to: p(26, 60))
            path.addQuadCurve(to: p(34, 60), control: p(30, 50))
            path.addQuadCurve(to: p(42, 60), control: p(38, 70))
            path.addQuadCurve(to: p(50, 60), control: p(46, 50))
            path.addQuadCurve(to: p(58, 60), control: p(54, 70))
            path.addLine(to: p(58, 47))
            path.addLine(to: p(70, 47))
            path.addLine(to: p(70, 73))
            path.addLine(to: p(82, 73))
            path.addLine(to: p(82, 60))
            path.addLine(to: p(93, 60))
            context.stroke(path, with: .color(Palette.accent),
                           style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
