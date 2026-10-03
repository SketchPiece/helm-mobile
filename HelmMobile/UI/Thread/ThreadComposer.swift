import PhotosUI
import SwiftUI

/// The composer pill: attach, type, send. While the agent works, an empty composer's button
/// stops it; with text, the message queues (long-press to steer it into the running turn).
struct ThreadComposer: View {
    let environment: EnvironmentSession
    let session: ThreadSession
    var didSend: () -> Void = {}

    @State private var text: String
    @State private var attachments: [DraftAttachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var stopping = false
    @FocusState private var focused: Bool

    init(environment: EnvironmentSession, session: ThreadSession, didSend: @escaping () -> Void = {}) {
        self.environment = environment
        self.session = session
        self.didSend = didSend
        _text = State(initialValue: Drafts.text(for: session.threadId))
    }

    private var thread: ThreadSummary? { session.projection?.thread ?? environment.thread(session.threadId) }
    private var isWorking: Bool { session.projection?.isWorking ?? thread?.isWorking ?? false }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        (!trimmed.isEmpty || attachments.contains { $0.uploaded != nil })
            && !attachments.contains(where: \.isUploading) && environment.isLive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            if focused || !trimmed.isEmpty {
                settingsChips
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 36, height: 36)
                        .contentShape(.circle)
                }
                .foregroundStyle(Palette.text)
                .accessibilityLabel("Attach photos")

                TextField(placeholder, text: $text, axis: .vertical)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.vertical, 7)
                    .onChange(of: text) { _, value in Drafts.save(value, for: session.threadId) }

                sendButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: focused || !trimmed.isEmpty)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            for item in items { attach(item) }
        }
        .sheet(isPresented: $showSettings) {
            ThreadSettingsSheet(environment: environment, session: session)
        }
    }

    private var placeholder: String {
        isWorking ? String(localized: "Add to the queue…") : String(localized: "Ask the agent…")
    }

    @ViewBuilder
    private var sendButton: some View {
        if isWorking && !canSend {
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
        } else {
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
        let message = trimmed
        let uploaded = attachments.compactMap(\.uploaded)
        text = ""
        attachments = []
        Drafts.save("", for: session.threadId)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        didSend()
        Task {
            await session.send(text: message, attachments: uploaded, followUp: followUp,
                               modelSelection: nil, runtimeMode: nil, interactionMode: nil)
        }
    }

    private func attach(_ item: PhotosPickerItem) {
        var draft = DraftAttachment(name: "photo.jpg")
        let id = draft.id
        attachments.append(draft)
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    throw RPCError.defect(String(localized: "Couldn't read the photo"))
                }
                draft.preview = image.preparingThumbnail(of: CGSize(width: 160, height: 160))
                update(id) { $0.preview = draft.preview }
                let uploaded = try await environment.uploadImage(image, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
                update(id) { $0.uploaded = uploaded }
            } catch {
                update(id) { $0.failed = error.localizedDescription }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout DraftAttachment) -> Void) {
        if let index = attachments.firstIndex(where: { $0.id == id }) { change(&attachments[index]) }
    }
}

struct AttachmentStrip: View {
    @Binding var attachments: [DraftAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack {
                        Palette.surface
                        if let preview = attachment.preview {
                            Image(uiImage: preview).resizable().scaledToFill()
                        }
                        if attachment.isUploading {
                            Color.black.opacity(0.3)
                            ProgressView().tint(.white)
                        } else if attachment.failed != nil {
                            Color.black.opacity(0.4)
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.errorText)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.system(size: 18))
                        }
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.horizontal, 6)
        }
    }
}
