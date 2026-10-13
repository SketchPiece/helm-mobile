import SwiftUI

/// Navigation for the whole app: the thread list is home; threads and New Thread push onto it.
@MainActor
@Observable
final class Router {
    enum Route: Hashable {
        case thread(ThreadRef)
        case newThread
        /// Snoozed or Settled on its own screen, within Home's project filter.
        case shelf(Shelf, projectId: String?)
    }

    enum Shelf: Hashable { case snoozed, settled }

    var path: [Route] = []
    var showSettings = false
    var showPairing = false
    /// The remote for the thread open on a computer nearby (Home's pill, or a thread's menu).
    var showingMacRemote = false
    /// What New Thread should start with (shared text and files), taken by it when it opens.
    var newThreadSeed: SharedContent?
    /// Where New Thread should start, picked by a long press on the New thread button; taken when it opens.
    var newThreadTarget: NewThreadTarget?
    /// New Thread's attachments outlive the screen, so going back keeps them with the draft.
    let newThreadComposer = ComposerDraft()
    /// A thread just started from New Thread, to move on from once the agent is at work.
    var afterStart: AfterStart?
    /// The new-thread draft New Thread shows (`Drafts` key): the last one written or opened.
    var newThreadDraftKey = Drafts.unassignedNewThreadKey

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

    /// New Thread in a given project (or without one); a draft keeps its text and moves there.
    func startNewThread(in target: NewThreadTarget) {
        newThreadTarget = target
        startNewThread()
    }

    /// New Thread on a draft from Home's list (one written here or in Helm on the Mac).
    func resume(_ draft: NewThreadDraft) {
        if draft.key != newThreadDraftKey {
            newThreadDraftKey = draft.key
            newThreadComposer.reset()
        }
        if let environmentId = draft.environmentId, let projectId = draft.projectId {
            newThreadTarget = NewThreadTarget(environmentId: environmentId, projectId: projectId)
        }
        startNewThread()
    }

    /// Lets Home's list catch up after New Thread closes.
    func refreshNewThreadDraft() {
        Drafts.shared.refreshNewThreadList()
    }

    /// Throws a new-thread draft away (New Thread's own by default): text and attachments, on the Mac too.
    func discardNewThreadDraft(_ key: String? = nil) {
        let key = key ?? newThreadDraftKey
        Drafts.shared.clear(key)
        if key == newThreadDraftKey { newThreadComposer.reset() }
    }

    /// The started thread showed the agent at work: on to New Thread in the same project, or Home.
    /// Nothing happens if the user has gone somewhere else meanwhile.
    func finishAfterStart(_ ref: ThreadRef) {
        guard let pending = afterStart, pending.ref == ref else { return }
        afterStart = nil
        guard path.last == .thread(ref) else { return }
        switch pending.behavior {
        case .open: break
        case .another:
            newThreadTarget = pending.target
            // Replacing the thread pushes New Thread, and Back from it goes Home.
            path = [.newThread]
        case .home:
            path = []
        }
    }

    /// Screens pushed inside Settings, for links such as the Usage widget's.
    var settingsPath: [SettingsDestination] = []

    func open(_ ref: ThreadRef) {
        if path.last != .thread(ref) { path = [.thread(ref)] }
    }

    func openShelf(_ shelf: Shelf, projectId: String?) {
        path = [.shelf(shelf, projectId: projectId)]
    }

    /// Opens a thread on top of the current screen (a subagent's thread, a shelf's row), so Back returns.
    func push(_ ref: ThreadRef) {
        if path.last != .thread(ref) { path.append(.thread(ref)) }
    }

    /// Leaves a thread that was deleted, archived or marked unread: back to what was under it.
    /// (`dismiss()` can't do this on iPad, where the thread is the root of the detail column.)
    func close(_ ref: ThreadRef) {
        if path.last == .thread(ref) { path.removeLast() }
    }

    /// The thread open in the detail column on iPad, highlighted in the sidebar.
    var selectedThread: ThreadRef? {
        if case .thread(let ref)? = path.first { return ref }
        return nil
    }
}

enum SettingsDestination: Hashable { case usage }

struct AfterStart: Equatable {
    var ref: ThreadRef
    var behavior: AfterStartBehavior
    var target: NewThreadTarget
}

/// A project to start a thread in; no project id means the Mac's "no project" scratch folder.
struct NewThreadTarget: Equatable {
    var environmentId: String
    var projectId: String?
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()
    @AppStorage(AppBadge.enabledKey) private var appIconBadge = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if model.hasEnvironments && !UserDefaults.standard.bool(forKey: "showWelcome") {
                Group {
                    // By the width the window has, never by device: a narrow iPad window is the iPhone app.
                    if sizeClass == .regular {
                        SplitRoot()
                    } else {
                        NavigationStack(path: $router.path) {
                            HomeView()
                                .navigationDestination(for: Router.Route.self) { RouteView(route: $0) }
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
        // Under the keyboard too: as it slides away the window would show white in the light theme.
        .background { Palette.canvas.ignoresSafeArea() }
        .task { await pairFromLaunchArguments() }
        .onChange(of: AppBadge.count(in: model), initial: true) { _, count in AppBadge.update(count: count) }
        .onChange(of: appIconBadge) { AppBadge.update(count: AppBadge.count(in: model)) }
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

/// The screen a route shows, in the iPhone stack and in the iPad detail column alike.
struct RouteView: View {
    let route: Router.Route

    var body: some View {
        switch route {
        case .thread(let ref): ThreadScreen(ref: ref)
        case .newThread: NewThreadView()
        case .shelf(let shelf, let projectId): ShelfScreen(shelf: shelf, projectId: projectId)
        }
    }
}

/// iPad and other wide windows: Home in the sidebar, the open screen beside it, like Mail.
/// The router's path is the same as on the iPhone; its first route is the detail column's root,
/// the rest is pushed on top of it (a subagent's thread, a shelf's row), so resizing the window
/// between the two layouts keeps what is open.
private struct SplitRoot: View {
    @Environment(Router.self) private var router
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            HomeView()
                .environment(\.isSidebar, true)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
        } detail: {
            NavigationStack(path: detailPath) {
                Group {
                    if let root = router.path.first {
                        RouteView(route: root)
                    } else {
                        nothingOpen
                    }
                }
                // Each opened screen starts fresh, as it does when pushed on the iPhone.
                .id(router.path.first)
                .navigationDestination(for: Router.Route.self) { RouteView(route: $0) }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var detailPath: Binding<[Router.Route]> {
        Binding {
            Array(router.path.dropFirst())
        } set: { tail in
            router.path = Array(router.path.prefix(1)) + tail
        }
    }

    private var nothingOpen: some View {
        ContentUnavailableView {
            Label("No thread open", systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text("Pick a thread on the left, or start a new one.")
        } actions: {
            Button("New thread") { router.startNewThread() }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.accentForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
    }
}

extension EnvironmentValues {
    /// Home is the iPad sidebar: the row of what's open beside it stays highlighted.
    @Entry var isSidebar = false
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
                step(1, String(localized: "Open Helm on your computer."))
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
