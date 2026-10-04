import SwiftUI

/// Create or edit a scheduled task: name and prompt, project and model, where it runs, and
/// when. Saves with `scheduledTasks.upsert`; leaving with unsaved changes asks first.
struct ScheduledTaskEditor: View {
    let initial: ScheduledTaskDraft

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var environmentId: String
    @State private var draft: ScheduledTaskDraft
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var showBranches = false

    init(environmentId: String, initial: ScheduledTaskDraft) {
        self.initial = initial
        _environmentId = State(initialValue: environmentId)
        _draft = State(initialValue: initial)
    }

    /// A new task's defaults: the most recently active project and its default model.
    static func newDraft(on environment: EnvironmentSession) -> ScheduledTaskDraft {
        let project = environment.shell.projects.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        return ScheduledTaskDraft(projectId: project?.id, modelSelection: environment.config?.initialSelection(project: project))
    }

    private var environment: EnvironmentSession? { model.environment(environmentId) }
    private var config: ServerConfig? { environment?.config }
    private var projects: [Project] {
        (environment?.shell.projects.values.map { $0 } ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    private var project: Project? { environment?.project(draft.projectId) }
    private var hasChanges: Bool { draft != initial }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                    }
                }
                if draft.task == nil, model.environments.count > 1 {
                    Section {
                        Picker("Runs on", selection: $environmentId) {
                            ForEach(model.environments) { Text($0.label).tag($0.id) }
                        }
                    }
                }
                taskSection
                contextSection
                workspaceSection
                scheduleSection
                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            if saving { ProgressView().tint(Palette.accentForeground) } else {
                                Text(draft.task == nil ? "Create task" : "Save changes").font(Typography.headline)
                            }
                            Spacer()
                        }
                        .frame(height: 44)
                        .foregroundStyle(Palette.accentForeground)
                        .background(Palette.accent, in: .rect(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || environment?.isLive != true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("saveScheduledTask")
                }
            }
            .font(Typography.body)
            .tint(Palette.text)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.canvas)
            .navigationTitle(draft.task == nil ? "New scheduled task" : "Edit scheduled task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your unsaved changes will be lost.")
            }
            .sheet(isPresented: $showBranches) {
                if let environment, let project {
                    BranchPicker(environment: environment, cwd: project.workspaceRoot, selected: draft.baseRef,
                                 showsOriginToggle: true, startFromOrigin: $draft.startFromOrigin) { draft.baseRef = $0 }
                }
            }
        }
        .interactiveDismissDisabled(hasChanges || saving)
        .onChange(of: environmentId) { _, _ in
            // Projects and models belong to the Mac; keep only what the user wrote.
            guard let environment else { return }
            var next = Self.newDraft(on: environment)
            next.title = draft.title
            next.prompt = draft.prompt
            next.scheduleMode = draft.scheduleMode
            next.timeOfDay = draft.timeOfDay
            next.weekdays = draft.weekdays
            next.intervalMinutes = draft.intervalMinutes
            next.enabled = draft.enabled
            draft = next
        }
    }

    // MARK: Sections

    private var taskSection: some View {
        Section {
            TextField("Name", text: $draft.title, prompt: Text("Check for issues"))
                .accessibilityIdentifier("taskName")
            TextField("Prompt", text: $draft.prompt, prompt: Text("What should the agent do each time?"), axis: .vertical)
                .lineLimit(3...10)
                .accessibilityIdentifier("taskPrompt")
        } header: {
            Text("Task").sectionLabelStyle()
        }
    }

    private var contextSection: some View {
        Section {
            Picker("Project", selection: Binding(
                get: { draft.projectId ?? "" },
                set: { id in
                    draft.projectId = id
                    if !draft.modelSelectionIsExplicit {
                        draft.modelSelection = config?.initialSelection(project: environment?.project(id))
                    }
                }
            )) {
                if draft.projectId == nil { Text("Choose project").tag("") }
                ForEach(projects) { Text($0.title).tag($0.id) }
            }
            NavigationLink {
                modelForm
            } label: {
                HStack {
                    Text("Model")
                    Spacer()
                    Text(config?.modelLabel(for: draft.modelSelection) ?? String(localized: "Choose model"))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            .disabled(config == nil)
        } header: {
            Text("Context").sectionLabelStyle()
        }
    }

    private var modelForm: some View {
        Form {
            if let config {
                ModelSettingsSections(
                    config: config, selection: draft.modelSelection, runtimeMode: draft.runtimeMode,
                    interactionMode: draft.interactionMode,
                    onSelection: {
                        draft.modelSelection = $0
                        draft.modelSelectionIsExplicit = true
                    },
                    onRuntimeMode: { draft.runtimeMode = $0 },
                    onInteractionMode: { draft.interactionMode = $0 }
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Model and access")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var workspaceSection: some View {
        Section {
            Picker("Run in", selection: $draft.workspace) {
                ForEach(ScheduledTaskDraft.WorkspaceMode.allCases) { Text($0.title).tag($0) }
            }
            switch draft.workspace {
            case .worktree:
                Button {
                    showBranches = true
                } label: {
                    HStack {
                        Text("Base branch").foregroundStyle(Palette.text)
                        Spacer()
                        Text(draft.startFromOrigin ? "From origin/\(draft.baseRef)" : "From \(draft.baseRef)")
                            .font(Typography.mono(14))
                            .foregroundStyle(Palette.textMuted)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.placeholder)
                    }
                }
                .disabled(project == nil || environment?.isLive != true)
            case .existingWorktree:
                TextField("Checkout path", text: $draft.checkoutPath, prompt: Text(verbatim: "/Users/…/worktree"))
                    .font(Typography.mono(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .root:
                EmptyView()
            }
        } header: {
            Text("Workspace").sectionLabelStyle()
        }
    }

    private var scheduleSection: some View {
        Section {
            Picker("Schedule", selection: $draft.scheduleMode) {
                Text("At a time").tag(ScheduledTaskDraft.ScheduleMode.fixedTime)
                Text("Every interval").tag(ScheduledTaskDraft.ScheduleMode.interval)
            }
            .pickerStyle(.segmented)
            if draft.scheduleMode == .fixedTime {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Repeat")
                        Spacer()
                        Text(ScheduledTaskText.repeatLabel(draft.weekdays)).foregroundStyle(Palette.textMuted)
                    }
                    WeekdayChips(selection: $draft.weekdays)
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    Text("Minutes between runs")
                    Spacer()
                    TextField("15", text: $draft.intervalMinutes)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                }
                if (Double(draft.intervalMinutes.replacingOccurrences(of: ",", with: ".")) ?? 0) < 1 {
                    Text("Intervals must be at least 1 minute.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }
            Toggle("Enabled", isOn: $draft.enabled)
                .tint(Palette.accent)
                .accessibilityIdentifier("taskEnabled")
        } header: {
            Text("Schedule").sectionLabelStyle()
        } footer: {
            if draft.scheduleMode == .fixedTime {
                Text("Time uses the Mac's time zone, which may differ from your phone's.").font(Typography.footnote)
            }
        }
    }

    /// "HH:MM" ↔ the time picker.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let parts = draft.timeOfDay.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.dropFirst().first ?? 0, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.timeOfDay = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
            }
        )
    }

    // MARK: Save

    private func save() {
        guard let environment, !saving else { return }
        let payload: JSON
        do {
            payload = try draft.upsertPayload(knownProjectIds: Set(environment.shell.projects.keys))
        } catch .incomplete {
            error = String(localized: "Add a name, prompt, project, model, a valid schedule, and the checkout path if needed.")
            return
        } catch {
            self.error = String(localized: "Choose a project on this Mac.")
            return
        }
        saving = true
        error = nil
        Task {
            do {
                try await environment.upsertScheduledTask(payload)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// Seven toggles, Monday first, for the days a fixed-time task runs.
private struct WeekdayChips: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ScheduledTaskText.weekdayOrder, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(ScheduledTaskText.weekdayShort(day))
                        .font(Typography.footnote.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .foregroundStyle(on ? Palette.canvas : Palette.textMuted)
                        .background(on ? Palette.text : Palette.canvas, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
