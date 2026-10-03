import SwiftUI

/// What the agent is waiting on: an approval (command, edit, permission) or questions.
struct PendingRequestCard: View {
    let request: PendingRequest
    let session: ThreadSession

    var body: some View {
        switch request.kind {
        case .approval(let requestKind, let prompt, let appName, let options):
            ApprovalCard(request: request, requestKind: requestKind, prompt: prompt, appName: appName,
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
            if let prompt, !prompt.isEmpty {
                ScrollView {
                    Text(prompt)
                        .font(requestKind == "command" ? Typography.mono(13) : Typography.subheadline)
                        .foregroundStyle(requestKind == "command" ? Palette.codeText : Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(requestKind == "command" ? 12 : 0)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(requestKind == "command" ? Palette.code : .clear, in: .rect(cornerRadius: 12))
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
            }
        }
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
                    if let description = option.description {
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
                .disabled(!request.canRespond || sending)
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
                try await session.answer(request, answers: answers)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

/// Messages waiting for the current turn to finish.
struct QueueStrip: View {
    let queued: [QueuedMessage]
    let session: ThreadSession
    let canSteer: Bool

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
            ForEach(queued) { message in
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textMuted)
                    Text(message.text)
                        .font(Typography.subheadline)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Menu {
                        if canSteer {
                            Button {
                                Task { try? await session.steerQueued(message.id) }
                            } label: { Label("Send now", systemImage: "arrow.turn.down.right") }
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingSurface(cornerRadius: 18)
    }
}
