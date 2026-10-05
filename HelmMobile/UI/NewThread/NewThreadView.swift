import SwiftUI

/// Start a thread: pick a project (most recent preselected), write the task, send. Model, access
/// and workspace are one tap away but never in the way. It pushes like a thread: going back with
/// nothing written cancels it, anything written stays as a draft on Home.
struct NewThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var environmentId: String?
    @State private var projectId: String?
    @State private var text = Drafts.text(for: NewThreadDraft.key)
    @State private var selection: ModelSelection?
    @State private var runtimeMode = "full-access"
    @State private var interactionMode = "default"
    @State private var newWorktree = false
    @State private var startFromOrigin = true
    @State private var showBranches = false
    @State private var repo: RefPage?
    @State private var baseBranch: String?
    @State private var suggestions = ComposerSuggestions()
    @State private var showProjects = false
    @State private var showSettings = false
    @State private var sending = false
    @State private var error: String?
    @State private var focused = false
    @State private var voice = VoiceInput()
    @State private var micDrag: CGFloat = 0
    /// "No project" was picked from the long press and its scratch folder is being set up on the Mac.
    @State private var preparingScratch = false
    /// Shared files waiting for the Mac to be connected before they upload.
    @State private var sharedFiles: [SharedFile] = []
    @AppStorage(PhonePreferences.returnKeyKey) private var returnKey = ReturnKeyBehavior.newline

    private var draft: ComposerDraft { router.newThreadComposer }

    private var environment: EnvironmentSession? {
        environmentId.flatMap { model.environment($0) } ?? model.environments.first(where: \.isLive) ?? model.environments.first
    }
    private var project: Project? { environment?.project(projectId) }
    /// The Mac is connected and its config and projects are in.
    private var isReady: Bool {
        environment.map { $0.isLive && $0.config != nil && !$0.shell.projects.isEmpty } ?? false
    }
    /// "No project" threads run in the scratch folder, always in place.
    private var isScratch: Bool { project.map { environment?.config?.isScratch($0) == true } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            header
            Spacer(minLength: 24)
            if let error {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.errorText)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            if focused && suggestions.isVisible {
                SuggestionPanel(suggestions: suggestions, onPick: pick)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
            composer
        }
        .animation(.easeOut(duration: 0.15), value: focused && suggestions.isVisible)
        // Under the keyboard too: as it slides away the window would show white in the light theme.
        .background { Palette.canvas.ignoresSafeArea() }
        .navigationTitle("New thread")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showProjects) {
            ProjectPicker(selectedEnvironment: environment?.id, selectedProject: projectId) { environment, project in
                environmentId = environment.id
                projectId = project.id
                showProjects = false
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    if let config = environment?.config {
                        ModelSettingsSections(
                            config: config, selection: selection, runtimeMode: runtimeMode,
                            interactionMode: interactionMode,
                            onSelection: { selection = $0 },
                            onRuntimeMode: { runtimeMode = $0 },
                            onInteractionMode: { interactionMode = $0 }
                        )
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Palette.canvas)
                .navigationTitle("Model and access")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { showSettings = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            takeTarget()
            restoreProject()
            pickDefaults()
            takeSeed()
        }
        .onDisappear(perform: leave)
        .onChange(of: router.newThreadSeed) { takeSeed() }
        // Opened from a quick action or share on a cold start: the Mac connects after this appears.
        .onChange(of: isReady) {
            // The draft's project may be gone from the Mac by now.
            if isReady, project == nil { projectId = nil }
            if projectId == nil || selection == nil { pickDefaults() }
            attachSharedFiles()
        }
        .onChange(of: projectId) { _, _ in
            resetForProject()
            NewThreadDraft.saveProject(environmentId: environmentId, projectId: projectId)
        }
        // Uploads belong to the Mac they went to.
        .onChange(of: environmentId) { old, _ in if old != nil { draft.reset() } }
        .task(id: "\(environment?.id ?? "")|\(project?.workspaceRoot ?? "")") { await loadBranches() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 14) {
            Button {
                showProjects = true
            } label: {
                VStack(spacing: 6) {
                    Text(isScratch ? "What are we doing" : "What are we doing in")
                        .foregroundStyle(Palette.text)
                    HStack(spacing: 8) {
                        if let project, !isScratch {
                            ProjectIcon(project: project, environment: environment, size: 26)
                        }
                        Text(projectQuestion)
                            .underline(color: Palette.placeholder)
                            .foregroundStyle(Palette.text)
                    }
                }
                .font(Typography.sans(24, .medium, relativeTo: .title2))
                .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("projectPicker")
            if model.environments.count > 1, let environment {
                Menu {
                    ForEach(model.environments) { option in
                        Button(option.label) {
                            environmentId = option.id
                            projectId = nil
                            pickDefaults()
                        }
                    }
                } label: {
                    Label("on \(environment.label)", systemImage: "laptopcomputer")
                        .font(Typography.subheadline)
                        .foregroundStyle(Palette.textMuted)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Palette.surface, in: .capsule)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private var projectQuestion: String {
        if isScratch { return String(localized: "without a project?") }
        return project.map { "\($0.title)?" } ?? String(localized: "which project?")
    }

    /// The card's top row: where the agent works. A new worktree is tinted, since it is the choice to
    /// notice before starting.
    private var whereRow: some View {
        HStack(spacing: 6) {
            Menu {
                // Toggles: the menu marks the choice itself and each row keeps the chip's icon.
                Toggle(isOn: Binding(get: { !newWorktree }, set: { if $0 { newWorktree = false } })) {
                    Image(systemName: "folder")
                    Text("Current checkout")
                    Text("Works in the project folder")
                }
                Toggle(isOn: Binding(get: { newWorktree }, set: { if $0 { newWorktree = true } })) {
                    Image(systemName: "arrow.triangle.branch")
                    Text("New worktree")
                    Text("Its own folder and branch")
                }
            } label: {
                ComposerChipLabel(title: newWorktree ? String(localized: "New worktree") : String(localized: "Current checkout"),
                                  highlighted: newWorktree) {
                    Image(systemName: newWorktree ? "arrow.triangle.branch" : "folder").font(.system(size: 13))
                }
            }
            .buttonStyle(.plain)
            if newWorktree, repo?.isRepo == true {
                Button {
                    showBranches = true
                } label: {
                    let base = baseBranch ?? "main"
                    ComposerChipLabel(title: originAvailable && startFromOrigin ? "from origin/\(base)" : "from \(base)",
                                      mono: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("baseBranch")
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.text.opacity(0.07)).frame(height: 1)
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $showBranches) {
            if let environment, let project {
                BranchPicker(
                    environment: environment, cwd: project.workspaceRoot, selected: baseBranch,
                    showsOriginToggle: originAvailable, startFromOrigin: $startFromOrigin
                ) { baseBranch = $0 }
            }
        }
    }

    /// "Start from origin" only means something when the repository has an origin.
    private var originAvailable: Bool { repo?.hasPrimaryRemote == true }

    /// The thread's composer card, opened, with one more row on top: where the agent works.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isScratch && project != nil {
                whereRow
            }
            if !draft.attachments.isEmpty || draft.notice != nil {
                AttachmentStrip(draft: draft, environment: environment)
            }
            if voice.state != .idle {
                VoiceStrip(voice: voice, dragOffset: micDrag, onCancel: { voice.cancel(); voice.dismissError() },
                           onDone: { finishDictation(send: false) }, onRetry: retryDictation)
            } else {
                ComposerTextView(text: $text, isFocused: $focused, placeholder: String(localized: "Ask anything…"),
                                 maxLines: 10, accessibilityIdentifier: "newThreadText", returnKey: returnKey,
                                 onSubmit: { _ in if canSend && !sending { launch() } }) { images in
                    guard let environment else { return }
                    images.forEach { draft.attach(image: $0, environment: environment) }
                }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 6)
                    .onChange(of: text) { old, value in
                        if let folded = draft.foldPaste(old: old, new: value, environment: environment) {
                            text = folded
                            return
                        }
                        Drafts.save(value, for: NewThreadDraft.key)
                        suggestions.update(text: value, scope: suggestionScope)
                    }
            }
            HStack(spacing: 6) {
                AttachMenu(draft: draft, environment: environment, size: 34) {
                    if let environment, let pasted = draft.paste(environment: environment, draftLength: text.utf16.count) {
                        text += pasted
                    }
                    focused = true
                }
                ComposerSettingsChips(
                    config: environment?.config, selection: selection, runtimeMode: runtimeMode,
                    interactionMode: interactionMode,
                    onSelection: { selection = $0 },
                    onRuntimeMode: { runtimeMode = $0 },
                    onInteractionMode: { interactionMode = $0 },
                    onMore: { showSettings = true }
                )
                .layoutPriority(1)
                Spacer(minLength: 0)
                trailingButton
            }
        }
        .padding(6)
        .contentShape(.rect)
        .onTapGesture { if voice.state == .idle { focused = true } }
        .composerGlass()
        .animation(.composer, value: voice.state)
        .animation(.composer, value: hasContent)
        .animation(.composer, value: newWorktree)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { focused = true }
        .onDisappear { if voice.isRecording { voice.cancel() } }
    }

    /// Empty field: the amber microphone (hold to dictate and start, tap for hands-free). With text:
    /// start takes the amber slot and the microphone waits beside it.
    @ViewBuilder
    private var trailingButton: some View {
        let holdRecording = voice.state == .recording(handsFree: false)
        if voice.state == .idle || holdRecording {
            MicButton(
                voice: voice,
                onHoldStart: { Task { await voice.start(handsFree: false) } },
                onHoldEnd: { cancelled in
                    if cancelled { voice.cancel() } else { finishDictation(send: true) }
                },
                onTap: {
                    focused = false
                    Task { await voice.start(handsFree: true) }
                },
                dragOffset: $micDrag,
                prominent: !(hasContent || sending)
            )
        }
        if (hasContent || sending) && !holdRecording {
            Button(action: launch) {
                Group {
                    if sending { ProgressView().tint(Palette.accentForeground) } else {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                    }
                }
                .frame(width: 40, height: 40)
                .foregroundStyle(canSend ? Palette.accentForeground : Palette.placeholder)
                .background(canSend ? Palette.accent : Palette.border, in: .circle)
            }
            .disabled(!canSend || sending)
            .accessibilityLabel("Start thread")
            .accessibilityIdentifier("startThread")
        }
    }

    private func finishDictation(send: Bool) {
        guard let environment else { return }
        Task {
            guard let dictated = await voice.finish(environment: environment, threadId: nil) else { return }
            insert(dictated, thenSend: send)
        }
    }

    private func retryDictation() {
        guard let environment else { return }
        Task {
            guard let dictated = await voice.retry(environment: environment, threadId: nil) else { return }
            insert(dictated, thenSend: false)
        }
    }

    private func insert(_ dictated: String, thenSend: Bool) {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = current.isEmpty ? dictated : "\(current) \(dictated)"
        if thenSend && canSend && !sending {
            launch()
        } else {
            focused = true
        }
    }

    /// Something typed or attached, so the button is Start rather than the microphone.
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.hasUploaded) && project != nil
            && selection != nil && environment?.isLive == true && !draft.isUploading
    }

    private var suggestionScope: ComposerSuggestions.Scope? {
        guard let environment else { return nil }
        return ComposerSuggestions.Scope(
            environment: environment, providerInstanceId: selection?.instanceId, cwd: project?.workspaceRoot,
            projectId: project?.id, repositoryName: project?.repositoryName, threadId: nil, hasThread: false,
            hasConversation: false, canChangeInteractionMode: true
        )
    }

    private func pick(_ item: ComposerSuggestions.Item) {
        guard let trigger = suggestions.trigger else { return }
        switch item.action {
        case .insert(let replacement):
            text = trigger.replacing(in: text, with: replacement)
        case .interactionMode(let mode):
            text = trigger.replacing(in: text, with: "")
            interactionMode = mode
        case .modelSettings:
            text = trigger.replacing(in: text, with: "")
            showSettings = true
        case .pullRequest(let reference):
            text = trigger.replacing(in: text, with: "\(reference.token) ")
            draft.addPullRequest(reference)
        case .thread(let reference):
            guard draft.addThread(reference) else { return }
            text = trigger.replacing(in: text, with: "\(reference.token) ")
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Logic

    /// Reopening a draft: back on the project it was written for, while that project is still there.
    private func restoreProject() {
        guard environmentId == nil, let saved = NewThreadDraft.load(hasAttachments: !draft.attachments.isEmpty),
              let savedEnvironment = saved.environmentId.flatMap({ model.environment($0) })
        else { return }
        let projects = savedEnvironment.shell.projects
        // Projects not in yet (a cold start): keep the saved one and check again once they are.
        guard projects.isEmpty || savedEnvironment.project(saved.projectId) != nil else { return }
        environmentId = savedEnvironment.id
        projectId = saved.projectId
    }

    /// The project picked by a long press on the New thread button; "no project" is set up on the Mac first.
    private func takeTarget() {
        guard let target = router.newThreadTarget else { return }
        router.newThreadTarget = nil
        environmentId = target.environmentId
        if let id = target.projectId {
            projectId = id
            return
        }
        guard let environment = model.environment(target.environmentId) else { return }
        if let scratch = environment.shell.projects.values.first(where: { environment.config?.isScratch($0) == true }) {
            projectId = scratch.id
            return
        }
        preparingScratch = true
        Task {
            do {
                let scratch = try await environment.ensureScratchProject()
                preparingScratch = false
                projectId = scratch.id
            } catch {
                preparingScratch = false
                self.error = error.localizedDescription
                pickDefaults()
            }
        }
    }

    private func pickDefaults() {
        guard let environment else { return }
        if environmentId == nil { environmentId = environment.id }
        if projectId == nil, !preparingScratch {
            // The project of the most recently active thread is the best guess.
            let recent = environment.shell.threads.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            projectId = recent?.projectId ?? environment.shell.projects.values.max {
                ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
            }?.id
        }
        resetForProject()
    }

    /// Shared text goes into the composer after what's there; files upload once the Mac is live.
    private func takeSeed() {
        guard let seed = router.newThreadSeed else { return }
        router.newThreadSeed = nil
        // The draft survives going back, so sharing the same thing again doesn't repeat it.
        if !seed.text.isEmpty, !text.contains(seed.text) {
            let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = current.isEmpty ? seed.text : current + "\n\n" + seed.text
        }
        sharedFiles += seed.files
        attachSharedFiles()
    }

    private func attachSharedFiles() {
        guard !sharedFiles.isEmpty, let environment, environment.isLive, environment.config != nil else { return }
        draft.attach(shared: sharedFiles, environment: environment)
        sharedFiles = []
    }

    private func resetForProject() {
        guard let config = environment?.config else { return }
        selection = config.initialSelection(project: project)
        runtimeMode = config.defaultRuntimeMode
        startFromOrigin = config.newWorktreesStartFromOrigin
    }

    /// Whether the project is a repository, and the branch a worktree starts from by default.
    private func loadBranches() async {
        repo = nil
        guard let environment, let project, environment.isLive, !isScratch else { return }
        guard let page = try? await environment.listRefs(cwd: project.workspaceRoot) else { return }
        repo = page
        baseBranch = page.defaultBase
    }

    /// Back with nothing written cancels; anything else stays as the draft Home lists. A thread
    /// being started clears the draft itself.
    private func leave() {
        guard !sending else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.attachments.isEmpty {
            router.discardNewThreadDraft()
        } else {
            NewThreadDraft.saveProject(environmentId: environment?.id, projectId: projectId)
            router.refreshNewThreadDraft()
        }
    }

    private func launch() {
        guard let environment, let project, let selection else { return }
        sending = true
        error = nil
        let message = draft.message(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                    inlineContext: environment.config?.inlineMessageContext ?? false)
        let request = AppModel.LaunchRequest(
            environment: environment, projectId: project.id,
            text: message.text, attachments: message.attachments, context: message.context, modelSelection: selection,
            runtimeMode: runtimeMode, interactionMode: interactionMode,
            newWorktree: newWorktree && !isScratch && baseBranch != nil, baseBranch: baseBranch,
            startFromOrigin: startFromOrigin && originAvailable
        )
        Task {
            do {
                let ref = try await model.launch(request)
                router.discardNewThreadDraft()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                // The thread takes New Thread's place, so Back goes to Home.
                router.open(ref)
            } catch {
                self.error = error.localizedDescription
                sending = false
                // Gone back while it was starting: the text is still the draft.
                router.refreshNewThreadDraft()
            }
        }
    }
}

/// Projects across connected Macs, searchable. "No project" sits on top for Macs with a scratch
/// folder, and "+" adds a project from the phone.
struct ProjectPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selectedEnvironment: String?
    let selectedProject: String?
    let onPick: (EnvironmentSession, Project) -> Void
    @State private var query = ""
    @State private var showAdd = false
    @State private var preparingScratch: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, !scratchEnvironments.isEmpty {
                    Section {
                        ForEach(scratchEnvironments) { environment in
                            scratchRow(environment)
                        }
                    } footer: {
                        if let error {
                            Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
                ForEach(filtered, id: \.project.id) { entry in
                    Button {
                        onPick(entry.environment, entry.project)
                    } label: {
                        HStack(spacing: 12) {
                            ProjectIcon(project: entry.project, environment: entry.environment, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.project.title).font(Typography.body).foregroundStyle(Palette.text)
                                Text(FolderPath.short(entry.project.workspaceRoot))
                                    .font(Typography.mono(12))
                                    .foregroundStyle(Palette.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if entry.project.id == selectedProject {
                                Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
                            }
                        }
                    }
                    .accessibilityIdentifier("projectOption")
                    .listRowBackground(Palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add project")
                    .accessibilityIdentifier("addProject")
                }
            }
            .sheet(isPresented: $showAdd) {
                AddProjectSheet(environmentId: selectedEnvironment) { environment, project in
                    showAdd = false
                    onPick(environment, project)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Connected Macs that can run a thread without a project.
    private var scratchEnvironments: [EnvironmentSession] {
        model.environments.filter { $0.isLive && $0.config?.scratchWorkspaceRoot != nil }
    }

    private func scratchRow(_ environment: EnvironmentSession) -> some View {
        let selected = environment.id == selectedEnvironment
            && environment.project(selectedProject).map { environment.config?.isScratch($0) == true } == true
        return Button {
            pickScratch(on: environment)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Palette.canvas, in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("No project — just a task").font(Typography.body).foregroundStyle(Palette.text)
                    if scratchEnvironments.count > 1 {
                        Text("on \(environment.label)").font(Typography.footnote).foregroundStyle(Palette.textMuted)
                    }
                }
                Spacer()
                if preparingScratch == environment.id {
                    ProgressView()
                } else if selected {
                    Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
                }
            }
        }
        .disabled(preparingScratch != nil)
        .accessibilityIdentifier("noProject")
    }

    private func pickScratch(on environment: EnvironmentSession) {
        preparingScratch = environment.id
        error = nil
        Task {
            do {
                onPick(environment, try await environment.ensureScratchProject())
            } catch {
                self.error = error.localizedDescription
            }
            preparingScratch = nil
        }
    }

    /// Every project except the scratch ones, which have their own row.
    private var filtered: [(environment: EnvironmentSession, project: Project)] {
        let all = model.allProjects().filter { $0.environment.config?.isScratch($0.project) != true }
        guard !query.isEmpty else { return all }
        return all.filter { $0.project.title.localizedCaseInsensitiveContains(query) || $0.project.workspaceRoot.localizedCaseInsensitiveContains(query) }
    }
}
