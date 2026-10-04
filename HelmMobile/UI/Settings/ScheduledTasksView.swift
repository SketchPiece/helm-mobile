import SwiftUI

/// Settings → Scheduled tasks: every Mac's tasks, live. Tap one to edit it; the menu pauses,
/// runs or deletes it; "+" makes a new one.
struct ScheduledTasksView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Editing?

    /// What the editor sheet opens with.
    struct Editing: Identifiable {
        let id = UUID()
        var environmentId: String
        var draft: ScheduledTaskDraft
    }

    var body: some View {
        Form {
            if model.environments.isEmpty {
                Text("Connect a computer to see and create scheduled tasks.")
                    .foregroundStyle(Palette.textMuted)
            }
            ForEach(model.environments) { environment in
                EnvironmentTasksSection(environment: environment) { task in
                    editing = Editing(environmentId: environment.id, draft: ScheduledTaskDraft(editing: task))
                }
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Scheduled tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newTask()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(!model.environments.contains(where: \.isLive))
                .accessibilityLabel("New task")
                .accessibilityIdentifier("newScheduledTask")
            }
        }
        .sheet(item: $editing) { editing in
            ScheduledTaskEditor(environmentId: editing.environmentId, initial: editing.draft)
        }
    }

    private func newTask() {
        guard let environment = model.environments.first(where: \.isLive) else { return }
        editing = Editing(environmentId: environment.id, draft: ScheduledTaskEditor.newDraft(on: environment))
    }
}

private struct EnvironmentTasksSection: View {
    let environment: EnvironmentSession
    let onEdit: (ScheduledTask) -> Void

    @State private var tasks: [ScheduledTask]?
    @State private var error: String?
    @State private var actionError: String?
    @State private var deleting: ScheduledTask?

    var body: some View {
        Section {
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            } else if let tasks {
                if tasks.isEmpty {
                    Text("No scheduled tasks yet.").foregroundStyle(Palette.textMuted)
                }
                ForEach(tasks) { task in
                    row(task)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(environment.isLive ? "Loading tasks…" : "Waiting for connection…")
                        .foregroundStyle(Palette.textMuted)
                }
            }
        } header: {
            Label(environment.label, systemImage: "laptopcomputer").sectionLabelStyle()
        }
        // Resubscribes whenever the Mac reconnects; the stream ends with the socket.
        .task(id: environment.isLive) { await subscribe() }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .confirmationDialog("Delete this task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { task in
            Button("Delete", role: .destructive) { act { try await environment.deleteScheduledTask(task.id) } }
        } message: { task in
            Text(task.title)
        }
    }

    private func subscribe() async {
        guard environment.isLive else { return }
        do {
            for try await list in try environment.scheduledTasks() {
                tasks = list
                error = nil
            }
        } catch {
            if case RPCError.disconnected = error { return }
            self.error = error.localizedDescription
        }
    }

    private func row(_ task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                onEdit(task)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(Typography.bodyMedium)
                        .foregroundStyle(task.enabled ? Palette.text : Palette.textMuted)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(subtitle(task, now: context.date))
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(2)
                    }
                    if let failure = task.lastRunError {
                        Text("Last run failed: \(failure)")
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.errorText)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scheduledTask")
            Menu {
                Button { onEdit(task) } label: { Label("Edit", systemImage: "pencil") }
                Button {
                    act { try await environment.setScheduledTask(task.id, enabled: !task.enabled) }
                } label: {
                    task.enabled ? Label("Pause", systemImage: "pause") : Label("Resume", systemImage: "play")
                }
                Button {
                    act { try await environment.runScheduledTaskNow(task.id) }
                } label: { Label("Run now", systemImage: "bolt") }
                Divider()
                Button(role: .destructive) { deleting = task } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Actions for \(task.title)")
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = task } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func subtitle(_ task: ScheduledTask, now: Date) -> String {
        let schedule = ScheduledTaskText.describe(task.schedule)
        if !task.enabled { return "\(schedule) · \(String(localized: "Paused"))" }
        if let next = task.nextRunAt { return "\(schedule) · \(ScheduledTaskText.nextRun(next, now: now))" }
        return schedule
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { actionError = error.localizedDescription }
        }
    }
}
