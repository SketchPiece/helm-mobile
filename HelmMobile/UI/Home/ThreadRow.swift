import SwiftUI

extension ThreadPhase {
    var label: String? {
        switch self {
        case .approval: String(localized: "Approval")
        case .input: String(localized: "Question")
        case .working: String(localized: "Working")
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
        case .failed: Palette.errorText
        case .limited: Palette.accentText
        case .done: Palette.done
        case .idle: Palette.textMuted
        }
    }
}

extension Palette {
    static let done = dynamic(light: 0x3E7A2E, dark: 0x8FC56A)
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
        HStack(alignment: .top, spacing: 12) {
            ProjectIcon(project: entry.project, environment: environment, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    if phase != .idle {
                        Circle()
                            .fill(phase.color)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Palette.canvas, lineWidth: 2.5))
                            .offset(x: 3, y: 3)
                    }
                }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(thread.displayTitle)
                        .font(phase == .idle ? Typography.body : Typography.bodyMedium)
                        .foregroundStyle(thread.isSettled ? Palette.textMuted : Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing(thread: thread, phase: phase)
                }
                subtitle(thread: thread, phase: phase)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func trailing(thread: ThreadSummary, phase: ThreadPhase) -> some View {
        if let label = phase.label, phase != .done {
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
        } else if let date = thread.updatedAt {
            Text(RelativeTime.short(date))
                .font(Typography.footnote)
                .foregroundStyle(phase == .done ? Palette.done : Palette.textMuted)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func subtitle(thread: ThreadSummary, phase: ThreadPhase) -> some View {
        HStack(spacing: 0) {
            if showsProject {
                Text(entry.project?.title ?? entry.environmentLabel)
                    .foregroundStyle(Palette.textMuted)
                Text(" · ").foregroundStyle(Palette.placeholder)
            }
            if (phase == .failed || phase == .limited), let error = thread.lastError {
                Text(error).foregroundStyle(Palette.errorText)
            } else if let text = thread.latestMessageText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text.replacingOccurrences(of: "\n", with: " ")).foregroundStyle(Palette.textMuted)
            } else if let branch = thread.branch {
                Text(branch).font(Typography.mono(13)).foregroundStyle(Palette.textMuted)
            }
            Spacer(minLength: 0)
            if let number = thread.pullRequestNumber {
                Label("#\(number)", systemImage: "arrow.triangle.pull")
                    .labelStyle(.titleAndIcon)
                    .font(Typography.mono(12))
                    .foregroundStyle(Palette.question)
                    .padding(.leading, 6)
            }
        }
        .font(Typography.subheadline)
        .lineLimit(1)
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
