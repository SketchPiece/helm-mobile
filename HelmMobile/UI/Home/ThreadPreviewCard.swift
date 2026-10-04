import SwiftUI

/// What a long press on a thread row shows above its menu, like the desktop's hover card:
/// where it runs, which model, what it is doing, and the latest message.
struct ThreadPreviewCard: View {
    let entry: ThreadListEntry
    let environment: EnvironmentSession?
    var showsComputer = false

    var body: some View {
        let thread = entry.thread
        let phase = thread.phase
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProjectIcon(project: entry.project, environment: environment, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.displayTitle)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                    Text(location)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                if let label = statusLabel(thread: thread, phase: phase) {
                    detail(symbol: "circle.fill", tint: label.color) {
                        Text(label.text).foregroundStyle(label.color)
                    }
                }
                if let branch = thread.branch {
                    detail(symbol: thread.worktreePath == nil ? "arrow.triangle.branch" : "square.stack.3d.up") {
                        Text(branch).font(Typography.mono(13)).lineLimit(1).truncationMode(.middle)
                        if thread.worktreePath != nil {
                            Text("worktree").foregroundStyle(Palette.textMuted)
                        }
                    }
                }
                if let selection = thread.modelSelection {
                    let provider = environment?.config?.provider(selection.instanceId)
                    HStack(spacing: 8) {
                        ProviderIcon(driver: provider?.driver, iconUrl: provider?.iconUrl, size: 13)
                            .frame(width: 16)
                        Text(environment?.config?.modelLabel(for: selection) ?? selection.model)
                        if thread.interactionMode == "plan" {
                            Text("· Plan").foregroundStyle(Palette.textMuted)
                        }
                    }
                }
                if let number = thread.pullRequestNumber {
                    detail(symbol: "arrow.triangle.pull", tint: Palette.question) {
                        Text("#\(number)").font(Typography.mono(13))
                        if let state = thread.pullRequestState {
                            Text(ComposerSuggestions.stateLabel(state.lowercased())).foregroundStyle(Palette.textMuted)
                        }
                    }
                }
                if let tasks = thread.backgroundTasks.title {
                    detail(symbol: "hourglass") { Text(tasks).lineLimit(2) }
                }
                if let error = thread.lastError, phase == .failed || phase == .limited {
                    detail(symbol: "exclamationmark.triangle", tint: Palette.errorText) {
                        Text(error).foregroundStyle(Palette.errorText).lineLimit(3)
                    }
                }
            }
            .font(Typography.footnote)
            .foregroundStyle(Palette.text)

            if let text = latestMessage {
                Text(text)
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .lineLimit(5)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(Palette.canvas)
    }

    private var location: String {
        var parts = [entry.project?.title ?? entry.environmentLabel]
        if showsComputer { parts.append(entry.environmentLabel) }
        if let updated = entry.thread.updatedAt {
            parts.append(updated.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private var latestMessage: String? {
        guard let text = entry.thread.latestMessageText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return ClipboardText.plain(text)
    }

    private func statusLabel(thread: ThreadSummary, phase: ThreadPhase) -> (text: String, color: Color)? {
        if thread.isSnoozed(), let wake = thread.snoozedUntil {
            return (String(localized: "Snoozed until \(Snooze.wakeDescription(until: wake))"), Palette.question)
        }
        if phase == .idle || phase == .done, thread.isWoke() { return (String(localized: "Woke"), Palette.accentText) }
        if thread.isSettled { return (String(localized: "Thread settled"), Palette.textMuted) }
        guard let label = phase.label else { return nil }
        return (label, phase.color)
    }

    private func detail<Content: View>(symbol: String, tint: Color = Palette.textMuted,
                                       @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "circle.fill" ? 7 : 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            content()
        }
    }
}
