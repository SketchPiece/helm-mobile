import PhotosUI
import SwiftUI

/// What the agent is waiting on: an approval (command, edit, permission) or questions.
struct PendingRequestCard: View {
    let request: PendingRequest
    let session: ThreadSession

    var body: some View {
        switch request.kind {
        case .approval(let requestKind, let prompt, let detail, let appName, let options):
            ApprovalCard(request: request, requestKind: requestKind, prompt: prompt, detail: detail, appName: appName,
                         options: options, session: session)
        case .questions(let questions, let dismissible):
            QuestionsCard(request: request, questions: questions, dismissible: dismissible, session: session)
        }
    }
}

private struct CardChrome<Content: View>: View {
    let label: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(label).sectionLabelStyle()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct ApprovalCard: View {
    let request: PendingRequest
    let requestKind: String
    let prompt: String?
    let detail: String?
    let appName: String?
    let options: [ApprovalOption]
    let session: ThreadSession
    @State private var sending: String?
    @State private var error: String?

    var body: some View {
        CardChrome(label: String(localized: "Approval needed"), tint: Palette.accent) {
            Text(title)
                .font(Typography.headline)
                .foregroundStyle(Palette.text)
            if let prompt, !prompt.isEmpty, prompt != detail {
                Text(prompt)
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(Typography.mono(13))
                        .foregroundStyle(Palette.codeText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(Palette.code, in: .rect(cornerRadius: 12))
            }
            if let warning = options.compactMap(\.warning).first {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.accentText)
            }
            if !request.canRespond {
                Text("The agent's session ended, so this can't be answered from here anymore.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textMuted)
            }
            buttons
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            }
        }
    }

    private var title: String {
        if let appName { return String(localized: "\(appName) wants to continue") }
        switch requestKind {
        case "command": return String(localized: "Run this command?")
        case "file-change": return String(localized: "Make these edits?")
        case "file-read": return String(localized: "Read these files?")
        case "mcp-elicitation": return String(localized: "A tool needs your input")
        default: return String(localized: "Allow this?")
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let primary = options.first { $0.decision == "accept" } ?? options.first
        let secondary = options.filter { $0 != primary && $0.decision != "decline" && $0.decision != "cancel" }
        let decline = options.first { $0.decision == "decline" || $0.decision == "cancel" }
        VStack(spacing: 8) {
            if let primary {
                Button { respond(primary) } label: {
                    buttonLabel(primary).font(Typography.headline).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("requestPrimary")
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.accentForeground)
            }
            HStack(spacing: 8) {
                ForEach(secondary, id: \.decision) { option in
                    Button { respond(option) } label: {
                        buttonLabel(option).font(Typography.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                if let decline {
                    Button { respond(decline) } label: {
                        buttonLabel(decline).font(Typography.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(Palette.errorText)
                }
            }
        }
        .disabled(!request.canRespond || sending != nil)
    }

    @ViewBuilder
    private func buttonLabel(_ option: ApprovalOption) -> some View {
        if sending == option.decision {
            ProgressView()
        } else {
            Text(option.label)
        }
    }

    private func respond(_ option: ApprovalOption) {
        sending = option.decision
        Task {
            do {
                try await session.respond(to: request, decision: option.decision)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
            }
            sending = nil
        }
    }
}

private struct QuestionsCard: View {
    let request: PendingRequest
    let questions: [UserQuestion]
    let dismissible: Bool
    let session: ThreadSession

    @State private var index = 0
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var attachments: [String: [QuestionAttachment]] = [:]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var collapsed = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        CardChrome(label: String(localized: "Needs an answer"), tint: Palette.question) {
            HStack {
                Text(questions.count > 1 ? String(localized: "Answer the questions") : String(localized: "Answer the question"))
                    .font(Typography.headline)
                Spacer()
                Button {
                    withAnimation(.snappy) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            if !collapsed, questions.indices.contains(index) {
                questionView(questions[index])
                footer
            }
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: UserQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if questions.count > 1 || question.header != nil {
                Text([questions.count > 1 ? String(localized: "Question \(index + 1) of \(questions.count)") : nil, question.header]
                    .compactMap { $0 }.joined(separator: " · "))
                    .sectionLabelStyle()
            }
            Text(question.question)
                .font(Typography.body)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(question.options, id: \.label) { option in
                        optionButton(option, question: question)
                    }
                }
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
            if question.allowCustomAnswer {
                TextField("Or write your own answer", text: Binding(
                    get: { custom[question.id] ?? "" },
                    set: { custom[question.id] = $0 }
                ), axis: .vertical)
                .font(Typography.subheadline)
                .lineLimit(1...4)
                .padding(12)
                .background(Palette.surface, in: .rect(cornerRadius: 12))
                if canAttach {
                    attachmentRow(question)
                }
            }
        }
    }

    // MARK: Attachments

    struct QuestionAttachment: Identifiable {
        let id = UUID()
        var preview: UIImage?
        var uploaded: ChatAttachment?
        var failed: String?
    }

    private var canAttach: Bool { session.environment?.config?.capability("questionAttachments") == true }

    private var isUploading: Bool {
        attachments.values.joined().contains { $0.uploaded == nil && $0.failed == nil }
    }

    private func attachmentRow(_ question: UserQuestion) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
                    Label("Attach photos", systemImage: "photo.badge.plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(Palette.surface, in: .rect(cornerRadius: 12))
                }
                .foregroundStyle(Palette.text)
                .onChange(of: pickerItems) { _, items in
                    guard !items.isEmpty else { return }
                    items.forEach { attach($0, to: question.id) }
                    pickerItems = []
                }
                ForEach(attachments[question.id] ?? []) { attachment in
                    thumbnail(attachment, questionId: question.id)
                }
            }
        }
    }

    private func thumbnail(_ attachment: QuestionAttachment, questionId: String) -> some View {
        ZStack {
            Palette.surface
            if let preview = attachment.preview {
                Image(uiImage: preview).resizable().scaledToFill()
            }
            if attachment.failed != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.errorText)
            } else if attachment.uploaded == nil {
                ProgressView()
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(.rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Button {
                attachments[questionId]?.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Palette.text, Palette.surfaceRaised)
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Remove")
            .offset(x: 5, y: -5)
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }

    private func attach(_ item: PhotosPickerItem, to questionId: String) {
        let draft = QuestionAttachment()
        attachments[questionId, default: []].append(draft)
        Task {
            do {
                guard let environment = session.environment else { throw RPCError.disconnected }
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw RPCError.defect(String(localized: "Couldn't read the photo"))
                }
                let preview = image.preparingThumbnail(of: CGSize(width: 120, height: 120))
                update(draft.id, in: questionId) { $0.preview = preview }
                let uploaded = try await environment.uploadImage(image, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
                update(draft.id, in: questionId) { $0.uploaded = uploaded }
            } catch {
                update(draft.id, in: questionId) { $0.failed = error.localizedDescription }
            }
        }
    }

    private func update(_ id: UUID, in questionId: String, _ change: (inout QuestionAttachment) -> Void) {
        guard let index = attachments[questionId]?.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[questionId]![index])
    }

    private func optionButton(_ option: UserQuestion.Option, question: UserQuestion) -> some View {
        let selected = selections[question.id, default: []].contains(option.answer)
        return Button {
            var set = selections[question.id, default: []]
            if question.multiSelect {
                if selected { set.remove(option.answer) } else { set.insert(option.answer) }
            } else {
                set = selected ? [] : [option.answer]
            }
            selections[question.id] = set
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.multiSelect
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Palette.accent : Palette.placeholder)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(Typography.subheadline.weight(.medium)).foregroundStyle(Palette.text)
                    if let description = option.description, description != option.label {
                        Text(description).font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .background(selected ? Palette.warningSurface : Palette.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Palette.accent : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("questionOption")
    }

    @ViewBuilder
    private var footer: some View {
        let isLast = index == questions.count - 1
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if index > 0 {
                    Button("Back") { withAnimation(.snappy) { index -= 1 } }
                        .buttonStyle(.glass)
                }
                Button {
                    if isLast { submit() } else { withAnimation(.snappy) { index += 1 } }
                } label: {
                    Group {
                        if sending { ProgressView() } else {
                            Text(isLast ? String(localized: "Send answers") : String(localized: "Next"))
                        }
                    }
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.accentForeground)
                .disabled(!request.canRespond || sending || (isLast && isUploading))
                .accessibilityIdentifier(isLast ? "requestPrimary" : "requestNext")
            }
            if dismissible {
                Button("Dismiss without answering") {
                    Task { try? await session.dismiss(request) }
                }
                .font(Typography.footnote)
                .foregroundStyle(Palette.textMuted)
            }
        }
    }

    private func submit() {
        var answers: [String: JSON] = [:]
        for question in questions {
            let text = custom[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty, question.allowCustomAnswer {
                answers[question.id] = .string(text)
            } else {
                let picked = question.options.map(\.answer).filter { selections[question.id, default: []].contains($0) }
                if question.multiSelect {
                    answers[question.id] = .array(picked.map { .string($0) })
                } else if let first = picked.first {
                    answers[question.id] = .string(first)
                }
            }
        }
        sending = true
        Task {
            do {
                try await session.answer(request, answers: answers, attachmentsByQuestionId: attachments.mapValues {
                    $0.compactMap(\.uploaded)
                })
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Messages waiting for the current turn to finish. With two or more and a provider that takes
/// queued messages, the grip drags a message to a new place (Move up/down stay in its menu).
struct QueueStrip: View {
    let queued: [QueuedMessage]
    let session: ThreadSession
    let canSteer: Bool
    /// The provider session takes queued messages, so their order can change.
    let canReorder: Bool
    @State private var editing: QueuedMessage?
    @State private var error: String?
    /// Row frames in the list's own space, measured before any drag offset.
    @State private var frames: [String: CGRect] = [:]
    @State private var dragging: String?
    @State private var dragOffset: CGFloat = 0
    /// The order just sent, shown until the server's run updates replace it.
    @State private var pendingOrder: [String]?

    private static let rowSpacing: CGFloat = 6

    private var canDrag: Bool { canReorder && queued.count > 1 }

    private var displayed: [QueuedMessage] {
        guard let pendingOrder, Set(pendingOrder) == Set(queued.map(\.id)) else { return queued }
        return pendingOrder.compactMap { id in queued.first { $0.id == id } }
    }

    private var rowFrames: [QueueOrder.RowFrame] {
        displayed.compactMap { message in
            frames[message.id].map { QueueOrder.RowFrame(id: message.id, minY: $0.minY, height: $0.height) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(queued.contains(where: \.held) ? String(localized: "Queue paused") : String(localized: "Up next"))
                    .sectionLabelStyle()
                Spacer()
                if queued.contains(where: \.held) {
                    Button("Resume") { Task { try? await session.resumeQueue() } }
                        .font(Typography.footnote.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                }
            }
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(displayed) { message in
                    row(message)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("queue")) } action: { frames[message.id] = $0 }
                        .offset(y: dragging == message.id ? dragOffset : shift(for: message.id))
                        .zIndex(dragging == message.id ? 1 : 0)
                        .animation(.snappy(duration: 0.2), value: dragging == message.id ? 0 : shift(for: message.id))
                }
            }
            .coordinateSpace(.named("queue"))
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingSurface(cornerRadius: 18)
        .onChange(of: queued.map(\.id)) { pendingOrder = nil }
        .sheet(item: $editing) { message in
            QueuedMessageEditor(message: message, session: session)
        }
    }

    private func row(_ message: QueuedMessage) -> some View {
        HStack(spacing: 8) {
            if canDrag {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(dragging == message.id ? Palette.text : Palette.textMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
                    .gesture(dragGesture(message))
                    .accessibilityLabel("Drag to reorder")
                    .accessibilityIdentifier("queueDragHandle")
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textMuted)
            }
            if !message.attachments.isEmpty {
                Image(systemName: "paperclip")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textMuted)
            }
            Text(ContextReference.displayText(message.text))
                .font(Typography.subheadline)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            menu(message)
        }
        .background(dragging == message.id ? Palette.surfaceRaised : .clear, in: .rect(cornerRadius: 10))
        .scaleEffect(dragging == message.id ? 1.02 : 1)
        .accessibilityIdentifier("queuedMessage")
    }

    private func menu(_ message: QueuedMessage) -> some View {
        Menu {
            if canSteer {
                Button {
                    Task { try? await session.steerQueued(message.id) }
                } label: { Label("Send now", systemImage: "arrow.turn.down.right") }
            }
            Button {
                editing = message
            } label: { Label("Edit", systemImage: "pencil") }
            if canDrag {
                let ids = displayed.map(\.id)
                if let before = QueueOrder.beforeRunId(ids, moving: message.id, .up) {
                    Button { reorder(message.id, before: before) } label: { Label("Move up", systemImage: "arrow.up") }
                }
                if let before = QueueOrder.beforeRunId(ids, moving: message.id, .down) {
                    Button { reorder(message.id, before: before) } label: { Label("Move down", systemImage: "arrow.down") }
                }
            }
            Button(role: .destructive) {
                Task { try? await session.cancelQueued(message.id) }
            } label: { Label("Remove", systemImage: "xmark") }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .foregroundStyle(Palette.textMuted)
    }

    private func dragGesture(_ message: QueuedMessage) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragging == nil { UISelectionFeedbackGenerator().selectionChanged() }
                dragging = message.id
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let drop = QueueOrder.dropBeforeRunId(rowFrames, moving: message.id, translation: value.translation.height)
                withAnimation(.snappy(duration: 0.2)) {
                    if let before = drop {
                        pendingOrder = QueueOrder.reordered(displayed.map(\.id), moving: message.id, before: before)
                    }
                    dragging = nil
                    dragOffset = 0
                }
                if let before = drop { reorder(message.id, before: before) }
            }
    }

    /// How far another row moves aside while one is dragged over it.
    private func shift(for id: String) -> CGFloat {
        guard let dragging, dragging != id, let source = frames[dragging],
              let before = QueueOrder.dragBeforeRunId(rowFrames, moving: dragging, translation: dragOffset)
        else { return 0 }
        let ids = displayed.map(\.id)
        let target = QueueOrder.reordered(ids, moving: dragging, before: before)
        guard let from = ids.firstIndex(of: id), let to = target.firstIndex(of: id) else { return 0 }
        return CGFloat(to - from) * (source.height + Self.rowSpacing)
    }

    private func reorder(_ runId: String, before: String?) {
        Task {
            do {
                try await session.reorderQueued(runId, before: before)
                error = nil
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                pendingOrder = nil
                self.error = error.localizedDescription
            }
        }
    }
}

/// Rewrites a queued message before it is sent: its text, and which attachments go with it
/// (remove ones it has, add photos and files like in the composer).
private struct QueuedMessageEditor: View {
    let message: QueuedMessage
    let session: ThreadSession
    @Environment(\.dismiss) private var dismiss
    /// File links the composer appended; hidden here, put back on save.
    private let trailing: [QueuedEdit.Link]
    private let initialText: String
    @State private var text: String
    @State private var kept: [ChatAttachment]
    @State private var draft = ComposerDraft()
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(message: QueuedMessage, session: ThreadSession) {
        self.message = message
        self.session = session
        let split = QueuedEdit.split(message.text)
        trailing = split.trailing
        initialText = split.body
        _text = State(initialValue: split.body)
        _kept = State(initialValue: message.attachments)
    }

    private var environment: EnvironmentSession? { session.environment }

    private var payload: QueuedEdit.Payload {
        QueuedEdit.payload(
            body: text.trimmingCharacters(in: .whitespacesAndNewlines), trailing: trailing, original: message,
            kept: kept, added: draft.uploaded, inlineContext: environment?.config?.inlineMessageContext ?? false
        )
    }

    private var changed: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != initialText
            || kept.map(\.id) != message.attachments.map(\.id) || draft.hasUploaded
    }

    private var canSave: Bool {
        changed && !saving && !draft.isUploading
            && !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && kept.count + draft.attachments.count <= AttachmentLimits.maxPerMessage
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(10)
                    .background(Palette.surface, in: .rect(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("queuedEditor")
                HStack(alignment: .center, spacing: 8) {
                    AttachMenu(draft: draft, environment: environment) {
                        if let environment, let pasted = draft.paste(environment: environment, draftLength: text.utf16.count) {
                            text += pasted
                        }
                    }
                    .background(Palette.surface, in: .circle)
                    if !kept.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(kept) { attachment in
                                    KeptAttachmentTile(attachment: attachment, environment: environment) {
                                        kept.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                            .padding(.top, 6)
                            .padding(.trailing, 6)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !draft.attachments.isEmpty || draft.notice != nil {
                    AttachmentStrip(draft: draft)
                }
                if let error {
                    Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                }
            }
            .padding(16)
            .background(Palette.canvas)
            .navigationTitle("Edit queued message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if saving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("queuedEditorSave")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        saving = true
        error = nil
        let payload = payload
        Task {
            do {
                try await session.editQueued(message.id, payload)
                dismiss()
            } catch {
                // The run most likely left the queue meanwhile.
                self.error = String(localized: "Couldn't save. It may have already started.")
            }
            saving = false
        }
    }
}

/// An attachment the queued message already has: a picture tile or a file chip, removable.
private struct KeptAttachmentTile: View {
    let attachment: ChatAttachment
    let environment: EnvironmentSession?
    let onRemove: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Group {
            if attachment.isImage {
                ZStack {
                    Palette.surface
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                }
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
            } else {
                Label(attachment.name, systemImage: "doc")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                    .padding(.horizontal, 10)
                    .frame(height: 52)
                    .background(Palette.surface, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Remove \(attachment.name)")
            .offset(x: 5, y: -5)
        }
        .task(id: attachment.id) {
            guard attachment.isImage, image == nil, let environment else { return }
            image = await AttachmentLoader.image(attachment, environment: environment)
        }
    }
}
