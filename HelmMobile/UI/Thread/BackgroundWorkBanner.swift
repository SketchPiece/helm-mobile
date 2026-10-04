import SwiftUI

/// Above the composer once the turn has ended but the thread still has work running: subagents
/// it waits on, background commands, monitors. Names them, opens a subagent's thread, and stops
/// them (the composer's stop button is gone by now, so this is the only way to).
struct BackgroundWorkBanner: View {
    let tasks: [BackgroundTask]
    let environmentId: String
    let stop: () async throws -> Void
    @Environment(Router.self) private var router
    @State private var stopping = false
    @State private var error: String?

    private static let listLimit = 4

    /// A single item without a thread to open is already named in the title.
    private var listed: [BackgroundTask] {
        if tasks.count == 1, tasks[0].childThreadId == nil { return [] }
        return tasks.sorted { $0.kind < $1.kind }
    }

    var body: some View {
        // Only work that will wake the agent pulses; a dev server can run for hours after it's done.
        let waiting = tasks.holdsCompletion
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(waiting ? Palette.working : Palette.textMuted)
                    .symbolEffect(.pulse, isActive: waiting)
                    .accessibilityHidden(true)
                Text(tasks.title ?? "")
                    .font(Typography.subheadline.weight(.medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button { stopAll() } label: {
                    Group {
                        if stopping { ProgressView().controlSize(.mini) } else { Text("Stop") }
                    }
                    .font(Typography.footnote.weight(.medium))
                    .frame(minWidth: 36)
                }
                .buttonStyle(.glass)
                .disabled(stopping)
                .accessibilityLabel("Stop background work")
            }
            if !listed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(listed.prefix(Self.listLimit)) { task in
                        row(task)
                    }
                    if listed.count > Self.listLimit {
                        Text("+\(listed.count - Self.listLimit) more")
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textMuted)
                            .padding(.leading, 17)
                    }
                }
            }
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface(cornerRadius: 18)
        .accessibilityIdentifier("backgroundWork")
    }

    @ViewBuilder
    private func row(_ task: BackgroundTask) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: icon(task.kind))
                .font(.system(size: 11, weight: .medium))
                .frame(width: 11)
            Text(task.name ?? noun(task.kind))
                .font(task.kind == .command ? Typography.mono(12) : Typography.footnote)
                .lineLimit(1)
            if task.childThreadId != nil {
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
        }
        if let child = task.childThreadId {
            Button {
                router.push(ThreadRef(environmentId: environmentId, threadId: child))
            } label: {
                label.foregroundStyle(Palette.accentText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open subagent \(task.name ?? noun(task.kind))")
        } else {
            label.foregroundStyle(Palette.textMuted)
        }
    }

    private func icon(_ kind: BackgroundTask.Kind) -> String {
        switch kind {
        case .subagent: "person.2"
        case .command: "terminal"
        case .monitor: "eye"
        case .backgroundTask: "gearshape"
        }
    }

    private func noun(_ kind: BackgroundTask.Kind) -> String {
        switch kind {
        case .subagent: String(localized: "Subagent")
        case .command: String(localized: "Command")
        case .monitor: String(localized: "Monitor")
        case .backgroundTask: String(localized: "Background task")
        }
    }

    private func stopAll() {
        stopping = true
        error = nil
        Task {
            do {
                try await stop()
            } catch {
                self.error = error.localizedDescription
            }
            // Acceptance doesn't mean the work has stopped; the banner goes when the server says so.
            stopping = false
        }
    }
}
