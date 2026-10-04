import SwiftUI

/// A thread: the conversation, what the agent is doing right now, anything it is waiting on,
/// and the composer.
struct ThreadScreen: View {
    let ref: ThreadRef
    @Environment(AppModel.self) private var model

    var body: some View {
        if let environment = model.environment(ref.environmentId) {
            ThreadContent(environment: environment, session: environment.threadSession(ref.threadId))
                .id(ref)
        } else {
            ContentUnavailableView("This Mac isn't connected", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        }
    }
}

private struct ThreadContent: View {
    let environment: EnvironmentSession
    @State var session: ThreadSession
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    /// Programmatic scrolling goes through the reader's proxy: unlike ScrollPosition it
    /// materialises the target row of the lazy stack and lands on it reliably.
    @State private var scrollProxy: ScrollViewProxy?
    /// The end of the conversation is on screen.
    @State private var bottomVisible = true
    /// The view sticks to the newest message: new content, the keyboard and a growing composer
    /// keep it at the bottom. Only the user's own scrolling turns this off (and shows "↓").
    @State private var followsBottom = true
    @State private var scrollPhase = ScrollPhase.idle
    @State private var expandedWork: Set<String> = []
    @State private var expandedRuns: Set<String> = []
    @State private var showSettings = false
    @State private var reviewing: Checkpoint?
    @State private var snoozingCustom = false
    @State private var actionError: String?

    init(environment: EnvironmentSession, session: ThreadSession) {
        self.environment = environment
        _session = State(initialValue: session)
    }

    /// The shell row carries status, plan and pending-request fields the thread projection's
    /// AppThread lacks, so it wins; the projection covers threads the shell no longer lists.
    private var summary: ThreadSummary? { environment.thread(session.threadId) ?? session.projection?.thread }
    private var project: Project? { environment.project(summary?.projectId) }

    var body: some View {
        let projection = session.projection
        let blocks = Timeline.folded(
            Timeline.blocks(from: projection?.rows.map(\.item) ?? [], liveRunId: projection?.activeRun?.id),
            runs: projection?.runs ?? [:],
            activeRunId: projection?.activeRun?.id,
            isWorking: projection?.isWorking ?? false,
            expanded: expandedRuns
        )
        ScrollViewReader { proxy in
        ScrollView {
            // A plain stack: a lazy one guesses the height of rows it hasn't drawn, so "scroll to
            // the newest message" stopped short or left blank rows. Folded turns keep it small.
            VStack(alignment: .leading, spacing: 18) {
                ForEach(blocks) { block in
                    blockView(block, projection: projection)
                        .id(block.id)
                }
                ForEach(session.outbox) { message in
                    OutgoingBubble(message: message, session: session)
                }
                if let projection, projection.isWorking, !blocksEndWithLiveWork(blocks) {
                    ThinkingRow()
                }
                // Visible exactly when the end of the conversation is on screen; also the target
                // of "scroll to bottom" (scrolling to an id materialises the lazy rows, scrolling to
                // the edge can leave them blank until the next touch).
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomId)
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        bottomVisible = visible
                        if visible { followsBottom = true }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .onAppear { scrollProxy = proxy }
        }
        .environment(\.threadEnvironmentId, environment.id)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        // Tapping the conversation puts the keyboard away, also when it is too short to scroll.
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        // Only the user's own scrolling decides whether we stop following the bottom: when their
        // drag (and its deceleration) ends away from the end, "↓" appears.
        .onScrollPhaseChange { old, phase in
            scrollPhase = phase
            if phase == .idle, old == .interacting || old == .decelerating {
                followsBottom = bottomVisible
            }
        }
        .onChange(of: contentSignature(blocks)) {
            if followsBottom { withAnimation(.easeOut(duration: 0.2)) { scrollToBottom() } }
        }
        // Above the composer (the overlay keeps to the safe area the composer inset leaves).
        .overlay(alignment: .bottomTrailing) {
            if !followsBottom, projection != nil {
                Button {
                    followsBottom = true
                    withAnimation { scrollToBottom() }
                    // Lazy rows settle their real heights on the way; land precisely after.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        scrollToBottom()
                    }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("scrollToBottom")
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .overlay {
            if projection == nil {
                if let error = session.loadError {
                    ContentUnavailableView("Couldn't open the thread", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if session.isDeleted {
                    ContentUnavailableView("Thread deleted", systemImage: "trash")
                } else {
                    ProgressView().controlSize(.large)
                }
            } else if blocks.isEmpty, session.outbox.isEmpty, projection?.isWorking == false {
                ContentUnavailableView("Nothing here yet", systemImage: "text.bubble",
                                       description: Text("Write below to give the agent a task."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomStack(projection: projection)
        }
        .background(Palette.canvas)
        .navigationTitle(summary?.displayTitle ?? "")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(projection: projection) }
        .sheet(isPresented: $showSettings) {
            ThreadSettingsSheet(environment: environment, session: session)
        }
        .sheet(item: $reviewing) { checkpoint in
            ChangesSheet(session: session, checkpoint: checkpoint)
        }
        .sheet(isPresented: $snoozingCustom) {
            CustomSnoozeSheet { date in
                try await model.perform(.snooze(date), on: ThreadRef(environmentId: environment.id, threadId: session.threadId))
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .onChange(of: projection != nil, initial: true) { _, loaded in
            guard loaded else { return }
            // The rebuilt scroll view starts at the bottom; one id scroll settles estimated row heights.
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                scrollToBottom()
            }
        }
        // Keep the latest message in view when the keyboard (or the composer) grows.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            if followsBottom { withAnimation(.easeOut(duration: 0.2)) { scrollToBottom() } }
        }
        .onAppear {
            session.markVisited()
            PushService.shared.visibleThread = ThreadRef(environmentId: environment.id, threadId: session.threadId)
        }
        .onDisappear {
            session.markVisited()
            if PushService.shared.visibleThread?.threadId == session.threadId { PushService.shared.visibleThread = nil }
        }
        .onChange(of: session.isDeleted) { _, deleted in if deleted { dismiss() } }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let project { parts.append(project.title) }
        if let branch = summary?.branch { parts.append(branch) }
        if model.environments.count > 1 { parts.append(environment.label) }
        return parts.joined(separator: " · ")
    }

    private func blocksEndWithLiveWork(_ blocks: [TimelineBlock]) -> Bool {
        if case .work(_, _, let isLive)? = blocks.last { return isLive }
        if case .assistant(let item)? = blocks.last { return item.isStreaming }
        return false
    }

    /// Changes whenever the bottom of the timeline grows (new block or streaming text).
    private func contentSignature(_ blocks: [TimelineBlock]) -> String {
        var signature = "\(blocks.count):\(session.outbox.count)"
        switch blocks.last {
        case .assistant(let item): signature += ":\(item.text.count)"
        case .work(_, let items, _): signature += ":\(items.count):\(items.last?.status ?? "")"
        default: break
        }
        return signature
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: TimelineBlock, projection: ThreadProjection?) -> some View {
        switch block {
        case .user(let item):
            UserBubble(item: item, environment: environment)
        case .assistant(let item):
            MarkdownView(text: item.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = item.text
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
        case .work(let id, let items, let isLive):
            WorkGroupView(
                items: items, isLive: isLive,
                isExpanded: Binding(
                    get: { expandedWork.contains(id) },
                    set: { expanded in
                        if expanded { expandedWork.insert(id) } else { expandedWork.remove(id) }
                    }
                )
            )
        case .plan(let item):
            PlanCard(item: item, actionable: summary?.hasActionableProposedPlan == true && item.id == lastPlanId(projection)) {
                implement(plan: item)
            }
        case .todo(let item):
            TodoCard(item: item)
        case .changes(let item):
            ChangesCard(item: item) {
                if let checkpointId = item.raw["checkpointId"]?.string,
                   let checkpoint = projection?.checkpoints[checkpointId]
                {
                    reviewing = checkpoint
                }
            }
        case .error(let item):
            ErrorCard(item: item)
        case .notice(let item):
            NoticeRow(item: item)
        case .fold(let key, let label, let expanded):
            FoldRow(label: label, expanded: expanded) {
                withAnimation(.snappy(duration: 0.25)) {
                    if expanded { expandedRuns.remove(key) } else { expandedRuns.insert(key) }
                }
            }
        }
    }

    private func lastPlanId(_ projection: ThreadProjection?) -> String? {
        projection?.rows.last { $0.item.type == "proposed_plan" }?.item.id
    }

    private func implement(plan item: TurnItem) {
        Task {
            await session.send(
                text: String(localized: "Implement the plan."), attachments: [],
                modelSelection: nil, runtimeMode: nil, interactionMode: "default"
            )
        }
    }

    private static let bottomId = "timeline-bottom"

    private func scrollToBottom() {
        scrollProxy?.scrollTo(Self.bottomId, anchor: .bottom)
    }

    // MARK: Bottom

    @ViewBuilder
    private func bottomStack(projection: ThreadProjection?) -> some View {
        VStack(spacing: 10) {
            if let projection {
                ForEach(projection.pendingRequests) { request in
                    PendingRequestCard(request: request, session: session)
                }
                if !projection.queued.isEmpty {
                    QueueStrip(queued: projection.queued, session: session, canSteer: projection.isWorking,
                               canReorder: projection.activeSession?.supportsQueuedMessages == true)
                }
                if let recovery = summary?.usageLimitRecovery, !projection.isWorking {
                    UsageLimitCard(state: recovery, session: session)
                }
                if projection.isWorking, let run = projection.activeRun, projection.pendingRequests.isEmpty {
                    WorkingPill(since: run.workingSince ?? Date())
                }
            }
            ThreadComposer(environment: environment, session: session) {
                withAnimation { scrollToBottom() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        // A taller composer (more lines, chips, cards) must not hide the newest message.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            if followsBottom { scrollToBottom() }
        }
        .animation(.easeOut(duration: 0.2), value: projection?.pendingRequests.count)
        .animation(.easeOut(duration: 0.2), value: followsBottom)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(projection: ThreadProjection?) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let checkpoint = projection?.latestCheckpointWithChanges {
                    Button {
                        reviewing = checkpoint
                    } label: { Label("Review changes", systemImage: "plusminus") }
                }
                Button {
                    showSettings = true
                } label: { Label("Model and access", systemImage: "slider.horizontal.3") }
                Divider()
                if let summary {
                    if summary.isSettled {
                        Button { perform(.unsettle) } label: { Label("Reopen", systemImage: "tray.and.arrow.up") }
                    } else {
                        Button { perform(.settle) } label: { Label("Settle", systemImage: "checkmark.circle") }
                    }
                    if summary.isSnoozed(), let wake = summary.snoozedUntil {
                        Button { perform(.unsnooze) } label: {
                            Label("Wake now", systemImage: "sun.max")
                            Text("Snoozed until \(Snooze.wakeDescription(until: wake))")
                        }
                    } else {
                        SnoozeMenu { perform(.snooze($0)) } custom: { snoozingCustom = true }
                    }
                    if environment.config?.capability("threadAutoSettleOptOut") == true {
                        Toggle(isOn: Binding(
                            get: { summary.autoSettleDisabledAt == nil },
                            set: { perform(.autoSettle($0)) }
                        )) {
                            Label("Auto-settle", systemImage: "clock.badge.checkmark")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = summary.id
                    } label: { Label("Copy thread ID", systemImage: "number") }
                    Button { perform(.archive, thenDismiss: true) } label: { Label("Archive", systemImage: "archivebox") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Thread actions")
        }
    }

    private func perform(_ action: AppModel.ThreadAction, thenDismiss: Bool = false) {
        let ref = ThreadRef(environmentId: environment.id, threadId: session.threadId)
        Task {
            do {
                try await model.perform(action, on: ref)
                if thenDismiss { dismiss() }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}
