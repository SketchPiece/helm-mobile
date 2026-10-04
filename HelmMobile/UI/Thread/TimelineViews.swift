import SwiftUI

/// The user's message: a bubble on the right, attachments above the text.
struct UserBubble: View {
    let item: TurnItem
    let environment: EnvironmentSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let attachments = item.attachments
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        AttachmentThumbnail(attachment: attachment, environment: environment)
                    }
                }
            }
            if !item.text.isEmpty {
                Text(item.text)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.message, in: .rect(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = item.text
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
            }
            if item.inputIntent == "steer" || item.inputIntent == "promoted_queued_to_steer" {
                Label("Steered", systemImage: "arrow.turn.down.right")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

/// A message this phone sent that the server hasn't confirmed yet (or that failed).
struct OutgoingBubble: View {
    let message: ThreadSession.OutgoingMessage
    let session: ThreadSession

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(message.text)
                .font(Typography.body)
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.message, in: .rect(cornerRadius: 20, style: .continuous))
                .opacity(message.failed == nil ? 0.7 : 1)
            if let failed = message.failed {
                HStack(spacing: 10) {
                    Text(failed).foregroundStyle(Palette.errorText).lineLimit(2)
                    Button("Retry") { Task { await session.retry(message) } }
                        .foregroundStyle(Palette.accentText)
                    Button("Discard") { session.discard(message) }
                        .foregroundStyle(Palette.textMuted)
                }
                .font(Typography.footnote)
            } else {
                Text("Sending…")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
    }
}

/// Agent work between two messages. Collapsed it is one line; live it shows the current step.
struct WorkGroupView: View {
    let items: [TurnItem]
    let isLive: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if isLive {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 13)
                    }
                    Text(headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Typography.subheadline)
                .foregroundStyle(Palette.textMuted)
                .contentShape(.rect)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        WorkStepRow(item: item)
                    }
                }
                .padding(.leading, 4)
                .padding(.top, 4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Palette.border).frame(width: 1).padding(.vertical, 6)
                }
                .transition(.opacity)
            }
        }
    }

    private var headline: String {
        if isLive, let current = items.last(where: \.isRunning) ?? items.last {
            let summary = Timeline.summary(of: current)
            return summary.text
        }
        return Timeline.groupSummary(items)
    }
}

/// One step inside an expanded work group.
struct WorkStepRow: View {
    let item: TurnItem
    @State private var showDetail = false
    @Environment(Router.self) private var router
    @Environment(\.threadEnvironmentId) private var environmentId

    var body: some View {
        let summary = Timeline.summary(of: item)
        let failed = item.status == "failed" || item.raw["outputIndicatesFailure"]?.bool == true
        Button {
            if hasDetail { withAnimation(.snappy(duration: 0.2)) { showDetail.toggle() } }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: summary.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .foregroundStyle(failed ? Palette.errorText : Palette.textMuted)
                    Text(summary.text)
                        .font(item.type == "command_execution" ? Typography.mono(13) : Typography.footnote)
                        .foregroundStyle(Palette.text.opacity(0.85))
                        .lineLimit(showDetail ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if item.isRunning {
                        ProgressView().controlSize(.mini)
                    } else if let detail = summary.detail {
                        Text(detail)
                            .font(Typography.mono(12))
                            .foregroundStyle(failed ? Palette.errorText : Palette.textMuted)
                    }
                }
                if showDetail, let detail = detailText {
                    Text(detail)
                        .font(item.type == "reasoning" ? Typography.footnote : Typography.mono(12))
                        .foregroundStyle(Palette.textMuted)
                        .textSelection(.enabled)
                        .padding(.leading, 24)
                }
                if showDetail, item.type == "subagent", let child = item.raw["childThreadId"]?.string, let environmentId {
                    Button {
                        router.push(ThreadRef(environmentId: environmentId, threadId: child))
                    } label: {
                        Label("Open the agent's thread", systemImage: "arrow.up.right")
                            .font(Typography.footnote.weight(.medium))
                            .foregroundStyle(Palette.accentText)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 24)
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var hasDetail: Bool { detailText != nil }

    private var detailText: String? {
        switch item.type {
        case "reasoning":
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case "subagent":
            return item.raw["result"]?.string ?? item.raw["prompt"]?.string
        case "file_change":
            let paths = (item.raw["changes"]?.array ?? []).compactMap { $0["path"]?.string }
            return paths.isEmpty ? nil : paths.joined(separator: "\n")
        case "file_search":
            let results = (item.raw["results"]?.array ?? []).prefix(20).compactMap { $0["fileName"]?.string }
            return results.isEmpty ? nil : results.joined(separator: "\n")
        case "web_search":
            let results = (item.raw["results"]?.array ?? []).prefix(10).compactMap { $0["title"]?.string ?? $0["url"]?.string }
            return results.isEmpty ? nil : results.joined(separator: "\n")
        case "dynamic_tool":
            guard let input = item.raw["input"], !input.isNull else { return nil }
            if let summary = input["summary"]?.string { return summary }
            return (try? input.data()).map { String(decoding: $0, as: UTF8.self) }.map { String($0.prefix(1200)) }
        default:
            return nil
        }
    }
}

/// While the agent has started but produced nothing visible yet.
struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Thinking").font(Typography.subheadline)
        }
        .foregroundStyle(Palette.textMuted)
    }
}

/// "Working 3:12" above the composer; tells the truth about elapsed time without animation.
struct WorkingPill: View {
    let since: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Palette.working).frame(width: 7, height: 7)
            Text("Working")
            Text(since, style: .timer).monospacedDigit()
        }
        .font(Typography.footnote)
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.surfaceRaised, in: .capsule)
        .overlay(Capsule().stroke(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

struct PlanCard: View {
    let item: TurnItem
    let actionable: Bool
    let implement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Plan", systemImage: "list.bullet.clipboard")
                .sectionLabelStyle()
            MarkdownView(text: item.text)
            if actionable {
                Button(action: implement) {
                    Text("Implement plan").font(Typography.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .foregroundStyle(Palette.accentForeground)
            }
        }
        .padding(16)
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

struct TodoCard: View {
    let item: TurnItem

    var body: some View {
        let steps = item.raw["steps"]?.array ?? []
        let done = steps.filter { $0["status"]?.string == "completed" }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("To-do").sectionLabelStyle()
                Spacer()
                Text("\(done)/\(steps.count)").font(Typography.mono(12)).foregroundStyle(Palette.textMuted)
            }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                let status = step["status"]?.string ?? "pending"
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: status == "completed" ? "checkmark.circle.fill" : status == "running" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(status == "completed" ? Palette.done : status == "running" ? Palette.accent : Palette.placeholder)
                        .font(.system(size: 14))
                    Text(step["text"]?.string ?? "")
                        .font(Typography.subheadline)
                        .foregroundStyle(status == "completed" ? Palette.textMuted : Palette.text)
                        .strikethrough(status == "completed", color: Palette.placeholder)
                }
            }
        }
        .padding(14)
        .background(Palette.surface, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// "3 files changed +20 −4" after a turn; opens the diff.
struct ChangesCard: View {
    let item: TurnItem
    let open: () -> Void

    var body: some View {
        let files = item.raw["files"]?.array ?? []
        let additions = files.reduce(0) { $0 + ($1["additions"]?.int ?? 0) }
        let deletions = files.reduce(0) { $0 + ($1["deletions"]?.int ?? 0) }
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(Palette.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(files.count == 1 ? String(localized: "1 file changed") : String(localized: "\(files.count) files changed"))
                        .font(Typography.subheadline.weight(.medium))
                        .foregroundStyle(Palette.text)
                    Text(files.prefix(3).compactMap { ($0["path"]?.string as NSString?)?.lastPathComponent }.joined(separator: ", "))
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text("+\(additions)").foregroundStyle(Palette.done)
                Text("−\(deletions)").foregroundStyle(Palette.errorText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.placeholder)
            }
            .font(Typography.mono(13))
            .padding(12)
            .background(Palette.surface, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("changesCard")
    }
}

struct ErrorCard: View {
    let item: TurnItem

    var body: some View {
        let failure = item.raw["failure"]
        let message = failure?["message"]?.string ?? item.text
        let isLimit = failure?["class"]?.string == "usage_limit"
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isLimit ? "gauge.with.dots.needle.100percent" : "exclamationmark.triangle.fill")
                .foregroundStyle(isLimit ? Palette.accentText : Palette.errorText)
            VStack(alignment: .leading, spacing: 4) {
                Text(isLimit ? String(localized: "Usage limit reached") : String(localized: "Something went wrong"))
                    .font(Typography.subheadline.weight(.semibold))
                Text(message)
                    .font(Typography.footnote)
                    .textSelection(.enabled)
                if let reset = ISODate.parse(failure?["resetAt"]?.string) {
                    Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .foregroundStyle(Palette.text)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(isLimit ? Palette.warningSurface : Palette.errorSurface, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

struct NoticeRow: View {
    let item: TurnItem

    var body: some View {
        let text: String = switch item.type {
        case "run_interrupt_request": String(localized: "Stopped by you")
        case "run_interrupt_result": item.text.isEmpty ? String(localized: "Stopped") : item.text
        case "notification": item.raw["summary"]?.string ?? item.text
        case "handoff": String(localized: "Switched to \(item.raw["toModel"]?.string ?? item.raw["toProviderInstanceId"]?.string ?? "another model")")
        default: item.text
        }
        HStack {
            Spacer()
            Text(text)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }
}

/// An image or file attached to a message; images load through a signed asset URL.
struct AttachmentThumbnail: View {
    let attachment: ChatAttachment
    let environment: EnvironmentSession
    @State private var image: UIImage?

    var body: some View {
        Group {
            if attachment.isImage {
                ZStack {
                    Palette.surface
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
            } else {
                Label(attachment.name, systemImage: "doc")
                    .font(Typography.footnote)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Palette.surface, in: .rect(cornerRadius: 12))
            }
        }
        .task(id: attachment.id) {
            guard attachment.isImage, image == nil else { return }
            image = await AttachmentLoader.image(attachment, environment: environment)
        }
    }
}

enum AttachmentLoader {
    @MainActor
    static func image(_ attachment: ChatAttachment, environment: EnvironmentSession) async -> UIImage? {
        guard let result = try? await environment.call("assets.createUrl", [
            "resource": ["_tag": "attachment", "attachmentId": .string(attachment.id),
                         "fileName": .string(attachment.name), "mimeType": .string(attachment.mimeType)],
        ]), let relative = result["relativeUrl"]?.string else { return nil }
        guard let (data, _) = try? await HelmHTTP.session.data(from: environment.http.url(relative)) else { return nil }
        return await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 300, height: 300)) }.value
    }
}

extension EnvironmentValues {
    /// The environment of the thread being shown, for rows that link to related threads.
    @Entry var threadEnvironmentId: String?
}
