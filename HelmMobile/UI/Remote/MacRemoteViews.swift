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
        voice.begin()
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
            // Edge to edge with the bottom bar's glass (Search and New thread) under it.
            .padding(.horizontal, 28)
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
    @State private var choosingScreenshot = false
    @State private var snoozingCustom = false
    /// The thread list under the title is open.
    @State private var listingThreads = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let target = remote.target, let thread = remote.thread {
                header(target: target, thread: thread)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 12) {
                        nowCard(thread: thread)
                        if let session = remote.session, let projection = session.projection {
                            ForEach(projection.pendingRequests) { request in
                                PendingRequestCard(request: request, session: session)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    pageDots
                }
                .scrollBounceBehavior(.basedOnSize)
                // Sideways: the thread before or after this one, as on Home; the computer follows.
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { drag in
                    let x = drag.translation.width
                    guard abs(x) > 60, abs(x) > abs(drag.translation.height) * 1.5,
                          let ref = remote.neighbour(x < 0 ? 1 : -1, in: model)
                    else { return }
                    Task { await remote.switchTo(ref, in: model) }
                })
                .id(target.ref)
                .transition(.opacity)
                threadActions
                controls
                    }
                    if listingThreads { threadList }
                }
            } else {
                ContentUnavailableView("Nobody at the computer", systemImage: "desktopcomputer",
                                       description: Text("Open a thread in Helm on your computer to use the remote."))
            }
        }
        .background(Palette.canvas)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $choosingScreenshot) {
            ScreenshotPanel(remote: remote)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $snoozingCustom) {
            CustomSnoozeSheet { date in await remote.settle(.snooze(date), in: model) }
        }
        .animation(.snappy(duration: 0.25), value: remote.target)
        .undoToast()
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
                voiceTargetMenu
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
            }
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
        return ZStack(alignment: .top) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy(duration: 0.25)) { listingThreads = false } }
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
            .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
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
                Text("Swipe for the next thread").font(Typography.footnote).foregroundStyle(Palette.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .animation(.snappy(duration: 0.25), value: index)
        }
    }

    /// Settle and Snooze, by the thumb. When another thread needs you, the remote goes on to it.
    private var threadActions: some View {
        let next = remote.nextWaiting(in: model)
        return VStack(alignment: .leading, spacing: 8) {
            if let next {
                Text("Next: \(next.thread.displayTitle)")
                    .font(Typography.mono(12))
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            HStack(spacing: 10) {
                let settled = remote.thread?.isSettled == true
                Button {
                    Task { await remote.settle(settled ? .unsettle : .settle, in: model) }
                } label: {
                    Label(settled ? "Reopen" : "Settle", systemImage: settled ? "tray.and.arrow.up" : "checkmark")
                        .font(Typography.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
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
                        .font(Typography.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glass)
            }
            .foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
    }

    /// Where the words go: sent as a message, or typed into the composer on the computer.
    private var voiceTargetMenu: some View {
        Menu {
            Picker("Voice", selection: Binding(get: { remote.voiceTarget }, set: { remote.voiceTarget = $0 })) {
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
        } label: {
            HStack(spacing: 5) {
                Image(systemName: remote.voiceTarget == .send ? "arrow.up" : "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                Text(remote.voiceTarget == .send ? "Voice sends" : "Voice types")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(Typography.footnote)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.surface, in: .capsule)
            .overlay(Capsule().stroke(Palette.border))
        }
        .accessibilityLabel("Where your voice goes")
    }

    /// The agent's latest words, a few lines of them: enough to know where it is.
    @ViewBuilder
    private func nowCard(thread: ThreadSummary) -> some View {
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
                        .lineLimit(5)
                }
                if let error = remote.sendError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: .rect(cornerRadius: 18))
        }
    }

    private var hint: LocalizedStringKey {
        let typing = remote.voiceTarget == .composer
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
                    Text("The screenshot goes with what you say")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 0)
                    Button {
                        remote.pendingScreenshot = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 28, height: 28)
                    }
                    .foregroundStyle(Palette.textMuted)
                    .accessibilityLabel("Remove the screenshot")
                }
                .padding(8)
                .background(Palette.surface, in: .rect(cornerRadius: 14))
                .padding(.horizontal, 24)
            }
            if remote.isSending, remote.voice.state == .idle {
                Text("Sending to the computer…").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                    .frame(height: 32)
            } else {
                RemoteVoiceStatus(remote: remote)
                    .frame(height: 32)
                    .padding(.horizontal, 24)
            }
            HStack {
                Button {
                    Task { await remote.stop() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .foregroundStyle(remote.isWorking ? Palette.errorText : Palette.textMuted)
                        .background(Palette.surface, in: .circle)
                        .overlay(Circle().stroke(Palette.border))
                }
                .disabled(!remote.isWorking)
                .accessibilityLabel("Stop the agent")
                Spacer()
                RemoteMicButton(remote: remote, diameter: 112)
                    .background(Circle().fill(Palette.accent.opacity(0.1)).padding(-12))
                Spacer()
                Button {
                    choosingScreenshot = true
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 58, height: 58)
                        .foregroundStyle(Palette.text)
                        .background(Palette.surface, in: .circle)
                        .overlay(Circle().stroke(Palette.border))
                }
                .accessibilityLabel("Send a screenshot")
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
