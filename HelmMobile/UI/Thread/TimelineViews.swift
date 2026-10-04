import SwiftUI

/// The user's message: a bubble on the right, attachments above the text.
struct UserBubble: View {
    let item: TurnItem
    let environment: EnvironmentSession
    @State private var viewing: ChatAttachment?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            let attachments = item.attachments
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { attachment in
                        if attachment.isImage {
                            Button {
                                viewing = attachment
                            } label: {
                                AttachmentThumbnail(attachment: attachment, environment: environment)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Open \(attachment.name)"))
                            .accessibilityIdentifier("attachmentImage")
                        } else {
                            AttachmentThumbnail(attachment: attachment, environment: environment)
                        }
                    }
                }
                .fullScreenCover(item: $viewing) { attachment in
                    ImageViewer(attachments: attachments.filter(\.isImage), environment: environment,
                                selection: attachment.id)
                }
            }
            if !item.text.isEmpty {
                Text(ContextReference.displayText(item.text))
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Palette.message, in: .rect(cornerRadius: 20, style: .continuous))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = ClipboardText.markdown(item.text, context: item.raw["context"])
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
            }
            let steered = item.inputIntent == "steer" || item.inputIntent == "promoted_queued_to_steer"
            let sentAt = item.startedAt ?? item.completedAt
            if steered || sentAt != nil {
                HStack(spacing: 6) {
                    if steered {
                        Label("Steered", systemImage: "arrow.turn.down.right")
                        if sentAt != nil { Text(verbatim: "·") }
                    }
                    if let sentAt {
                        Text(sentAt, format: .dateTime.hour().minute())
                            .monospacedDigit()
                    }
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textMuted)
                .padding(.trailing, 6)
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
            Text(ContextReference.displayText(message.text))
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

/// Something that happened to the conversation itself, drawn as a divider across the timeline:
/// a stop, a model switch, a compaction, a fork.
struct NoticeRow: View {
    let item: TurnItem
    /// The thread on screen; a fork that points at it is where this thread began.
    let threadId: String
    @Environment(Router.self) private var router
    @Environment(\.threadEnvironmentId) private var environmentId
    @Environment(AppModel.self) private var model

    var body: some View {
        let notice = presentation
        if let target = notice.opens, let environmentId {
            Button {
                router.push(ThreadRef(environmentId: environmentId, threadId: target))
            } label: {
                TimelineDivider(symbol: notice.symbol, label: notice.label, detail: notice.detail,
                                isRunning: item.isRunning, opens: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the thread"))
        } else {
            TimelineDivider(symbol: notice.symbol, label: notice.label, detail: notice.detail, isRunning: item.isRunning)
        }
    }

    private var presentation: (symbol: String, label: String, detail: String?, opens: String?) {
        let raw = item.raw
        switch item.type {
        case "run_interrupt_request":
            return ("hand.raised", String(localized: "Stopped by you"), nonEmpty(raw["message"]?.string), nil)
        case "run_interrupt_result":
            return ("stop.circle", String(localized: "Stopped"), nonEmpty(item.text), nil)
        case "notification":
            return ("bell", raw["summary"]?.string ?? item.text, nil, nil)
        case "handoff":
            let model = raw["toModel"]?.string ?? raw["toProviderInstanceId"]?.string ?? String(localized: "another model")
            return ("bolt", String(localized: "Switched to \(model)"), nonEmpty(raw["summary"]?.string), nil)
        case "compaction":
            if item.isRunning { return ("arrow.down.right.and.arrow.up.left", String(localized: "Compacting context"), nil, nil) }
            let before = raw["beforeTokenCount"]?.int, after = raw["afterTokenCount"]?.int
            let tokens = before != nil || after != nil
                ? String(localized: "\(TokenCount.short(before)) → \(TokenCount.short(after)) tokens") : nil
            let failed = item.status == "failed"
            return ("arrow.down.right.and.arrow.up.left",
                    failed ? String(localized: "Couldn't compact the context") : String(localized: "Context compacted"), tokens, nil)
        case "fork":
            guard let target = raw["targetThreadId"]?.string, target != threadId else {
                return ("arrow.triangle.branch", String(localized: "Forked here"), nil, nil)
            }
            let title = environmentId.flatMap { model.environment($0)?.thread(target)?.displayTitle }
            return ("arrow.triangle.branch", String(localized: "Forked"), title.map { String(localized: "continues in \($0)") }, target)
        default:
            return ("info.circle", item.text.isEmpty ? (item.title ?? item.type.replacingOccurrences(of: "_", with: " ")) : item.text, nil, nil)
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// A hairline across the timeline with a short label in the middle.
struct TimelineDivider: View {
    var symbol: String?
    let label: String
    var detail: String?
    var isRunning = false
    var opens = false

    var body: some View {
        HStack(spacing: 10) {
            line
            HStack(spacing: 5) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(label).fontWeight(.medium)
                if let detail {
                    Text(verbatim: "·")
                    Text(detail).lineLimit(1)
                }
                if opens {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
            }
            .font(Typography.caption)
            .foregroundStyle(Palette.textMuted)
            .layoutPriority(1)
            line
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle().fill(Palette.border).frame(height: 1).frame(minWidth: 16)
    }
}

enum TokenCount {
    /// "850", "12k", "1.2M".
    static func short(_ count: Int?) -> String {
        guard let count else { return "?" }
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 {
            let thousands = Double(count) / 1000
            return thousands < 10 ? String(format: "%.1fk", thousands).replacingOccurrences(of: ".0k", with: "k") : "\(Int(thousands.rounded()))k"
        }
        return String(format: "%.1fM", Double(count) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
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
    /// Thumbnails and full images already fetched this session, so scrolling back and reopening
    /// the viewer don't download them again.
    @MainActor private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    @MainActor
    static func image(_ attachment: ChatAttachment, environment: EnvironmentSession) async -> UIImage? {
        let key = "thumb:\(attachment.id)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = await data(attachment, environment: environment) else { return nil }
        let image = await Task.detached { UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 300, height: 300)) }.value
        if let image { cache.setObject(image, forKey: key, cost: 300 * 300 * 4) }
        return image
    }

    /// The image at full size, decoded off the main thread, for the viewer.
    @MainActor
    static func fullImage(_ attachment: ChatAttachment, environment: EnvironmentSession) async -> UIImage? {
        let key = "full:\(attachment.id)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = await data(attachment, environment: environment) else { return nil }
        let image = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }

    @MainActor
    private static func data(_ attachment: ChatAttachment, environment: EnvironmentSession) async -> Data? {
        guard let result = try? await environment.call("assets.createUrl", [
            "resource": ["_tag": "attachment", "attachmentId": .string(attachment.id),
                         "fileName": .string(attachment.name), "mimeType": .string(attachment.mimeType)],
        ]), let relative = result["relativeUrl"]?.string else { return nil }
        return try? await HelmHTTP.session.data(from: environment.http.url(relative)).0
    }
}

extension EnvironmentValues {
    /// The environment of the thread being shown, for rows that link to related threads.
    @Entry var threadEnvironmentId: String?
}

/// "Worked for 3m 12s": a finished turn's steps, folded away; tap to see them.
struct FoldRow: View {
    let label: String
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 13)
                Text(label)
                Rectangle().fill(Palette.border).frame(height: 1)
            }
            .font(Typography.subheadline)
            .foregroundStyle(Palette.textMuted)
            .contentShape(.rect)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("runFold")
    }
}
