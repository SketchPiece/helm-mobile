import SwiftUI

/// An approval or the agent's questions, answerable from the wrist.
struct RequestCard: View {
    let thread: WatchThread
    let request: WatchRequest
    @Binding var busy: Bool
    @Binding var error: String?
    @Environment(WatchStore.self) private var store
    /// Picks so far, per question (multi-select and multi-question cards).
    @State private var picks: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.kind {
            case .approval: approval
            case .questions: questions
            }
            if !request.canRespond {
                Text("The agent can't take an answer anymore.")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textMuted)
            }
        }
        .padding(10)
        .background(tint.opacity(0.16), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5), lineWidth: 1))
        .disabled(busy || !request.canRespond)
    }

    private var tint: Color { request.kind == .approval ? WatchPalette.accent : WatchPalette.question }

    // MARK: Approval

    @ViewBuilder
    private var approval: some View {
        Label(request.title ?? String(localized: "Allow this?"), systemImage: "hand.raised.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(WatchPalette.accentText)
        if let detail = request.detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(8)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.35), in: .rect(cornerRadius: 8))
        }
        let primary = request.options.first { $0.decision == "accept" } ?? request.options.first
        let decline = request.options.first { $0.decision == "decline" || $0.decision == "cancel" }
        let others = request.options.filter { $0 != primary && $0 != decline }
        if let primary {
            Button { respond(primary.decision) } label: {
                Text(primary.label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(WatchPalette.accent)
            .foregroundStyle(WatchPalette.accentForeground)
        }
        ForEach(others, id: \.decision) { option in
            Button { respond(option.decision) } label: {
                Text(option.label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        if let decline {
            Button(role: .destructive) { respond(decline.decision) } label: {
                Text(decline.label).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func respond(_ decision: String) {
        send(.respond(environmentId: thread.environmentId, threadId: thread.threadId, requestId: request.id, decision: decision))
    }

    // MARK: Questions

    /// One single-choice question answers on the first tap; anything else collects picks and sends.
    private var answersOnTap: Bool { request.questions.count == 1 && request.questions.first?.multiSelect == false }

    @ViewBuilder
    private var questions: some View {
        ForEach(request.questions) { question in
            VStack(alignment: .leading, spacing: 6) {
                if let header = question.header, !header.isEmpty {
                    Text(header.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WatchPalette.question)
                }
                Text(question.question)
                    .font(.footnote.weight(.medium))
                ForEach(question.options, id: \.answer) { option in
                    optionButton(question, option)
                }
                if question.allowCustomAnswer {
                    TextFieldLink(prompt: Text("Your answer")) {
                        Label(custom(question) ?? String(localized: "Other…"), systemImage: "mic")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } onSubmit: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        if answersOnTap {
                            answer([question.id: [trimmed]])
                        } else {
                            picks[question.id] = [trimmed]
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        if !answersOnTap {
            Button { answer(picks) } label: {
                Text("Send answers").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(WatchPalette.question)
            .disabled(request.questions.contains { (picks[$0.id] ?? []).isEmpty })
        }
        if request.dismissible {
            Button { send(.dismiss(environmentId: thread.environmentId, threadId: thread.threadId, requestId: request.id)) } label: {
                Text("Skip").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func optionButton(_ question: WatchRequest.Question, _ option: WatchRequest.Choice) -> some View {
        let picked = picks[question.id]?.contains(option.answer) == true
        return Button {
            if answersOnTap {
                answer([question.id: [option.answer]])
            } else if question.multiSelect {
                var list = picks[question.id] ?? []
                if picked { list.removeAll { $0 == option.answer } } else { list.append(option.answer) }
                picks[question.id] = list
            } else {
                picks[question.id] = [option.answer]
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                if !answersOnTap {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? WatchPalette.question : WatchPalette.textMuted)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.footnote).foregroundStyle(.white)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(WatchPalette.textMuted).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.bordered)
    }

    /// The typed answer, when it isn't one of the options.
    private func custom(_ question: WatchRequest.Question) -> String? {
        guard let pick = picks[question.id]?.first, !question.options.contains(where: { $0.answer == pick }) else { return nil }
        return pick
    }

    private func answer(_ answers: [String: [String]]) {
        send(.answer(environmentId: thread.environmentId, threadId: thread.threadId, requestId: request.id, answers: answers))
    }

    private func send(_ message: WatchRequestMessage) {
        busy = true
        error = nil
        Task {
            let reply = await store.perform(message)
            busy = false
            if !reply.ok { error = reply.error }
        }
    }
}
