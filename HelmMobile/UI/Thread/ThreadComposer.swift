import SwiftUI

/// The composer pill: attach, type, send. While the agent works, an empty composer's button
/// stops it; with text, the message queues (long-press to steer it into the running turn).
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
    @FocusState private var focused: Bool

    init(environment: EnvironmentSession, session: ThreadSession, didSend: @escaping () -> Void = {}) {
        self.environment = environment
        self.session = session
        self.didSend = didSend
        _text = State(initialValue: Drafts.text(for: session.threadId))
    }

    private var thread: ThreadSummary? { environment.thread(session.threadId) ?? session.projection?.thread }
    private var isWorking: Bool { session.projection?.isWorking ?? thread?.isWorking ?? false }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        .onDisappear { if voice.isRecording { voice.cancel() } }
    }

    private var pill: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.attachments.isEmpty || draft.notice != nil {
                AttachmentStrip(draft: draft)
            }
            if focused || !trimmed.isEmpty {
                settingsChips
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                if voice.state != .idle {
                    VoiceStrip(voice: voice, dragOffset: micDrag, onCancel: { voice.cancel(); voice.dismissError() },
                               onDone: { finishDictation(send: false) }, onRetry: retryDictation)
                } else {
                    editor
                }
                trailingButtons
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .floatingSurface(cornerRadius: 24)
        .animation(.easeOut(duration: 0.18), value: focused || !trimmed.isEmpty)
        .animation(.easeOut(duration: 0.18), value: voice.state)
    }

    @ViewBuilder
    private var editor: some View {
                AttachMenu(draft: draft, environment: environment) {
                    if let pasted = draft.paste(environment: environment, draftLength: text.utf16.count) {
                        text += pasted
                    }
                    focused = true
                }

                TextField(placeholder, text: $text, axis: .vertical)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1...8)
                    .focused($focused)
                    .accessibilityIdentifier("composer")
                    .padding(.vertical, 7)
                    .onChange(of: text) { old, value in
                        if let folded = draft.foldPaste(old: old, new: value, environment: environment) {
                            text = folded
                            return
                        }
                        Drafts.save(value, for: session.threadId)
                        suggestions.update(text: value, scope: suggestionScope)
                    }
    }

    private var suggestionScope: ComposerSuggestions.Scope {
        let project = environment.project(thread?.projectId)
        return ComposerSuggestions.Scope(
            environment: environment, providerInstanceId: thread?.modelSelection?.instanceId,
            cwd: thread?.worktreePath ?? project?.workspaceRoot, projectId: thread?.projectId,
            repositoryName: project?.repositoryName, hasThread: true,
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
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Empty field: microphone (and stop while working). With text: send.
    @ViewBuilder
    private var trailingButtons: some View {
        let holdRecording = voice.state == .recording(handsFree: false)
        if canSend && !holdRecording {
            sendButton
        } else if voice.state == .idle || holdRecording {
            MicButton(
                voice: voice,
                onHoldStart: { Task { await voice.start(handsFree: false) } },
                onHoldEnd: { cancelled in
                    if cancelled { voice.cancel() } else { finishDictation(send: true) }
                },
                onTap: {
                    focused = false
                    Task { await voice.start(handsFree: true) }
                },
                dragOffset: $micDrag
            )
            if isWorking && !holdRecording { stopButton }
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
            send(followUp: .queue)
        } else {
            focused = true
        }
    }

    private var placeholder: String {
        isWorking ? String(localized: "Add to the queue…") : String(localized: "Ask the agent…")
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
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(Palette.error, in: .circle)
            }
            .accessibilityLabel("Stop the agent")
    }

    private var sendButton: some View {
            Button {
                send(followUp: .queue)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(canSend ? Palette.accentForeground : Palette.placeholder)
                    .background(canSend ? Palette.accent : Palette.border, in: .circle)
            }
            .disabled(!canSend)
            .accessibilityIdentifier("send")
            .contextMenu {
                if isWorking && canSend {
                    Button {
                        send(followUp: .steer)
                    } label: { Label("Send now (steer)", systemImage: "arrow.turn.down.right") }
                    Button {
                        send(followUp: .queue)
                    } label: { Label("Queue after this turn", systemImage: "clock") }
                }
            }
            .accessibilityLabel(isWorking ? "Queue message" : "Send")
    }

    private var settingsChips: some View {
        let config = environment.config
        let mode = RuntimeMode(rawValue: thread?.runtimeMode ?? "") ?? .fullAccess
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(config?.modelLabel(for: thread?.modelSelection) ?? String(localized: "Model"), symbol: "cpu")
                chip(mode.title, symbol: mode.symbol)
                if thread?.interactionMode == "plan" {
                    chip(String(localized: "Plan"), symbol: "list.bullet.clipboard")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func chip(_ title: String, symbol: String) -> some View {
        Button {
            showSettings = true
        } label: {
            Label(title, systemImage: symbol)
                .font(Typography.footnote.weight(.medium))
                .foregroundStyle(Palette.textMuted)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Palette.surface.opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func send(followUp: ThreadSession.FollowUp) {
        guard canSend else { return }
        let message = draft.message(text: trimmed, inlineContext: environment.config?.inlineMessageContext ?? false)
        text = ""
        draft.reset()
        suggestions.clear()
        Drafts.save("", for: session.threadId)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        didSend()
        Task {
            await session.send(text: message.text, attachments: message.attachments, context: message.context,
                               followUp: followUp, modelSelection: nil, runtimeMode: nil, interactionMode: nil)
        }
    }
}
