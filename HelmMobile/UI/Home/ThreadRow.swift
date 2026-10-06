import SwiftUI

extension ThreadPhase {
    var label: String? {
        switch self {
        case .approval: String(localized: "Approval")
        case .input: String(localized: "Question")
        case .working: String(localized: "Working")
        case .waiting: String(localized: "Waiting")
        case .failed: String(localized: "Failed")
        case .limited: String(localized: "Limit")
        case .done: String(localized: "Done")
        case .idle: nil
        }
    }

    var color: Color {
        switch self {
        case .approval: Palette.accentText
        case .input: Palette.question
        case .working: Palette.working
        case .waiting: Palette.textMuted
        case .failed: Palette.errorText
        case .limited: Palette.accentText
        case .done: Palette.done
        case .idle: Palette.textMuted
        }
    }
}

extension Palette {
    static let done = dynamic(light: 0x3E7A2E, dark: 0x8FC56A)
    /// GitHub's own pull-request purple.
    static let pullRequest = dynamic(light: 0x8250DF, dark: 0xA371F7)
}

/// GitHub's pull-request octicon, tinted by the foreground style.
struct PullRequestIcon: View {
    var size: CGFloat

    var body: some View {
        Image("PullRequest")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// One thread in the list: project tile with a status lamp, title, one line of context, and
/// the status (or the time) on the right.
struct ThreadRow: View {
    let entry: ThreadListEntry
    let environment: EnvironmentSession?
    var showsProject = true

    var body: some View {
        let thread = entry.thread
        let phase = thread.phase
        let woke = phase == .idle || phase == .done ? thread.isWoke() : false
        let recedes = thread.recedes
        HStack(alignment: .center, spacing: 12) {
            ProjectIcon(project: entry.project, environment: environment, size: 44)
                // Settled history recedes: a grey, faded tile keeps the tail scannable.
                .grayscale(thread.isSettled ? 1 : 0)
                .opacity(thread.isSettled ? 0.5 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if phase != .idle || woke {
                        Circle()
                            .fill(woke ? Palette.accentText : phase.color)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Palette.canvas, lineWidth: 2.5))
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        // Unsent text in this thread's composer: the same pen as the new-thread draft.
                        if DraftIndex.shared.hasDraft(thread.id) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.accentText)
                                .accessibilityLabel(Text("Unsent draft"))
                        }
                        Text(thread.displayTitle)
                            .font(phase == .idle && !woke || recedes ? Typography.body : Typography.bodyMedium)
                            .foregroundStyle(thread.isSettled || recedes ? Palette.textMuted : Palette.text)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    trailing(thread: thread, phase: phase, woke: woke)
                }
                subtitle(thread: thread, phase: phase)
            }
        }
        .padding(.vertical, 8)
        // A running turn fades as a whole row, status included: it takes less attention than rows
        // that need a person.
        .opacity(phase == .working ? 0.7 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(thread: ThreadSummary, phase: ThreadPhase, woke: Bool) -> some View {
        if woke {
            // Back from a snooze in its old place: the label carries the news until it's opened.
            HStack(spacing: 3) {
                Image(systemName: "sun.max")
                Text("Woke")
            }
            .font(Typography.footnote.weight(.medium))
            .foregroundStyle(Palette.accentText)
        } else if let label = phase.label, phase != .done {
            if phase == .working, let since = thread.activityRunStartedAt {
                HStack(spacing: 4) {
                    Text(label)
                    Text(since, style: .timer).monospacedDigit()
                }
                .font(Typography.footnote)
                .foregroundStyle(phase.color)
                .lineLimit(1)
            } else {
                Text(label)
                    .font(Typography.footnote.weight(.medium))
                    .foregroundStyle(phase.color)
            }
        } else if thread.isSnoozed(), let wake = thread.snoozedUntil {
            // A snoozed row shows when it comes back, not when it was last touched.
            Label(Snooze.wakeLabel(until: wake), systemImage: "moon.zzz")
                .labelStyle(.titleAndIcon)
                .font(Typography.footnote)
                .foregroundStyle(Palette.question)
                .monospacedDigit()
                .accessibilityLabel(Text("Wakes \(Snooze.wakeDescription(until: wake))"))
        } else if let date = thread.updatedAt {
            Text(RelativeTime.short(date))
                .font(Typography.footnote)
                .foregroundStyle(phase == .done ? Palette.done : Palette.textMuted)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func subtitle(thread: ThreadSummary, phase: ThreadPhase) -> some View {
        let detail = detailText(thread: thread, phase: phase)
        HStack(spacing: 0) {
            if showsProject {
                Text(entry.project?.title ?? entry.environmentLabel)
                    .foregroundStyle(Palette.textMuted)
                if detail != nil { Text(" · ").foregroundStyle(Palette.placeholder) }
            }
            if let detail {
                Text(detail.text)
                    .font(detail.mono ? Typography.mono(13) : Typography.subheadline)
                    .foregroundStyle(detail.isError ? Palette.errorText : Palette.textMuted)
            }
            Spacer(minLength: 0)
            if let number = thread.pullRequestNumber {
                HStack(spacing: 3) {
                    PullRequestIcon(size: 12)
                    Text("#\(number)")
                }
                .font(Typography.mono(12))
                .foregroundStyle(Palette.pullRequest)
                .padding(.leading, 6)
            }
        }
        .font(Typography.subheadline)
        .lineLimit(1)
    }

    private func detailText(thread: ThreadSummary, phase: ThreadPhase) -> (text: String, mono: Bool, isError: Bool)? {
        if phase == .failed || phase == .limited, let error = thread.lastError {
            return (error, false, true)
        }
        if phase == .waiting, let title = thread.backgroundTasks.title {
            return (title, false, false)
        }
        if let text = thread.latestMessageText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return (text.replacingOccurrences(of: "\n", with: " "), false, false)
        }
        if let branch = thread.branch { return (branch, true, false) }
        return nil
    }
}

/// The unsent new thread on top of Home, laid out like a thread row: its project, the first line,
/// and "Draft" where the time goes.
struct DraftRow: View {
    let draft: NewThreadDraft
    let project: Project?
    let environment: EnvironmentSession?
    var showsProject = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProjectIcon(project: project, environment: environment, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draft.title.isEmpty ? String(localized: "New thread") : draft.title)
                        .font(Typography.body)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Draft")
                        .font(Typography.footnote.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                }
                subtitle
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// The project, then whatever follows the first line.
    @ViewBuilder
    private var subtitle: some View {
        let rest = draft.remainder
        let projectTitle = showsProject ? (project?.title ?? environment?.label) : nil
        if projectTitle != nil || !rest.isEmpty {
            HStack(spacing: 0) {
                if let projectTitle {
                    Text(projectTitle).foregroundStyle(Palette.textMuted)
                    if !rest.isEmpty { Text(" · ").foregroundStyle(Palette.placeholder) }
                }
                if !rest.isEmpty {
                    Text(rest).foregroundStyle(Palette.textMuted)
                }
                Spacer(minLength: 0)
            }
            .font(Typography.subheadline)
            .lineLimit(1)
        }
    }
}

enum RelativeTime {
    /// "now", "5m", "3h", "2d", then a short date.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60))m") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3600))h") }
        if seconds < 7 * 86_400 { return String(localized: "\(Int(seconds / 86_400))d") }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
