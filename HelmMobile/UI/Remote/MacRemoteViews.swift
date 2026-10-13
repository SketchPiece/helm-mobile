import PhotosUI
import SwiftUI

/// The remote's microphone. Recording starts at touch-down. Hold, then let go: sent to the thread
/// on the Mac (slide left first to drop it). Tap: keeps recording hands-free until the next tap,
/// which sends.
struct RemoteMicButton: View {
    let remote: MacRemote
    var diameter: CGFloat = 44

    @State private var pressedAt: Date?
    @State private var holding = false
    /// The press landed on a hands-free recording: lifting it sends.
    @State private var endsHandsFree = false
    @State private var dragOffset: CGFloat = 0

    private var voice: VoiceInput { remote.voice }

    var body: some View {
        let recording = voice.isRecording
        let cancelling = holding && dragOffset < MicButton.cancelThreshold
        ZStack {
            Circle().fill(recording ? Palette.error : Palette.accent)
            if voice.state == .transcribing {
                ProgressView().tint(Palette.accentForeground)
            } else {
                Image(systemName: cancelling ? "xmark" : voice.state == .recording(handsFree: true) ? "arrow.up" : "mic.fill")
                    .contentTransition(.opacity)
                    .font(.system(size: diameter * 0.38, weight: .semibold))
                    .foregroundStyle(recording ? .white : Palette.accentForeground)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(holding ? 1.08 : pressedAt != nil ? 0.92 : 1)
        .animation(.easeOut(duration: 0.15), value: holding)
        .animation(.easeOut(duration: 0.1), value: pressedAt != nil)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: cancelling)
        .sensoryFeedback(.impact(weight: .light), trigger: cancelling)
        .sensoryFeedback(.success, trigger: remote.sentCount)
        .contentShape(.circle)
        .gesture(MicPressGesture(
            onBegan: press,
            onMoved: { dragOffset = min(0, $0) },
            onEnded: { cancelledBySystem in release(tapped: !cancelledBySystem) }
        ))
        .onDisappear {
            if pressedAt != nil { release(tapped: false) }
        }
        .accessibilityLabel(voice.state == .recording(handsFree: true) ? "Send to the computer" : "Talk to the computer")
        .accessibilityHint("Hold to talk, release to send")
    }

    private func press() {
        guard pressedAt == nil, voice.state != .transcribing else { return }
        pressedAt = Date()
        if voice.state == .recording(handsFree: true) {
            endsHandsFree = true
            return
        }
        if case .failed = voice.state { voice.dismissError() }
        remote.beginDictation()
        let started = pressedAt
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if pressedAt == started, pressedAt != nil {
                holding = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    private func release(tapped: Bool) {
        guard pressedAt != nil else { return }
        let wasHolding = holding
        let cancelled = dragOffset < MicButton.cancelThreshold
        pressedAt = nil
        holding = false
        dragOffset = 0
        if endsHandsFree {
            endsHandsFree = false
            Task { await remote.finishAndSend() }
        } else if wasHolding {
            if cancelled { voice.cancel() } else { Task { await remote.finishAndSend() } }
        } else if tapped {
            voice.keepHandsFree()
        } else {
            voice.cancel()
        }
    }
}

/// One line on what the thread is doing: the phase with its colour, and how long it has worked.
struct RemoteStatusLine: View {
    let thread: ThreadSummary

    var body: some View {
        let phase = thread.phase
        if phase != .idle { line(phase) }
    }

    private func line(_ phase: ThreadPhase) -> some View {
        HStack(spacing: 6) {
            Circle().fill(phase.color).frame(width: 7, height: 7)
            if phase == .working, let since = thread.activityRunStartedAt {
                Text("Working")
                Text(since, style: .timer).monospacedDigit()
            } else if let label = phase.label {
                Text(label)
            }
        }
        .font(Typography.mono(12))
        .foregroundStyle(phase.color)
        .lineLimit(1)
    }
}

/// Above Home's bottom bar while Helm on a Mac nearby has a thread open: what it is, how it's
/// going, and a microphone that talks straight into it. Tapping the rest opens the remote.
struct MacRemotePill: View {
    let remote: MacRemote
    /// Edge to edge with the bottom bar's glass on the phone; the iPad sidebar has no bar.
    var horizontalPadding: CGFloat = 28
    let onOpen: () -> Void

    var body: some View {
        if let target = remote.target, let thread = remote.thread {
            HStack(spacing: 12) {
                Group {
                    switch remote.voice.state {
                    case .recording, .transcribing, .failed:
                        RemoteVoiceStatus(remote: remote)
                    case .idle:
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Palette.text)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.displayTitle)
                                    .font(Typography.subheadline.weight(.medium))
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    RemoteStatusLine(thread: thread)
                                    Text(thread.phase == .idle ? target.macLabel : "· \(target.macLabel)")
                                        .font(Typography.mono(12))
                                        .foregroundStyle(Palette.textMuted)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture(perform: onOpen)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens the remote for the thread on your computer")
                RemoteMicButton(remote: remote, diameter: 40)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 52)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// What the microphone is doing, in the pill or the remote: the take's length and levels, then
/// "Sending…", or why it failed.
struct RemoteVoiceStatus: View {
    let remote: MacRemote

    var body: some View {
        HStack(spacing: 10) {
            switch remote.voice.state {
            case .recording(let handsFree):
                Circle().fill(Palette.error).frame(width: 8, height: 8)
                if let startedAt = remote.voice.startedAt {
                    Text(startedAt, style: .timer)
                        .font(Typography.mono(14))
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                }
                LevelBars(levels: remote.voice.levels)
                if handsFree {
                    Button {
                        remote.voice.cancel()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    }
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityLabel("Cancel dictation")
                }
            case .transcribing:
                Text("Sending to the computer…").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.errorText)
                Text(message).font(Typography.footnote).foregroundStyle(Palette.text).lineLimit(2)
                Spacer(minLength: 0)
                Button("Retry") { Task { await remote.retryTranscription() } }
                    .font(Typography.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accentText)
            case .idle:
                EmptyView()
            }
        }
    }
}

/// The remote itself: the thread on the Mac at a glance, what the agent asks, and the big
/// microphone with Stop beside it. The Mac shows the whole thread; this is for the hand.
struct MacRemoteSheet: View {
    let remote: MacRemote
    let onOpenThread: (ThreadRef) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The picture button's three ways in: the camera, screenshots only, or every photo.
    @State private var takingPhoto = false
    @State private var pickingFrom: PHPickerFilter?
    @State private var pickedItem: PhotosPickerItem?
    /// A picture is on the clipboard (checked without reading it, so no paste prompt until used).
    @State private var clipboardHasImage = UIPasteboard.general.hasImages
    @State private var snoozingCustom = false
    /// The thread list under the title is open.
    @State private var listingThreads = false
    /// Where the thread list drops from: right under the header.
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let target = remote.target, let thread = remote.thread {
                header(target: target, thread: thread)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                // What the agent asks, as tall as it needs (scrolling past ~half the screen).
                if let session = remote.session, let requests = session.projection?.pendingRequests, !requests.isEmpty {
                    ViewThatFits(in: .vertical) {
                        requestCards(requests, session: session)
                        ScrollView { requestCards(requests, session: session) }
                            .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(maxHeight: 380, alignment: .top)
                }
                // The chat itself fills the middle, and dragging it scrolls the chat on the
                // computer; Settle and Snooze sit at its foot, this thread's place among the others under it.
                pad(thread: thread)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .id(target.ref)
                    .transition(.opacity)
                pageDots
                    .padding(.top, 10)
                controls
            } else {
                ContentUnavailableView("Nobody at the computer", systemImage: "desktopcomputer",
                                       description: Text("Open a thread in Helm on your computer to use the remote."))
            }
        }
        .overlay(alignment: .top) {
            if listingThreads {
                // No dimming: the list floats on its shadow, and a tap anywhere else puts it away.
                ZStack(alignment: .top) {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.snappy(duration: 0.25)) { listingThreads = false } }
                    threadList
                        .padding(.top, headerHeight)
                }
            }
        }
        .background(Palette.canvas)
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in remote.pendingScreenshot = image }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: Binding(get: { pickingFrom != nil }, set: { if !$0 { pickingFrom = nil } }),
                      selection: $pickedItem, matching: pickingFrom ?? .images)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            clipboardHasImage = UIPasteboard.general.hasImages
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    remote.pendingScreenshot = image
                }
            }
        }
        .sheet(isPresented: $snoozingCustom) {
            CustomSnoozeSheet { date in await remote.settle(.snooze(date), in: model) }
        }
        .animation(.snappy(duration: 0.25), value: remote.target)
        .undoToast()
    }

    private func requestCards(_ requests: [PendingRequest], session: ThreadSession) -> some View {
        VStack(spacing: 12) {
            ForEach(requests) { request in
                PendingRequestCard(request: request, session: session)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    /// One card: the end of the chat, bottom-up and fading out at the top, sunk into a dotted pad
    /// that drives the chat on the computer, with Settle and Snooze along its foot.
    private func pad(thread: ThreadSummary) -> some View {
        VStack(spacing: 0) {
            RemoteTrackpad(remote: remote) { step in
                guard let ref = remote.neighbour(step, in: model) else { return }
                Task { await remote.switchTo(ref, in: model) }
            } content: {
                VStack(spacing: 0) {
                    // The words never size the card: they hang from its bottom in whatever room
                    // the header and the controls leave, and older words are cut off at the top.
                    Color.clear
                        .overlay(alignment: .bottomLeading) {
                            chatTail(thread: thread)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                        }
                        .clipped()
                        .mask {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 30)
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 72)
                                Color.black
                            }
                        }
                        .background { PadGrain() }
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 6) {
                                Circle().fill(Palette.done).frame(width: 6, height: 6)
                                Text("ON THE COMPUTER", comment: "Over the chat on the remote: what it shows is the chat on the computer")
                            }
                            .font(Typography.mono(10.5))
                            .foregroundStyle(Palette.textMuted)
                            .padding(12)
                            .accessibilityHidden(true)
                        }
                        // Sunk below the card, the way a trackpad sits in the case.
                        .background {
                            RoundedRectangle(cornerRadius: 13)
                                .fill(Palette.canvas.shadow(.inner(color: .black.opacity(0.16), radius: 2, y: 1)))
                        }
                        .clipShape(.rect(cornerRadius: 13))
                        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.text.opacity(0.07)) }
                        .padding([.horizontal, .top], 10)
                    padFooter
                }
            }
            // A new thread can't be settled or snoozed until it is sent.
            if !remote.isDraft {
                Rectangle().fill(Palette.border).frame(height: 1)
                threadActions
            }
        }
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: 20))
    }

    /// Under the words: the next thread Settle leads to, or how to use the pad.
    @ViewBuilder
    private var padFooter: some View {
        Group {
            if let next = remote.nextWaiting(in: model) {
                Text("Next: \(next.thread.displayTitle)")
                    .font(Typography.mono(12))
                    .lineLimit(1)
            } else {
                Label("Drag to scroll the computer · double tap for the latest", systemImage: "arrow.up.and.down")
                    .labelStyle(.tight)
                    .font(Typography.caption)
            }
        }
        .foregroundStyle(Palette.textMuted)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func header(target: MacRemoteTarget, thread: ThreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(Palette.done).frame(width: 7, height: 7)
                Text("\(target.macLabel.uppercased()) · NEARBY", comment: "The computer's name in capitals, on the same network as the phone")
                    .font(Typography.mono(12))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                Spacer()
                if let environment = remote.environment, environment.config?.capability("screenRemote") == true {
                    Button {
                        ScreenRemotePresenter.present(environment)
                    } label: {
                        Image(systemName: "display")
                            .font(.system(size: 17))
                            .foregroundStyle(Palette.text)
                    }
                    .accessibilityLabel("Control the computer")
                    .padding(.trailing, 6)
                }
                if !remote.isDraft {
                    Button {
                        dismiss()
                        onOpenThread(target.ref)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 18))
                            .foregroundStyle(Palette.text)
                    }
                    .accessibilityLabel("Open the thread on this phone")
                }
            }
            threadMenu(current: thread)
            HStack(spacing: 8) {
                ProjectIcon(project: remote.environment?.project(thread.projectId), environment: remote.environment, size: 18)
                Text(remote.environment?.project(thread.projectId)?.title ?? target.macLabel)
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                if thread.phase != .idle {
                    Text(verbatim: "·").foregroundStyle(Palette.textMuted)
                    RemoteStatusLine(thread: thread)
                }
                Spacer(minLength: 8)
                if remote.isWorking { stopButton }
            }
            .frame(minHeight: 30)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    /// The title; tapping it lists every thread on this computer under it.
    private func threadMenu(current thread: ThreadSummary) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { listingThreads.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(thread.displayTitle)
                    .font(Typography.sans(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
                    .rotationEffect(.degrees(listingThreads ? 180 : 0))
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Lists the threads on this computer")
    }

    /// Every thread on this computer, as on Home: what needs you first, then the rest. The one the
    /// computer shows is lit; picking another opens it there.
    private var threadList: some View {
        let lists = remote.threads(in: model)
        return Group {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !lists.waiting.isEmpty {
                        listHeader("Needs you")
                        ForEach(lists.waiting) { threadRow($0) }
                    }
                    if !lists.others.isEmpty {
                        listHeader("Active")
                        ForEach(lists.others) { threadRow($0) }
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.border))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }

    private func listHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .textCase(.uppercase)
            .font(Typography.sectionHeader)
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func threadRow(_ entry: ThreadListEntry) -> some View {
        let current = entry.ref == remote.target?.ref
        let phase = entry.thread.phase
        return Button {
            withAnimation(.snappy(duration: 0.25)) { listingThreads = false }
            Task { await remote.switchTo(entry.ref, in: model) }
        } label: {
            HStack(spacing: 12) {
                ProjectIcon(project: entry.project, environment: remote.environment, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.thread.displayTitle)
                        .font(Typography.subheadline.weight(.medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Text(entry.project?.title ?? entry.environmentLabel)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if current {
                    Label("On the computer", systemImage: "desktopcomputer")
                        .labelStyle(.tight)
                        .font(Typography.mono(12))
                        .foregroundStyle(Palette.accentText)
                } else if let label = phase.label {
                    Text(label)
                        .font(Typography.mono(12))
                        .foregroundStyle(phase.color)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(current ? Palette.accent.opacity(0.1) : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Where this thread sits among the others, under the card: the swipe's map.
    @ViewBuilder
    private var pageDots: some View {
        let lists = remote.threads(in: model)
        let all = (lists.waiting + lists.others).map(\.ref)
        if all.count > 1, let index = all.firstIndex(where: { $0 == remote.target?.ref }) {
            VStack(spacing: 6) {
                if all.count <= 9 {
                    HStack(spacing: 6) {
                        ForEach(all.indices, id: \.self) { i in
                            Capsule()
                                .fill(i == index ? Palette.text : Palette.border)
                                .frame(width: i == index ? 16 : 6, height: 6)
                        }
                    }
                } else {
                    Text("\(index + 1) of \(all.count)").font(Typography.mono(12)).foregroundStyle(Palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: index)
        }
    }

    /// Settle and Snooze, a quiet strip along the pad's foot. When another thread needs you, the
    /// remote goes on to it.
    private var threadActions: some View {
        HStack(spacing: 0) {
            let settled = remote.thread?.isSettled == true
            Button {
                Task { await remote.settle(settled ? .unsettle : .settle, in: model) }
            } label: {
                Label(settled ? "Reopen" : "Settle", systemImage: settled ? "tray.and.arrow.up" : "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(.rect)
            }
            Rectangle().fill(Palette.border).frame(width: 1, height: 26)
            Menu {
                ForEach(Snooze.presets()) { preset in
                    Button {
                        Task { await remote.settle(.snooze(preset.date), in: model) }
                    } label: {
                        Text(preset.title)
                        Text(preset.whenLabel)
                    }
                }
                Button("Custom…") { snoozingCustom = true }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .font(Typography.subheadline.weight(.medium))
        .foregroundStyle(Palette.text)
    }

    /// Next to the run it stops, only while there is one.
    private var stopButton: some View {
        Button {
            Task { await remote.stop() }
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .labelStyle(.tight)
                .font(Typography.footnote.weight(.medium))
                .foregroundStyle(Palette.errorText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.surface, in: .capsule)
                .overlay(Capsule().stroke(Palette.border))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel("Stop the agent")
    }

    /// The end of the chat as the computer shows it: earlier turns' words, your last message, the
    /// steps of the turn since, and the agent's reply. Older turns fill the room a short reply leaves.
    @ViewBuilder
    private func chatTail(thread: ThreadSummary) -> some View {
        let tail = Self.tail(of: remote.session?.projection?.rows.map(\.item) ?? [])
        if remote.isDraft {
            VStack(alignment: .leading, spacing: 8) {
                Text("A new thread, not sent yet. What you say and the pictures you add go into its composer on the computer, for you to send there.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textMuted)
                if let error = remote.sendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if tail.items.isEmpty {
            latest(thread: thread)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(tail.items) { item in
                    tailRow(item, earlier: item.ordinal < tail.lastAsk)
                }
                if let error = remote.sendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Messages from the whole chat, steps only from the turn since your last message, and of
    /// those the last few: more could never show above the reply anyway.
    private static func tail(of items: [TurnItem]) -> (items: [TurnItem], lastAsk: Int) {
        let lastAsk = items.last { $0.type == "user_message" }?.ordinal ?? .min
        var steps = 0
        var kept: [TurnItem] = []
        for item in items.reversed() where item.parentItemId == nil {
            switch item.type {
            case "user_message", "assistant_message":
                if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { kept.append(item) }
            case "reasoning", "thread_created", _ where Timeline.noticeTypes.contains(item.type):
                continue
            default:
                guard item.ordinal > lastAsk, steps < 3, !(item.title ?? "").isEmpty else { continue }
                steps += 1
                kept.append(item)
            }
            if kept.count == 16 { break }
        }
        return (kept.reversed(), lastAsk)
    }

    @ViewBuilder
    private func tailRow(_ item: TurnItem, earlier: Bool) -> some View {
        let words = (try? AttributedString(markdown: item.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.text)
        switch item.type {
        case "user_message":
            Text(words)
                .font(Typography.subheadline)
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Palette.message, in: .rect(cornerRadii: .init(topLeading: 16, bottomLeading: 16, bottomTrailing: 4, topTrailing: 16)))
                .padding(.leading, 48)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case "assistant_message":
            Text(words)
                .font(Typography.subheadline)
                .foregroundStyle(earlier ? Palette.textMuted : Palette.text)
        default:
            HStack(spacing: 8) {
                if item.isRunning {
                    Circle().fill(Palette.working).frame(width: 7, height: 7)
                } else {
                    Image(systemName: item.status == "failed" ? "xmark" : "checkmark").font(.system(size: 10, weight: .semibold))
                }
                Text(item.title ?? "").lineLimit(1)
            }
            .font(Typography.mono(12.5))
            .foregroundStyle(item.isRunning ? Palette.working : Palette.textMuted)
        }
    }

    /// The agent's latest words and what it is running, for a thread whose chat isn't loaded yet.
    @ViewBuilder
    private func latest(thread: ThreadSummary) -> some View {
        let running = remote.session?.projection?.items.values
            .filter { $0.isRunning && !($0.title ?? "").isEmpty }
            .max { $0.ordinal < $1.ordinal }
        let latest = thread.latestMessageText?.isEmpty == false ? thread.latestMessageText : remote.session?.projection?.items.values
            .filter { $0.type == "assistant_message" && !$0.text.isEmpty }
            .max { $0.ordinal < $1.ordinal }?.text
        if running != nil || latest != nil || remote.sendError != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let running, let title = running.title {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.working).frame(width: 7, height: 7)
                        Text(title).lineLimit(1)
                    }
                    .font(Typography.mono(13))
                    .foregroundStyle(Palette.working)
                }
                if let text = latest {
                    // Inline markdown only: a glance, not the thread.
                    Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                        .font(Typography.subheadline)
                        .foregroundStyle(thread.latestMessageRole == "user" ? Palette.textMuted : Palette.text)
                }
                if let error = remote.sendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }
            .padding(.top, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hint: LocalizedStringKey {
        let typing = remote.typesIntoComposer
        if remote.canSendComposer {
            return "Hold to talk and add to it · the arrow sends it"
        }
        if remote.voice.state == .recording(handsFree: true) {
            return typing ? "Tap to type it on the computer" : "Tap to send"
        }
        return typing ? "Hold to talk · let go to type it on the computer" : "Hold to talk · let go to send"
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let screenshot = remote.pendingScreenshot {
                // Kept for what is said next.
                HStack(spacing: 10) {
                    Image(uiImage: screenshot)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 44)
                        .clipShape(.rect(cornerRadius: 5))
                    Text(remote.typesIntoComposer ? "Add it now, or say something to go with it" : "Send it now, or say something to go with it")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Button {
                        remote.pendingScreenshot = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityLabel("Remove the picture")
                    Button {
                        Task { await remote.sendScreenshot(screenshot) }
                    } label: {
                        Image(systemName: remote.typesIntoComposer ? "plus" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(Palette.accentForeground)
                            .background(Palette.accent, in: .circle)
                    }
                    .disabled(remote.isSending)
                    .accessibilityLabel(remote.typesIntoComposer ? "Add the picture on the computer" : "Send the picture")
                }
                .padding(8)
                .background(Palette.surface, in: .rect(cornerRadius: 14))
                .padding(.horizontal, 24)
            }
            if remote.isSending, remote.voice.state == .idle {
                Text(remote.typesIntoComposer ? "Adding it on the computer…" : "Sending to the computer…").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                    .frame(height: 32)
            } else {
                RemoteVoiceStatus(remote: remote)
                    .frame(height: 32)
                    .padding(.horizontal, 24)
            }
            HStack {
                RemoteLeftControl(
                    canSend: remote.canSendComposer,
                    isDraft: remote.isDraft,
                    typesIntoComposer: remote.typesIntoComposer,
                    voiceTarget: remote.voiceTarget,
                    onSend: { Task { await remote.sendComposer() } },
                    onPick: { remote.voiceTarget = $0 }
                )
                .equatable()
                .animation(.snappy(duration: 0.25), value: remote.canSendComposer)
                Spacer()
                RemoteMicButton(remote: remote, diameter: 112)
                    .background(Circle().fill(Palette.accent.opacity(0.1)).padding(-12))
                Spacer()
                Menu {
                    if clipboardHasImage {
                        Button {
                            if let image = UIPasteboard.general.image { remote.pendingScreenshot = image }
                        } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    }
                    if CameraPicker.isAvailable {
                        Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
                    }
                    Button { pickingFrom = .screenshots } label: { Label("Screenshots", systemImage: "camera.viewfinder") }
                    Button { pickingFrom = .images } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 58, height: 58)
                        .foregroundStyle(Palette.text)
                        .background(Palette.surface, in: .circle)
                        .overlay(Circle().stroke(Palette.border))
                }
                .accessibilityLabel("Add a picture")
            }
            .padding(.horizontal, 34)
            Text(hint)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textMuted)
        }
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

/// Beside the remote's microphone: where the words go, or, once the computer's composer holds
/// something, Send for it (a long press still picks where the words go). Its own view, equal on
/// what it shows, so the thread's updates don't rebuild the menu under the finger.
private struct RemoteLeftControl: View, @MainActor Equatable {
    let canSend: Bool
    let isDraft: Bool
    let typesIntoComposer: Bool
    let voiceTarget: MacRemote.VoiceTarget
    let onSend: () -> Void
    let onPick: (MacRemote.VoiceTarget) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.canSend, lhs.isDraft, lhs.typesIntoComposer, lhs.voiceTarget)
            == (rhs.canSend, rhs.isDraft, rhs.typesIntoComposer, rhs.voiceTarget)
    }

    var body: some View {
        if canSend {
            Group {
                // A new thread has nothing else to send to: the button only sends.
                if isDraft {
                    Button(action: onSend) { sendLabel }
                } else {
                    Menu { picker } label: { sendLabel } primaryAction: { onSend() }
                        .accessibilityHint("Hold to choose where your voice goes")
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send what's in the computer's composer")
            .transition(.scale.combined(with: .opacity))
        } else {
            Menu { picker } label: {
                Image(systemName: typesIntoComposer ? "keyboard" : "arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 58, height: 58)
                    .foregroundStyle(Palette.text)
                    .background(Palette.surface, in: .circle)
                    .overlay(Circle().stroke(Palette.border))
            }
            // A new thread has nothing to send to yet: the voice types into it.
            .disabled(isDraft)
            .accessibilityLabel("Where your voice goes")
            .accessibilityValue(typesIntoComposer ? "Voice types" : "Voice sends")
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var sendLabel: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 22, weight: .bold))
            .frame(width: 58, height: 58)
            .foregroundStyle(Palette.accentForeground)
            .background(Palette.accent, in: .circle)
    }

    /// Where the words go: sent as a message, or typed into the composer on the computer.
    private var picker: some View {
        Picker("Voice", selection: Binding(get: { voiceTarget }, set: { onPick($0) })) {
            Label {
                Text("Send right away")
                Text("As a new message")
            } icon: {
                Image(systemName: "arrow.up")
            }
            .tag(MacRemote.VoiceTarget.send)
            Label {
                Text("Type on the computer")
                Text("Into its composer, you send")
            } icon: {
                Image(systemName: "keyboard")
            }
            .tag(MacRemote.VoiceTarget.composer)
        }
    }
}

/// "Open on <computer>": shows the thread in Helm on that computer and brings it forward. Only
/// offered while the computer is on the same network, for the thread menu and Home's long press.
struct OpenOnComputerButton: View {
    let environment: EnvironmentSession
    let threadId: String

    var body: some View {
        if environment.isLive, NearbyMacs.shared.contains(environment.id) {
            Button {
                Task {
                    let opened = (try? await environment.sendRemoteCommand([
                        "type": "thread.open", "threadId": .string(threadId),
                    ])) ?? false
                    UINotificationFeedbackGenerator().notificationOccurred(opened ? .success : .error)
                }
            } label: {
                Label("Open on \(environment.label)", systemImage: "desktopcomputer")
            }
        }
    }
}

/// The matte dots of the remote's pad: dense on top where older turns fade out, thin under the
/// newest words so the reply reads clean.
private struct PadGrain: View {
    var body: some View {
        Canvas { context, size in
            let dot = context.resolve(GraphicsContext.Shading.color(Palette.text.opacity(0.16)))
            for y in stride(from: 3.0, to: size.height, by: 7) {
                for x in stride(from: 3.0, to: size.width, by: 7) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: dot)
                }
            }
        }
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.35), location: 0.55),
                                   .init(color: .black.opacity(0.25), location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The middle of the remote, under what it shows: drag up and down to scroll the chat on the
/// computer (finger up, newer messages, as on the phone), fling to glide, double tap for the
/// latest. Sideways goes to the thread before or after.
struct RemoteTrackpad<Content: View>: View {
    let remote: MacRemote
    let onSwipe: (_ step: Int) -> Void
    @ViewBuilder let content: Content

    private enum Axis { case vertical, horizontal }
    @State private var axis: Axis?
    @State private var lastY: CGFloat = 0
    /// Pixels on the computer per point on the phone.
    private var gain: Double { 2.5 }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A touch of shade while a drag scrolls the computer.
            .background(Palette.text.opacity(axis == .vertical ? 0.04 : 0))
            .animation(.easeOut(duration: 0.2), value: axis)
            .contentShape(.rect)
            .onTapGesture(count: 2) { remote.scrollComputerToEnd() }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { drag in
                        if axis == nil {
                            axis = abs(drag.translation.width) > abs(drag.translation.height) ? .horizontal : .vertical
                            lastY = 0
                        }
                        guard axis == .vertical else { return }
                        let dy = drag.translation.height - lastY
                        lastY = drag.translation.height
                        remote.scrollComputer(by: -Double(dy) * gain)
                    }
                    .onEnded { drag in
                        defer { axis = nil }
                        switch axis {
                        case .horizontal:
                            // Right goes on to the next thread (the lit dot moves right), left goes back.
                            if abs(drag.translation.width) > 60 { onSwipe(drag.translation.width > 0 ? 1 : -1) }
                        case .vertical:
                            let carry = drag.predictedEndTranslation.height - drag.translation.height
                            if abs(carry) > 40 { remote.flingComputer(by: -Double(carry) * gain) }
                        case nil:
                            break
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Scroll up on the computer") { remote.flingComputer(by: -600) }
            .accessibilityAction(named: "Scroll down on the computer") { remote.flingComputer(by: 600) }
            .accessibilityAction(named: "Jump to the latest") { remote.scrollComputerToEnd() }
    }
}
