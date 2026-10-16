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
            ContentUnavailableView("This computer isn't connected", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        }
    }
}

private struct ThreadContent: View {
    let environment: EnvironmentSession
    @State var session: ThreadSession
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Programmatic scrolling goes through the reader's proxy: unlike ScrollPosition it
    /// materialises the target row of the lazy stack and lands on it reliably.
    @State private var scrollProxy: ScrollViewProxy?
    /// The end of the conversation is on screen.
    @State private var bottomVisible = true
    /// The view sticks to the newest message: new content, the keyboard and a growing composer
    /// keep it at the bottom. Only the user's own scrolling turns this off (and shows "↓").
    @State private var followsBottom = true
    @State private var arrowHeight: CGFloat = 48
    @State private var scrollPhase = ScrollPhase.idle
    /// The user has scrolled this thread themselves; reaching the top then loads older history.
    @State private var userScrolled = false
    /// Only used to shift the offset when an older page lands above what is on screen.
    @State private var position = ScrollPosition()
    /// The latest content offset and height.
    @State private var scrollMetrics = ScrollMetrics()
    /// Offset and height right before an older page was merged; the next height change
    /// moves the offset by the growth so the rows on screen stay put.
    @State private var prependBase: ScrollMetrics?
    /// The first block drawn. A plain stack draws every row it holds, and on a long thread that
    /// made scrolling, and hit-testing for a trackpad most of all, stutter on an older iPad; so it
    /// holds the last `windowPage` blocks and reaching the top shows more (`revealEarlier`).
    @State private var windowStart: WindowStart?
    @State private var revealing = false
    @State private var expandedWork: Set<String> = []
    @State private var expandedRuns: Set<String> = []
    @State private var showSettings = false
    @State private var reviewing: Checkpoint?
    @State private var snoozingCustom = false
    @State private var actionError: String?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false
    /// "Mark as unread" leaves the thread; leaving must not mark it read again.
    @State private var leavesUnread = false
    /// Which rows are on screen, for noticing a blank screen; an object, so it doesn't redraw the thread.
    @State private var watch = BlankWatch()

    init(environment: EnvironmentSession, session: ThreadSession) {
        self.environment = environment
        _session = State(initialValue: session)
    }

    /// The shell row carries status, plan and pending-request fields the thread projection's
    /// AppThread lacks, so it wins; the projection covers threads the shell no longer lists.
    private var summary: ThreadSummary? { environment.thread(session.threadId) ?? session.projection?.thread }
    private var project: Project? { environment.project(summary?.projectId) }
    private var ref: ThreadRef { ThreadRef(environmentId: environment.id, threadId: session.threadId) }

    private func timelineBlocks(_ projection: ThreadProjection?) -> [TimelineBlock] {
        Perf.measure("thread.timeline", units: projection?.rows.count ?? 0) {
            Timeline.folded(
                Timeline.blocks(from: projection?.rows.map(\.item) ?? [], liveRunId: projection?.activeRun?.id),
                runs: projection?.runs ?? [:],
                activeRunId: projection?.activeRun?.id,
                isWorking: projection?.isWorking ?? false,
                expanded: expandedRuns
            )
        }
    }

    struct WindowStart: Equatable {
        var id: String
        var index: Int
        /// Everything, after a page of history arrived from the computer.
        static let all = WindowStart(id: "", index: 0)
    }

    private static let windowPage = 30

    /// Where the drawn part starts: the pinned block, or where it was if that block is gone
    /// (a fold opened, a snapshot replaced the window), or the last page before anything is pinned.
    private func windowStartIndex(_ blocks: [TimelineBlock]) -> Int {
        guard let windowStart else { return max(0, blocks.count - Self.windowPage) }
        if windowStart == .all { return 0 }
        if let index = blocks.firstIndex(where: { $0.id == windowStart.id }) { return index }
        return min(windowStart.index, max(0, blocks.count - 1))
    }

    var body: some View {
        let projection = session.projection
        let blocks = timelineBlocks(projection)
        let startIndex = windowStartIndex(blocks)
        let shown = blocks[startIndex...]
        let latestAnswer = blocks.last { if case .assistant = $0 { true } else { false } }?.id
        ScrollViewReader { proxy in
        ScrollView {
            // Lazy, so rows off screen aren't built or hit-tested: with a plain stack, trackpad
            // scrolling on the iPad stalled hit-testing every drawn message.
            LazyVStack(alignment: .leading, spacing: 18) {
                if let projection, startIndex > 0 || projection.history.hasMore || session.historyError != nil {
                    EarlierHistoryRow(isLoading: session.isLoadingHistory, error: session.historyError,
                                      canLoad: startIndex > 0 || projection.history.hasMore, load: loadEarlier)
                        .onScrollVisibilityChange(threshold: 0.5) { visible in
                            if visible, userScrolled, session.historyError == nil, !Self.manualHistory { loadEarlier() }
                        }
                }
                if let lineage = lineageLink {
                    lineage
                }
                let days = Timeline.dayBreaks(blocks)
                let tailStart = max(shown.startIndex, shown.endIndex - Self.tailCount)
                ForEach(shown[..<tailStart]) { block in
                    if let day = days[block.id] {
                        TimelineDivider(label: day)
                    }
                    blockView(block, projection: projection, latestAnswer: latestAnswer)
                        .onScrollVisibilityChange(threshold: 0.01) { watch.set(block.id, visible: $0) }
                        .id(block.id)
                }
                // The end of the conversation is one row, drawn whole: lazy rows there guessed
                // their heights and were left undrawn after a jump, so opening or sending landed
                // short of the end or on a blank screen until the next touch (on an older iPad).
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(shown[tailStart...]) { block in
                        if let day = days[block.id] {
                            TimelineDivider(label: day)
                        }
                        blockView(block, projection: projection, latestAnswer: latestAnswer)
                            .id(block.id)
                    }
                    ForEach(session.outbox) { message in
                        OutgoingBubble(message: message, session: session)
                    }
                    if let projection, projection.isWorking, !blocksEndWithLiveWork(blocks) {
                        ThinkingRow()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onScrollVisibilityChange(threshold: 0.01) { watch.set(BlankWatch.tail, visible: $0) }
                // Visible exactly when the end of the conversation is on screen. It sits on this row
                // rather than being a row of its own: the lazy stack kept a row after a growing one
                // at its old place, so it showed as visible and scrolling to it went nowhere.
                .overlay(alignment: .bottom) {
                    Color.clear
                        .frame(height: 1)
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            ScrollTrace.bottomVisible(visible)
                            bottomVisible = visible
                            if visible { followsBottom = true }
                        }
                }
                // Room between the last message and the composer. It is part of this row, so
                // scrolling to it lands below the room, not short of it with the room under the composer.
                .padding(.bottom, 16)
                // The target of "scroll to bottom" (scrolling to an id materialises the lazy rows,
                // scrolling to the edge can leave them blank until the next touch).
                .id(Self.bottomId)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .readableColumn()
            // Pins the drawn part to its first block, so new messages grow it at the bottom only.
            .onChange(of: shown.first?.id, initial: true) { _, id in
                if let id { windowStart = WindowStart(id: id, index: startIndex) }
            }
        }
        .onAppear { scrollProxy = proxy }
        }
        .environment(\.threadEnvironmentId, environment.id)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollMetrics.self) {
            // `scrollTo(y:)` counts from the content's top, the offset from the top inset.
            ScrollMetrics(offset: $0.contentOffset.y + $0.contentInsets.top, height: $0.contentSize.height,
                          viewport: $0.containerSize.height, insetTop: $0.contentInsets.top,
                          insetBottom: $0.contentInsets.bottom)
        } action: { old, metrics in
            scrollMetrics = metrics
            if let base = prependBase, metrics.height != base.height {
                prependBase = nil
                ScrollTrace.log("prepend shift", "\(Int(metrics.height - base.height)) pt")
                position.scrollTo(y: base.offset + metrics.height - base.height)
            } else if prependBase == nil, followsBottom, scrollPhase == .idle, metrics.height != old.height {
                // The lazy stack corrects its guessed row heights as rows draw; following the
                // bottom, re-aim, or the view is left short of the end or past it on a blank screen.
                scrollToBottom("height changed")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Tapping the conversation puts the keyboard away, also when it is too short to scroll.
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        // Only the user's own scrolling decides whether we stop following the bottom: when their
        // drag (and its deceleration) ends away from the end, "↓" appears.
        .onScrollPhaseChange { old, phase in
            Perf.scroll("timeline", phase)
            ScrollTrace.phase(old, phase)
            scrollPhase = phase
            if phase == .interacting { userScrolled = true }
            if phase == .idle, old == .interacting || old == .decelerating {
                followsBottom = bottomVisible
            }
            if phase == .idle {
                watch.gapBefore = scrollGap
                checkBlank("scroll ended")
            }
        }
        .onChange(of: contentSignature(blocks)) { old, new in
            ScrollTrace.log("content", "\(old) → \(new)")
            if followsBottom {
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom("content (animated)") }
            } else if blocks.count < watch.blockCount {
                refollowAfterFold(gapBefore: watch.gapBefore)
            }
            // The geometry has already changed by now, so after a fold this is the folded height.
            if blocks.count >= watch.blockCount { watch.gapBefore = scrollGap }
            watch.blockCount = blocks.count
            checkBlank("new content")
        }
        .onChange(of: session.snapshotCount) {
            ThreadLog.record(logPrefix + "snapshot from the computer · " + stateLine())
            checkBlank("snapshot")
        }
        .modifier(ScrollTraceHooks(followsBottom: followsBottom, isWorking: projection?.isWorking == true,
                                   startIndex: startIndex, blockCount: blocks.count))
        // Above the cards over the composer, when there are any (the overlay keeps to the safe
        // area the composer inset leaves). Otherwise it hangs right above the composer itself.
        .overlay(alignment: .bottomTrailing) {
            if !followsBottom, let projection, hasCards(projection) {
                scrollToBottomButton
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        .overlay {
            if projection == nil {
                if let error = session.loadError {
                    ContentUnavailableView("Couldn't open the thread", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if session.isDeleted {
                    ContentUnavailableView("Thread deleted", systemImage: "trash")
                } else if !environment.isLive, session.checkedSavedCopy {
                    ContentUnavailableView("Not saved on this phone", systemImage: "icloud.slash",
                                           description: Text("This thread opens once the computer is reachable."))
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
        // Under the keyboard too: as it slides away the window would show white in the light theme.
        .background { Palette.canvas.ignoresSafeArea() }
        .ignoresHardwareKeyboardBar()
        .navigationTitle(summary?.displayTitle ?? "")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(projection: projection) }
        .sheet(isPresented: $showSettings) {
            ThreadSettingsSheet(environment: environment, session: session)
        }
        // Narrow windows show the changes over the conversation; wide ones beside it (see `review`).
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
        .alert("Rename thread", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { perform(.rename(renameText)) }
        }
        .confirmationDialog("Delete this thread?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { perform(.delete, thenDismiss: true) }
        } message: {
            Text("The conversation and its terminal history are removed from the computer.")
        }
        .onChange(of: projection != nil, initial: true) { _, loaded in
            guard loaded else { return }
            ScrollTrace.log("loaded", "\(blocks.count) blocks")
            // The rebuilt scroll view starts at the bottom; one id scroll settles estimated row heights.
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                scrollToBottom("opened")
                await settleAtBottom("opened")
                checkLanded("opened")
                ThreadLog.record(logPrefix + "opened · " + stateLine())
                checkBlank("opened")
            }
        }
        // Keep the latest message in view when the keyboard (or the composer) grows.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            if followsBottom { withAnimation(.easeOut(duration: 0.2)) { scrollToBottom("keyboard shown (animated)") } }
        }
        .onAppear {
            ScrollTrace.thread(session.threadId, opened: true)
            session.markVisited()
            PushService.shared.visibleThread = ThreadRef(environmentId: environment.id, threadId: session.threadId)
        }
        .onDisappear {
            ScrollTrace.thread(session.threadId, opened: false)
            if !leavesUnread { session.markVisited() }
            if PushService.shared.visibleThread?.threadId == session.threadId { PushService.shared.visibleThread = nil }
        }
        .onChange(of: session.isDeleted) { _, deleted in if deleted { router.close(ref) } }
        .focusedSceneValue(\.openThread, menuActions(projection: projection))
        .task(id: session.projection?.isWorking == true) { await moveOnAfterStart() }
    }

    /// Started from New Thread with "Start another" or "Back to threads": once the agent is seen at work,
    /// on right away, only letting the push into the thread settle. If it hasn't started within a few seconds, stay here.
    private func moveOnAfterStart() async {
        let ref = ThreadRef(environmentId: environment.id, threadId: session.threadId)
        guard router.afterStart?.ref == ref else { return }
        let working = session.projection?.isWorking == true
        try? await Task.sleep(for: working ? .seconds(0.3) : .seconds(10))
        guard !Task.isCancelled else { return }
        if working {
            router.finishAfterStart(ref)
        } else if router.afterStart?.ref == ref {
            router.afterStart = nil
        }
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
    private func blockView(_ block: TimelineBlock, projection: ThreadProjection?, latestAnswer: String?) -> some View {
        switch block {
        case .user(let item):
            UserBubble(item: item, environment: environment)
        case .assistant(let item):
            AssistantMessage(item: item, isLatest: item.id == latestAnswer)
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
            let saveRoot = summary?.worktreePath ?? project?.workspaceRoot
            PlanCard(item: item, actionable: summary?.hasActionableProposedPlan == true && item.id == lastPlanId(projection),
                     saveRoot: saveRoot?.isEmpty == false ? saveRoot : nil,
                     save: { path, contents in
                         guard let saveRoot else { return path }
                         let result = try await environment.call("projects.writeFile", [
                             "cwd": .string(saveRoot), "relativePath": .string(path), "contents": .string(contents),
                         ])
                         return result["relativePath"]?.string ?? path
                     }) {
                implement(plan: item)
            }
        case .todo(let item):
            TodoCard(item: item)
        case .changes(let item):
            ChangesCard(item: item) {
                if let checkpointId = item.raw["checkpointId"]?.string,
                   let checkpoint = projection?.checkpoints[checkpointId]
                {
                    review(checkpoint)
                }
            }
        case .error(let item):
            ErrorCard(item: item)
        case .notice(let item):
            NoticeRow(item: item, threadId: session.threadId)
        case .fold(let key, let label, let expanded):
            FoldRow(label: label, expanded: expanded) {
                withAnimation(.snappy(duration: 0.25)) {
                    if expanded { expandedRuns.remove(key) } else { expandedRuns.insert(key) }
                }
            }
        }
    }

    /// A subagent's or a fork's thread starts with where it came from; tap to go there.
    private var lineageLink: AnyView? {
        guard let summary, let parentId = summary.parentThreadId,
              summary.relationshipToParent == "subagent" || summary.relationshipToParent == "fork" else { return nil }
        let parentTitle = environment.thread(parentId)?.displayTitle
        let isSubagent = summary.relationshipToParent == "subagent"
        return AnyView(
            Button {
                router.push(ThreadRef(environmentId: environment.id, threadId: parentId))
            } label: {
                TimelineDivider(symbol: isSubagent ? "person.2" : "arrow.triangle.branch",
                                label: isSubagent ? String(localized: "Subagent of") : String(localized: "Forked from"),
                                detail: parentTitle ?? String(localized: "the parent thread"), opens: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lineageLink")
        )
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
    /// Blocks at the end drawn as one row, outside the lazy stack's guessing.
    private static let tailCount = 6

    /// UI tests measure a tapped load with `-manualHistory`: reaching the top doesn't load by itself.
    private static let manualHistory: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-manualHistory")
        #else
        false
        #endif
    }()

    private func loadEarlier() {
        guard !session.isLoadingHistory, !revealing else { return }
        let blocks = timelineBlocks(session.projection)
        let start = windowStartIndex(blocks)
        if start > 0 {
            revealEarlier(blocks, from: start)
            return
        }
        Task {
            await session.loadEarlier {
                await waitForRest()
                prependBase = scrollMetrics
                windowStart = .all
            }
        }
    }

    /// Draws the page of blocks above the drawn part; nothing to fetch.
    private func revealEarlier(_ blocks: [TimelineBlock], from start: Int) {
        revealing = true
        Task {
            await waitForRest()
            prependBase = scrollMetrics
            let index = max(0, start - Self.windowPage)
            windowStart = WindowStart(id: blocks[index].id, index: index)
            revealing = false
        }
    }

    /// Land a page once the scroll view is at rest (a fling or the bounce at the top would
    /// override the correction); `prependBase` then shifts the offset by what it adds above.
    private func waitForRest() async {
        for _ in 0..<60 where scrollPhase != .idle { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// `reason` names the caller in the scroll trace.
    private func scrollToBottom(_ reason: String) {
        ScrollTrace.log("scrollToBottom", reason)
        scrollProxy?.scrollTo(Self.bottomId, anchor: .bottom)
    }

    /// The lazy stack guesses the height of rows it hasn't drawn, so a jump to the end lands short
    /// on a long thread (the rows above draw on the way and push the end down). Aim again until the
    /// content height stops changing and the end is on screen: an animated jump across rows the
    /// lazy stack only guessed can stop far up the conversation with the height already settled.
    private func settleAtBottom(_ reason: String) async {
        var height: CGFloat = -1
        for attempt in 0..<12 {
            try? await Task.sleep(for: .milliseconds(150))
            guard followsBottom, scrollPhase != .interacting else {
                ScrollTrace.log("settle stopped", "\(reason) #\(attempt): " + (followsBottom ? "user dragging" : "not following"))
                return
            }
            if scrollMetrics.height == height, bottomVisible {
                ScrollTrace.log("settle done", "\(reason) #\(attempt)")
                return
            }
            height = scrollMetrics.height
            scrollToBottom("settle \(reason) #\(attempt)")
        }
        ScrollTrace.log("settle gave up", reason)
        ScrollTrace.caught("kept aiming at the end after \(reason) and gave up")
    }

    /// A finished turn folds its work into one row. With the view a little short of the end the
    /// rows moved under it and it was left far up in rows the lazy stack only guessed, often blank:
    /// back to the end, where the answer is. Further up, it is only noted, to see how often.
    private func refollowAfterFold(gapBefore: CGFloat) {
        guard gapBefore < scrollMetrics.viewport else {
            ScrollTrace.caught("a turn folded while the view was \(Int(gapBefore)) pt short of the end")
            ThreadLog.record(logPrefix + "folded while \(Int(gapBefore)) pt short of the end · " + stateLine())
            return
        }
        ScrollTrace.log("folded near the end", "\(Int(gapBefore)) pt short; back to the end")
        followsBottom = true
        scrollToBottom("folded near the end")
        Task {
            await settleAtBottom("folded")
            checkLanded("folded")
        }
    }

    /// After a jump to the end has settled: is the end on screen? Logged and saved if not.
    private func checkLanded(_ reason: String) {
        guard followsBottom, scrollPhase == .idle, session.projection != nil else { return }
        let gap = scrollGap
        guard !bottomVisible || abs(gap) > 4 else { return }
        let what = "\(reason) ended " + (gap >= 0 ? "\(Int(gap)) pt short of" : "\(Int(-gap)) pt past") + " the end"
            + (bottomVisible ? "" : ", end not on screen")
        ThreadLog.record(logPrefix + what + " · " + stateLine())
        ScrollTrace.caught(what)
    }

    /// How far short of the end the view is; negative is past it. The container height leaves out
    /// both insets, and at the end the content's bottom sits at the bottom inset's top edge.
    private var scrollGap: CGFloat { scrollMetrics.gap }

    // MARK: Blank screen

    /// Why nothing of the conversation is on screen although it has blocks, or nil. The lazy stack
    /// has left the screen blank until the next touch: offset past its content, or rows not drawn.
    private func blankReason() -> String? {
        guard session.projection != nil, scrollPhase == .idle, scrollMetrics.viewport > 0 else { return nil }
        let blocks = timelineBlocks(session.projection)
        guard !blocks.isEmpty else { return nil }
        let metrics = scrollMetrics
        let raw = metrics.offset - metrics.insetTop
        if raw > metrics.height || raw + metrics.viewport + metrics.insetTop + metrics.insetBottom < 0 {
            return "scrolled off the content"
        }
        if watch.onScreen(of: shownIds(blocks)) == 0 { return "no row on screen" }
        return nil
    }

    private func shownIds(_ blocks: [TimelineBlock]) -> Set<String> {
        Set(blocks[windowStartIndex(blocks)...].map(\.id)).union([BlankWatch.tail])
    }

    /// A moment after `reason` (once things settle), if the screen is blank: log it and go back to
    /// the end, nudging the offset if aiming alone doesn't bring the rows back.
    private func checkBlank(_ reason: String) {
        guard !watch.healing else { return }
        watch.pending?.cancel()
        watch.pending = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, !watch.healing else { return }
            guard let why = blankReason() else {
                // At rest and following the end, the end has to be on screen.
                if followsBottom, scrollPhase == .idle, session.projection != nil, !bottomVisible {
                    let what = "following the end after \(reason), but it isn't on screen"
                    ThreadLog.record(logPrefix + what + " · " + stateLine())
                    ScrollTrace.caught(what)
                    scrollToBottom("end not on screen")
                }
                return
            }
            watch.healing = true
            defer { watch.healing = false }
            ThreadLog.record(logPrefix + "BLANK after \(reason): \(why) · " + stateLine())
            ScrollTrace.caught("blank screen after \(reason): \(why)")
            followsBottom = true
            scrollToBottom("blank")
            await settleAtBottom("blank")
            if blankReason() != nil {
                position.scrollTo(y: max(0, scrollMetrics.offset - 1))
                try? await Task.sleep(for: .milliseconds(100))
                scrollToBottom("blank, nudged")
                try? await Task.sleep(for: .milliseconds(500))
            }
            ThreadLog.record(logPrefix + (blankReason().map { "  still blank: \($0)" } ?? "  rows back") + " · " + stateLine())
        }
    }

    private var logPrefix: String {
        "\(session.threadId.prefix(8)) \(String((summary?.displayTitle ?? "").prefix(40))) · "
    }

    /// The scroll view's state for the thread log.
    private func stateLine() -> String {
        let blocks = timelineBlocks(session.projection)
        let metrics = scrollMetrics
        let raw = metrics.offset - metrics.insetTop
        let gap = scrollGap
        return "\(blocks.count) blocks from #\(windowStartIndex(blocks)), rows on screen \(watch.onScreen(of: shownIds(blocks)))"
            + ", end \(bottomVisible ? "✓" : "✗"), follows \(followsBottom ? "✓" : "✗")"
            + String(format: ", offset %.0f, height %.0f, view %.0f, gap %.0f", raw, metrics.height, metrics.viewport, gap)
            + (session.savedAt == nil ? ", live" : ", saved copy") + (environment.isLive ? "" : ", offline")
    }

    // MARK: Bottom

    /// Full-width cards between the timeline and the composer.
    private func hasCards(_ projection: ThreadProjection) -> Bool {
        !projection.pendingRequests.isEmpty || !projection.queued.isEmpty
            || (summary?.usageLimitRecovery != nil && !projection.isWorking)
            || (!projection.isWorking && !(summary?.backgroundTasks.isEmpty ?? true))
    }

    private var scrollToBottomButton: some View {
        Button {
            ScrollTrace.log("↓ tapped")
            followsBottom = true
            withAnimation { scrollToBottom("↓ (animated)") }
            Task {
                await settleAtBottom("↓")
                checkLanded("↓")
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityIdentifier("scrollToBottom")
        .transition(.opacity)
    }

    @ViewBuilder
    private func bottomStack(projection: ThreadProjection?) -> some View {
        VStack(spacing: 10) {
            if projection != nil, !environment.isLive {
                SavedCopyNotice(status: environment.status, savedAt: session.savedAt)
            }
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
                // Offline, the saved copy can't say whether the turn is still running; the
                // connection notice stands in for the pill until the Mac answers again.
                if environment.isLive, projection.isWorking, let run = projection.activeRun,
                   projection.pendingRequests.isEmpty {
                    WorkingPill(since: run.workingSince ?? Date())
                }
                if !projection.isWorking, let summary, !summary.backgroundTasks.isEmpty {
                    BackgroundWorkBanner(tasks: summary.backgroundTasks, environmentId: environment.id) {
                        try await session.stopBackgroundWork(latestRunId: summary.latestRunId)
                    }
                }
            }
            ThreadComposer(environment: environment, session: session) {
                ScrollTrace.log("send", "working \(projection?.isWorking == true ? "yes" : "no"), outbox \(session.outbox.count), rows \(projection?.rows.count ?? 0)")
                // Sending means "show me the end", also when the conversation was scrolled up.
                followsBottom = true
                withAnimation { scrollToBottom("send (animated)") }
                // The bubble lands right after and the composer shrinks back as its text clears.
                Task {
                    await settleAtBottom("send")
                    checkLanded("send")
                }
            }
            // Beside a working or offline pill (they sit in the middle), 8 pt above the composer.
            .overlay(alignment: .topTrailing) {
                if !followsBottom, let projection, !hasCards(projection) {
                    scrollToBottomButton
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { arrowHeight = $0 }
                        .offset(y: -(arrowHeight + 8))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .readableColumn()
        // A taller composer (more lines, chips, cards) must not hide the newest message.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
            ScrollTrace.log("bottom stack", "\(Int(old)) → \(Int(new)) pt")
            if followsBottom { scrollToBottom("bottom stack height") }
        }
        .animation(.easeOut(duration: 0.2), value: projection?.pendingRequests.count)
        .animation(.easeOut(duration: 0.2), value: summary?.backgroundTasks)
        .animation(.easeOut(duration: 0.2), value: followsBottom)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(projection: ThreadProjection?) -> some ToolbarContent {
        // Wide windows have room to show the changes beside the thread, so they get their own button.
        if sizeClass == .regular, let checkpoint = projection?.latestCheckpointWithChanges {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    review(checkpoint, toggle: true)
                } label: {
                    Image(systemName: "plusminus")
                }
                .accessibilityLabel("Review changes")
                .accessibilityIdentifier("reviewChanges")
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        if let usage = projection?.contextUsage {
            ToolbarItem(placement: .topBarTrailing) {
                ContextMeter(used: usage.used, max: usage.max,
                             compactBlockedReason: compactBlockedReason(projection),
                             compact: canCompact ? { compact() } : nil)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if model.macRemoteTarget()?.ref == ThreadRef(environmentId: environment.id, threadId: session.threadId) {
                    // The computer shows this very thread: the remote for it, not "open it there".
                    Button {
                        router.showingMacRemote = true
                    } label: { Label("Open the remote", systemImage: "appletvremote.gen4") }
                    Divider()
                } else if NearbyMacs.shared.contains(environment.id) {
                    OpenOnComputerButton(environment: environment, threadId: session.threadId)
                    Divider()
                }
                if let checkpoint = projection?.latestCheckpointWithChanges {
                    Button {
                        review(checkpoint)
                    } label: { Label("Review changes", systemImage: "plusminus") }
                }
                Button {
                    showSettings = true
                } label: { Label("Thread settings", systemImage: "slider.horizontal.3") }
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
                    if summary.pinnedAt == nil {
                        Button { perform(.pin) } label: { Label("Pin", systemImage: "pin") }
                    } else {
                        Button { perform(.unpin) } label: { Label("Unpin", systemImage: "pin.slash") }
                    }
                    Button {
                        leavesUnread = true
                        perform(.markUnread, thenDismiss: true)
                    } label: { Label("Mark as unread", systemImage: "circlebadge") }
                    Divider()
                    Button {
                        renameText = summary.title
                        renaming = true
                    } label: { Label("Rename", systemImage: "pencil") }
                    Button { perform(.regenerateTitle) } label: { Label("Regenerate title", systemImage: "sparkles") }
                    Button {
                        UIPasteboard.general.string = summary.id
                    } label: { Label("Copy thread ID", systemImage: "number") }
                    Divider()
                    Button { perform(.archive, thenDismiss: true) } label: { Label("Archive", systemImage: "archivebox") }
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Thread actions")
        }
    }

    /// A turn's changes: in the inspector beside the thread when the window is wide (it lives
    /// outside the navigation stack, which would otherwise lose its toolbar), else in a sheet.
    private func review(_ checkpoint: Checkpoint, toggle: Bool = false) {
        guard sizeClass == .regular else {
            reviewing = checkpoint
            return
        }
        if toggle, router.reviewing?.ref == ref {
            router.reviewing = nil
        } else {
            router.reviewing = ChangesReview(ref: ref, checkpoint: checkpoint)
        }
    }

    /// What the menu bar's Thread menu does here.
    private func menuActions(projection: ThreadProjection?) -> OpenThreadActions {
        let checkpoint = projection?.latestCheckpointWithChanges
        return OpenThreadActions(
            isWorking: projection?.isWorking == true,
            hasChanges: checkpoint != nil,
            isReviewing: router.reviewing?.ref == ref,
            isSettled: summary?.isSettled == true,
            isPinned: summary?.pinnedAt != nil,
            stop: { Task { try? await session.interrupt() } },
            toggleReview: { if let checkpoint { review(checkpoint, toggle: true) } },
            perform: { perform($0) },
            markUnread: {
                leavesUnread = true
                perform(.markUnread, thenDismiss: true)
            }
        )
    }

    /// The thread's provider offers `/compact`.
    private var canCompact: Bool {
        guard let instanceId = summary?.modelSelection?.instanceId,
              let provider = environment.config?.provider(instanceId) else { return false }
        return provider.slashCommands(cwd: summary?.worktreePath ?? project?.workspaceRoot).contains { $0.name == "compact" }
    }

    private func compactBlockedReason(_ projection: ThreadProjection?) -> String? {
        if !environment.isLive { return String(localized: "The computer is offline.") }
        if projection?.isWorking == true { return String(localized: "Wait for the agent to finish its turn.") }
        if projection?.pendingRequests.isEmpty == false { return String(localized: "Answer the agent first.") }
        return nil
    }

    /// Compaction is a message of its own, like on the desktop; the draft stays in the composer.
    private func compact() {
        Task {
            await session.send(text: "/compact", attachments: [], modelSelection: nil, runtimeMode: nil, interactionMode: nil)
        }
    }

    private func perform(_ action: AppModel.ThreadAction, thenDismiss: Bool = false) {
        let ref = ThreadRef(environmentId: environment.id, threadId: session.threadId)
        Task {
            do {
                try await model.perform(action, on: ref)
                // A delete may already have closed the screen when the stream reported it.
                if thenDismiss, !session.isDeleted { router.close(ref) }
            } catch {
                leavesUnread = false
                actionError = error.localizedDescription
            }
        }
    }
}

/// Above the oldest loaded message of a long thread: loads the previous page (also on its own
/// when the user scrolls up to it), or says why it couldn't.
private struct EarlierHistoryRow: View {
    let isLoading: Bool
    let error: String?
    let canLoad: Bool
    let load: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if canLoad {
                Button(action: load) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: error == nil ? "chevron.up" : "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(isLoading ? String(localized: "Loading earlier messages…")
                             : error == nil ? String(localized: "Load earlier messages") : String(localized: "Try again"))
                            .font(Typography.footnote.weight(.medium))
                    }
                    .foregroundStyle(Palette.textMuted)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Palette.surface, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityIdentifier("loadEarlier")
            }
            if let error {
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Above the composer while the Mac is out of reach: the timeline is the copy saved on this phone.
private struct SavedCopyNotice: View {
    let status: EnvironmentSession.Status
    let savedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            if status == .connecting {
                ProgressView().controlSize(.mini)
                Text("Connecting…")
            } else {
                Image(systemName: status == .unauthorized ? "key.slash" : "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                if status == .unauthorized { Text("Pair again") } else { Text("Offline") }
            }
            if let savedAt {
                Text(verbatim: "·")
                Text("As of \(savedAt.asOfDescription)")
            }
        }
        .font(Typography.footnote.weight(.medium))
        .foregroundStyle(Palette.textMuted)
        .padding(.horizontal, 14)
        .frame(minHeight: 30)
        .background(Palette.surface, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// What the scroll trace (Settings → Performance) watches besides the calls in the thread itself.
private struct ScrollTraceHooks: ViewModifier {
    let followsBottom: Bool
    let isWorking: Bool
    let startIndex: Int
    let blockCount: Int

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                ScrollTrace.geometry(geometry)
            }
            .onChange(of: followsBottom) { ScrollTrace.followsBottom(followsBottom) }
            .onChange(of: isWorking) { ScrollTrace.log("working", isWorking ? "yes" : "no") }
            .onChange(of: startIndex) { old, new in ScrollTrace.log("window start", "\(old) → \(new) of \(blockCount)") }
    }
}

/// Where the thread's scroll view is: content offset (from the content's top) and content height,
/// the scroll view's height and its insets.
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var viewport: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0

    /// How far short of the end the view is; negative is past it.
    var gap: CGFloat { height - viewport - offset }
}

/// The thread's rows on screen and its pending blank-screen check.
@MainActor
private final class BlankWatch {
    static let tail = "timeline-tail"
    private var visible: Set<String> = []
    var pending: Task<Void, Never>?
    var healing = false
    /// Blocks at the last content change, and how far short of the end the view was then.
    var blockCount = 0
    var gapBefore: CGFloat = 0

    func set(_ id: String, visible isVisible: Bool) {
        if isVisible { visible.insert(id) } else { visible.remove(id) }
    }

    /// Rows still in the timeline that are on screen (a replaced row never reports leaving).
    func onScreen(of ids: Set<String>) -> Int { visible.intersection(ids).count }
}
