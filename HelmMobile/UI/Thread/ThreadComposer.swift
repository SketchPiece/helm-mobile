import SwiftUI

/// The composer: a narrow glass pill at rest that opens into a two-row card (text on top; attach,
/// model, access mode and the amber action below) while you write. While the agent works, an empty composer's button
/// stops it; with text, the message queues or steers per Settings → Follow-ups (long-press for
/// the other one).
/// Typing `/`, `@`, `$` or `#` opens suggestions above it.
struct ThreadComposer: View {
    let environment: EnvironmentSession
    let session: ThreadSession
    var didSend: () -> Void = {}

    @State private var text: String
    @State private var draft = ComposerDraft()
    @State private var suggestions = ComposerSuggestions()
    @State private var showSettings = false
    @State private var stopping = false
    @State private var voice = VoiceInput()
    @State private var micDrag: CGFloat = 0
    @State private var focused = false
    /// Lets the attach button and the trailing buttons fly between the two rows as the card opens.
    @Namespace private var shape
    @AppStorage(PhonePreferences.followUpKey) private var followUpBehavior = FollowUpBehavior.queue
    @AppStorage(PhonePreferences.returnKeyKey) private var returnKey = ReturnKeyBehavior.standard

    init(environment: EnvironmentSession, session: ThreadSession, didSend: @escaping () -> Void = {}) {
        self.environment = environment
        self.session = session
        self.didSend = didSend
        _text = State(initialValue: Drafts.shared.text(for: session.threadId))
    }

    private var thread: ThreadSummary? { environment.thread(session.threadId) ?? session.projection?.thread }
    private var isWorking: Bool { session.projection?.isWorking ?? thread?.isWorking ?? false }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty || draft.hasUploaded || draft.isUploading }
    private var canSend: Bool {
        (!trimmed.isEmpty || draft.hasUploaded) && !draft.isUploading && environment.isLive
    }

    var body: some View {
        VStack(spacing: 8) {
            if focused && suggestions.isVisible {
                SuggestionPanel(suggestions: suggestions, onPick: pick)
                    .transition(.opacity)
            }
            pill
        }
        .animation(.easeOut(duration: 0.15), value: focused && suggestions.isVisible)
        .sheet(isPresented: $showSettings) {
            ThreadSettingsSheet(environment: environment, session: session)
        }
        .onAppear {
            voice.warmUp()
            draft.restore(Drafts.shared.files(for: session.threadId))
        }
        // Written or sent in Helm on the Mac meanwhile.
        .onChange(of: Drafts.shared.remoteRevision(session.threadId)) {
            text = Drafts.shared.text(for: session.threadId)
            draft.restore(Drafts.shared.files(for: session.threadId))
        }
        .onChange(of: draft.draftFiles) { saveDraft() }
        .onDisappear { if voice.isRecording { voice.cancel() } }
    }

    /// Opens into the two-row card while there is something to edit; at rest it is one narrow row.
    private var expanded: Bool {
        focused || !trimmed.isEmpty || !draft.attachments.isEmpty || draft.notice != nil
    }

    private var pill: some View {
        // Spacing is per row: a folded text view must not leave a gap above the recording.
        VStack(alignment: .leading, spacing: 0) {
            if !draft.attachments.isEmpty || draft.notice != nil {
                AttachmentStrip(draft: draft, environment: environment)
                    .padding(.bottom, 4)
            }
            // The text view keeps its place in this row in both shapes, so it never loses focus.
            // One centred row at rest; opened, the last line of text lines up with the bottom.
            HStack(alignment: expanded ? .bottom : .center, spacing: 6) {
                // At rest the recording fades in over the attach button and the empty field rather
                // than pushing them aside, so nothing slides across it. Nothing is focused at rest,
                // so hiding the text view this way can't drop the keyboard.
                HStack(alignment: expanded ? .bottom : .center, spacing: 6) {
                    if !expanded { movingAttach }
                    // Opened, the text view folds away while dictating rather than leaving the window,
                    // so the keyboard stays up. With a draft, the draft stays in view above the strip.
                    editor.padding(.leading, expanded ? 6 : 0)
                        .voiceCollapsed(editorFolded)
                }
                .opacity(dictatingAtRest ? 0 : 1)
                .overlay {
                    if dictatingAtRest { voiceStrip.transition(.opacity) }
                }
                if !expanded { movingTrailing }
            }
            if expanded {
                // The controls row: attach, model and mode, or the recording while dictating. The amber
                // slot stays put either way, so a held microphone doesn't move under the finger.
                HStack(spacing: 6) {
                    if dictating {
                        voiceStrip
                    } else {
                        movingAttach
                        settingsChips.layoutPriority(1)
                        Spacer(minLength: 0)
                    }
                    movingTrailing
                }
                .padding(.top, editorFolded ? 0 : 4)
                .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .onBackgroundTap { if voice.state == .idle { focused = true } }
        // Live glass at rest, to play with; opened, the menus in it get the taps instead.
        .composerGlass(cornerRadius: expanded ? 26 : 25, interactive: !expanded)
        .composerImageDrop(cornerRadius: expanded ? 26 : 25) { images in
            images.forEach { draft.attach(image: $0, environment: environment) }
        }
        // At rest the pill floats inset from the edges and stretches out to them when it opens.
        .padding(.horizontal, expanded ? 0 : 14)
        .animation(.composer, value: expanded)
        .animation(.composer, value: voice.state)
        .animation(.composer, value: hasContent)
        .animation(.composer, value: isWorking)
    }

    private var dictating: Bool { voice.state != .idle }
    private var dictatingAtRest: Bool { dictating && !expanded }
    /// In the opened card the text view folds away while dictating, unless there is a draft to show.
    private var editorFolded: Bool { dictating && expanded && trimmed.isEmpty }

    private var voiceStrip: some View {
        VoiceStrip(voice: voice, dragOffset: micDrag, onCancel: { voice.cancel(); voice.dismissError() },
                   onRetry: retryDictation)
    }

    private var movingAttach: some View {
        attachMenu.matchedGeometryEffect(id: "attach", in: shape)
    }

    private var movingTrailing: some View {
        HStack(spacing: 6) { trailingButtons }
            .matchedGeometryEffect(id: "trailing", in: shape)
    }

    private var attachMenu: some View {
        AttachMenu(draft: draft, environment: environment, size: 34) {
            if let pasted = draft.paste(environment: environment, draftLength: text.utf16.count) {
                text += pasted
            }
            focused = true
        }
    }

    private var editor: some View {
        ComposerTextView(text: $text, isFocused: $focused, placeholder: placeholder,
                         accessibilityIdentifier: "composer", returnKey: returnKey,
                         onSubmit: { alternate in
                             send(followUp: alternate ? followUpBehavior.other.followUp : followUpBehavior.followUp)
                         }) { images in
            images.forEach { draft.attach(image: $0, environment: environment) }
        }
            .padding(.vertical, 7)
            .onChange(of: text) { old, value in
                if let folded = draft.foldPaste(old: old, new: value, environment: environment) {
                    text = folded
                    return
                }
                saveDraft()
                suggestions.update(text: value, scope: suggestionScope)
            }
    }

    private var suggestionScope: ComposerSuggestions.Scope {
        let project = environment.project(thread?.projectId)
        return ComposerSuggestions.Scope(
            environment: environment, providerInstanceId: thread?.modelSelection?.instanceId,
            cwd: thread?.worktreePath ?? project?.workspaceRoot, projectId: thread?.projectId,
            repositoryName: project?.repositoryName, threadId: session.threadId, hasThread: true,
            hasConversation: !(session.projection?.messages.isEmpty ?? true), canChangeInteractionMode: true
        )
    }

    private func pick(_ item: ComposerSuggestions.Item) {
        guard let trigger = suggestions.trigger else { return }
        switch item.action {
        case .insert(let replacement):
            text = trigger.replacing(in: text, with: replacement)
        case .interactionMode(let mode):
            text = trigger.replacing(in: text, with: "")
            Task { try? await session.setInteractionMode(mode) }
        case .modelSettings:
            text = trigger.replacing(in: text, with: "")
            showSettings = true
        case .pullRequest(let reference):
            text = trigger.replacing(in: text, with: "\(reference.token) ")
            draft.addPullRequest(reference)
        case .thread(let reference):
            guard draft.addThread(reference) else { return }
            text = trigger.replacing(in: text, with: "\(reference.token) ")
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The amber slot holds what happens next: the microphone on an empty field, send once there is
    /// something to send, stop while the agent works. Otherwise the microphone waits beside it as an
    /// icon. It is always the first view here, so a hold survives send or stop appearing next to it.
    @ViewBuilder
    private var trailingButtons: some View {
        let holdRecording = voice.state == .recording(handsFree: false)
        if voice.state == .idle || holdRecording {
            MicButton(
                voice: voice,
                onHoldEnd: { cancelled in
                    if cancelled { voice.cancel() } else { finishDictation(send: true) }
                },
                onPress: { voice.begin() },
                onTap: { voice.keepHandsFree() },
                onAbandon: { voice.cancel() },
                dragOffset: $micDrag,
                prominent: !hasContent && !isWorking
            )
        }
        if voice.state != .idle {
            // Only the recording's own action while dictating: no send beside ✓.
            VoiceSlotButton(voice: voice) { finishDictation(send: false) }
        } else if hasContent {
            sendButton
        } else if isWorking {
            stopButton
        }
    }

    private func finishDictation(send: Bool) {
        Task {
            guard let dictated = await voice.finish(environment: environment, threadId: session.threadId) else { return }
            insert(dictated, thenSend: send)
        }
    }

    private func retryDictation() {
        Task {
            guard let dictated = await voice.retry(environment: environment, threadId: session.threadId) else { return }
            insert(dictated, thenSend: false)
        }
    }

    private func insert(_ dictated: String, thenSend: Bool) {
        text = trimmed.isEmpty ? dictated : "\(trimmed) \(dictated)"
        if thenSend {
            send(followUp: followUpBehavior.followUp)
        } else {
            focused = true
        }
    }

    private var placeholder: String {
        guard isWorking else { return String(localized: "Ask the agent…") }
        return followUpBehavior == .queue ? String(localized: "Add to the queue…") : String(localized: "Steer the agent…")
    }

    private var stopButton: some View {
            Button {
                stopping = true
                Task {
                    try? await session.interrupt()
                    stopping = false
                }
            } label: {
                Group {
                    if stopping { ProgressView().tint(.white) } else {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                    }
                }
                .frame(width: 40, height: 40)
                .foregroundStyle(.white)
                .background(Palette.error, in: .circle)
            }
            .accessibilityLabel("Stop the agent")
    }

    private var sendButton: some View {
        SendButton(canSend: canSend, other: isWorking ? followUpBehavior.other : nil,
                   label: !isWorking ? "Send" : followUpBehavior == .queue ? "Queue message" : "Steer the agent") {
            send(followUp: $0 ?? followUpBehavior.followUp)
        }
        .equatable()
    }

    private var settingsChips: some View {
        ComposerSettingsChips(
            config: environment.config, selection: thread?.modelSelection,
            runtimeMode: thread?.runtimeMode ?? RuntimeMode.fullAccess.rawValue,
            interactionMode: thread?.interactionMode ?? "default",
            foldMode: hasContent || isWorking,
            onSelection: { selection in apply { try await session.setModel(selection) } },
            onRuntimeMode: { mode in apply { try await session.setRuntimeMode(mode) } },
            onInteractionMode: { mode in apply { try await session.setInteractionMode(mode) } },
            onMore: { showSettings = true }
        )
    }

    /// A settings change from a chip menu applies right away, as in Thread settings.
    private func apply(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                draft.notice = error.localizedDescription
            }
        }
    }

    private func saveDraft() {
        Drafts.shared.save(text: text, files: draft.draftFiles, for: session.threadId, environmentId: environment.id)
    }

    private func send(followUp: ThreadSession.FollowUp) {
        guard canSend else { return }
        let message = draft.message(text: trimmed, inlineContext: environment.config?.inlineMessageContext ?? false)
        text = ""
        draft.reset()
        suggestions.clear()
        Drafts.shared.clear(session.threadId)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        didSend()
        Task {
            await session.send(text: message.text, attachments: message.attachments, context: message.context,
                               followUp: followUp, modelSelection: nil, runtimeMode: nil, interactionMode: nil)
        }
    }
}

/// The amber send button. While the agent works, a hold offers the other follow-up in a menu at
/// the button: a context menu lifted the button out of the card and dimmed the whole screen.
/// Its own `Equatable` view, so updates from the Mac don't rebuild the menu under the finger.
private struct SendButton: View, @MainActor Equatable {
    let canSend: Bool
    /// The follow-up a hold offers; nil when the agent is idle and there's nothing else to offer.
    let other: FollowUpBehavior?
    let label: LocalizedStringKey
    /// nil sends the default follow-up.
    let onSend: (ThreadSession.FollowUp?) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.canSend, lhs.other, lhs.label) == (rhs.canSend, rhs.other, rhs.label)
    }

    var body: some View {
        Group {
            if let other, canSend {
                Menu {
                    switch other {
                    case .steer:
                        Button { onSend(.steer) } label: { Label("Send now (steer)", systemImage: "arrow.turn.down.right") }
                    case .queue:
                        Button { onSend(.queue) } label: { Label("Queue after this turn", systemImage: "clock") }
                    }
                } label: { arrow } primaryAction: { onSend(nil) }
            } else {
                Button { onSend(nil) } label: { arrow }
                    .disabled(!canSend)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("send")
        .accessibilityLabel(label)
    }

    private var arrow: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 40, height: 40)
            .foregroundStyle(canSend ? Palette.accentForeground : Palette.placeholder)
            .background(canSend ? Palette.accent : Palette.border, in: .circle)
    }
}
