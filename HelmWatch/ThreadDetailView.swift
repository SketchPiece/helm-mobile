import SwiftUI

/// One thread: what it waits for, then the conversation newest first, and a bar to reply, stop or settle.
struct ThreadDetailView: View {
    let threadId: String
    @Environment(WatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Group {
            if let thread = store.thread(threadId) {
                content(thread)
            } else if loading {
                ProgressView()
            } else {
                EmptyState(symbol: "questionmark.folder", title: String(localized: "Thread not found"),
                           detail: String(localized: "It may have been archived."))
            }
        }
        .navigationTitle(store.thread(threadId)?.projectTitle ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await store.open(threadId)
            loading = false
        }
        .onDisappear { store.close(threadId) }
    }

    private func content(_ thread: WatchThread) -> some View {
        let detail = store.details[threadId]
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header(thread, detail: detail)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.error)
                }
                ForEach(detail?.requests ?? []) { request in
                    RequestCard(thread: thread, request: request, busy: $busy, error: $error)
                }
                if detail == nil && loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach((detail?.messages ?? fallbackMessages(thread)).reversed()) { message in
                    MessageView(message: message)
                }
            }
        }
        // The bottom bar floats over the end of the thread; leave room to scroll the last button clear.
        .contentMargins(.bottom, 44, for: .scrollContent)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                bottomBar(thread, detail: detail)
            }
        }
    }

    private func header(_ thread: WatchThread, detail: WatchThreadDetail?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(thread.title)
                .font(.headline)
                .lineLimit(3)
            PhaseLabel(phase: thread.phase)
            if let queued = detail?.queuedCount, queued > 0 {
                Text("\(queued) queued")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textMuted)
            }
            if detail?.isStale == true && !loading {
                Text("Not live: the iPhone is reconnecting.")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textMuted)
            }
            if thread.phase == .failed || thread.phase == .limited, let lastError = thread.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.error)
                    .lineLimit(4)
            }
        }
    }

    /// Before the phone answers, the list's latest message stands in.
    private func fallbackMessages(_ thread: WatchThread) -> [WatchMessage] {
        guard let text = thread.latestText else { return [] }
        return [WatchMessage(id: "latest", role: thread.latestRole == "user" ? .user : .assistant, text: text, date: thread.updatedAt)]
    }

    @ViewBuilder
    private func bottomBar(_ thread: WatchThread, detail: WatchThreadDetail?) -> some View {
        let working = detail?.isWorking ?? (thread.phase == .working)
        if working || thread.phase == .waiting {
            Button(role: .destructive) {
                act(.interrupt(environmentId: thread.environmentId, threadId: thread.threadId))
            } label: {
                Image(systemName: "stop.fill").foregroundStyle(.white)
            }
            .tint(WatchPalette.errorFill)
            .accessibilityLabel(Text("Stop"))
            .disabled(busy)
        } else if !thread.isSettled {
            Button {
                act(.settle(environmentId: thread.environmentId, threadId: thread.threadId)) { dismiss() }
            } label: {
                Image(systemName: "checkmark").foregroundStyle(.white)
            }
            .tint(WatchPalette.surface)
            .accessibilityLabel(Text("Settle"))
            .disabled(busy)
        }
        Spacer()
        TextFieldLink(prompt: Text(working ? "Queue a message" : "Reply")) {
            Image(systemName: "mic.fill").foregroundStyle(WatchPalette.accentForeground)
        } onSubmit: { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            act(.send(environmentId: thread.environmentId, threadId: thread.threadId, text: trimmed))
        }
        .accessibilityLabel(Text("Reply"))
        .disabled(busy)
    }

    private func act(_ message: WatchRequestMessage, then: @escaping () -> Void = {}) {
        busy = true
        error = nil
        Task {
            let reply = await store.perform(message)
            busy = false
            if reply.ok { then() } else { error = reply.error }
        }
    }
}

struct MessageView: View {
    let message: WatchMessage

    var body: some View {
        switch message.role {
        case .work:
            Label(message.text, systemImage: "gearshape.2")
                .font(.caption2)
                .foregroundStyle(WatchPalette.textMuted)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(WatchPalette.error)
        case .user:
            VStack(alignment: .leading, spacing: 2) {
                Text("You").font(.caption2.weight(.semibold)).foregroundStyle(WatchPalette.accentText)
                Text(message.text).font(.footnote)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchPalette.surface, in: .rect(cornerRadius: 12))
        case .assistant, .plan:
            VStack(alignment: .leading, spacing: 2) {
                if message.role == .plan {
                    Text("Plan").font(.caption2.weight(.semibold)).foregroundStyle(WatchPalette.question)
                }
                Text(Self.markdown(message.text)).font(.footnote)
            }
        }
    }

    /// Inline markdown (bold, code, links); block syntax stays as typed, which reads fine at this size.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
