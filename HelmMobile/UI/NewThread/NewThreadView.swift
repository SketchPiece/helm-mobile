import PhotosUI
import SwiftUI

/// Start a thread: pick a project (most recent preselected), write the task, send. Model, access
/// and workspace are one tap away but never in the way.
struct NewThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var environmentId: String?
    @State private var projectId: String?
    @State private var text = Drafts.text(for: "new-thread")
    @State private var selection: ModelSelection?
    @State private var runtimeMode = "full-access"
    @State private var interactionMode = "default"
    @State private var newWorktree = false
    @State private var branches: [String] = []
    @State private var baseBranch: String?
    @State private var attachments: [DraftAttachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showProjects = false
    @State private var showSettings = false
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var environment: EnvironmentSession? {
        environmentId.flatMap { model.environment($0) } ?? model.environments.first(where: \.isLive) ?? model.environments.first
    }
    private var project: Project? { environment?.project(projectId) }

    var body: some View {
        NavigationStack {
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
                workspaceChips
                composer
            }
            .background(Palette.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
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
        }
        .onAppear(perform: pickDefaults)
        .onChange(of: projectId) { _, _ in resetForProject() }
        .task(id: "\(environment?.id ?? "")|\(project?.workspaceRoot ?? "")") { await loadBranches() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 14) {
            Button {
                showProjects = true
            } label: {
                VStack(spacing: 6) {
                    Text("What are we doing in")
                        .foregroundStyle(Palette.text)
                    HStack(spacing: 8) {
                        if let project {
                            ProjectIcon(project: project, environment: environment, size: 26)
                        }
                        Text(project.map { "\($0.title)?" } ?? String(localized: "which project?"))
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

    private var workspaceChips: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    newWorktree = false
                } label: {
                    Label("Current checkout", systemImage: newWorktree ? "" : "checkmark")
                }
                Button {
                    newWorktree = true
                } label: {
                    Label("New worktree", systemImage: newWorktree ? "checkmark" : "")
                }
            } label: {
                chipLabel(newWorktree ? String(localized: "New worktree") : String(localized: "Current checkout"),
                          symbol: newWorktree ? "arrow.triangle.branch" : "folder")
            }
            Button {
                showSettings = true
            } label: {
                let mode = RuntimeMode(rawValue: runtimeMode) ?? .fullAccess
                chipLabel(mode.title, symbol: mode.symbol)
            }
            .buttonStyle(.plain)
            if newWorktree, !branches.isEmpty {
                Menu {
                    ForEach(branches, id: \.self) { branch in
                        Button(branch) { baseBranch = branch }
                    }
                } label: {
                    chipLabel(baseBranch ?? "main", symbol: "point.topleft.down.to.point.bottomright.curvepath", mono: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func chipLabel(_ title: String, symbol: String, mono: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(title).font(mono ? Typography.mono(13) : Typography.footnote.weight(.medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Palette.surface, in: .capsule)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            TextField("Ask anything…", text: $text, axis: .vertical)
                .font(Typography.body)
                .lineLimit(3...10)
                .focused($focused)
                .accessibilityIdentifier("newThreadText")
                .onChange(of: text) { _, value in Drafts.save(value, for: "new-thread") }
            HStack(spacing: 6) {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 34, height: 34)
                }
                .foregroundStyle(Palette.text)
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: 5) {
                        if let selection { ProviderGlyph(driver: environment?.config?.provider(selection.instanceId)?.driver ?? "") }
                        Text(environment?.config?.modelLabel(for: selection) ?? String(localized: "Model"))
                            .font(Typography.subheadline.weight(.medium))
                        if interactionMode == "plan" {
                            Text("· Plan").font(Typography.subheadline).foregroundStyle(Palette.textMuted)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: launch) {
                    Group {
                        if sending { ProgressView().tint(Palette.accentForeground) } else {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .foregroundStyle(canSend ? Palette.accentForeground : Palette.placeholder)
                    .background(canSend ? Palette.accent : Palette.border, in: .circle)
                }
                .disabled(!canSend || sending)
                .accessibilityLabel("Start thread")
                .accessibilityIdentifier("startThread")
            }
        }
        .padding(14)
        .floatingSurface(cornerRadius: 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { focused = true }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty, let environment else { return }
            pickerItems = []
            for item in items {
                var draft = DraftAttachment(name: "photo.jpg")
                let id = draft.id
                attachments.append(draft)
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                        draft.preview = image.preparingThumbnail(of: CGSize(width: 160, height: 160))
                        if let index = attachments.firstIndex(where: { $0.id == id }) { attachments[index].preview = draft.preview }
                        let uploaded = try await environment.uploadImage(image)
                        if let index = attachments.firstIndex(where: { $0.id == id }) { attachments[index].uploaded = uploaded }
                    } catch {
                        if let index = attachments.firstIndex(where: { $0.id == id }) {
                            attachments[index].failed = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && project != nil && selection != nil
            && environment?.isLive == true && !attachments.contains(where: \.isUploading)
    }

    // MARK: Logic

    private func pickDefaults() {
        guard let environment else { return }
        if environmentId == nil { environmentId = environment.id }
        if projectId == nil {
            // The project of the most recently active thread is the best guess.
            let recent = environment.shell.threads.values.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
            projectId = recent?.projectId ?? environment.shell.projects.values.max {
                ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
            }?.id
        }
        resetForProject()
    }

    private func resetForProject() {
        guard let config = environment?.config else { return }
        selection = config.initialSelection(project: project)
        runtimeMode = config.defaultRuntimeMode
    }

    private func loadBranches() async {
        guard let environment, let project, environment.isLive else { return }
        guard let result = try? await environment.call("vcs.listRefs", [
            "cwd": .string(project.workspaceRoot), "refKind": "local", "limit": 50,
        ]) else {
            branches = []
            return
        }
        let refs = result["refs"]?.array ?? []
        branches = refs.compactMap { $0["name"]?.string }
        baseBranch = refs.first { $0["current"]?.bool == true }?["name"]?.string
            ?? refs.first { $0["isDefault"]?.bool == true }?["name"]?.string
            ?? branches.first
    }

    private func launch() {
        guard let environment, let project, let selection else { return }
        sending = true
        error = nil
        let request = AppModel.LaunchRequest(
            environment: environment, projectId: project.id,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments.compactMap(\.uploaded), modelSelection: selection,
            runtimeMode: runtimeMode, interactionMode: interactionMode,
            newWorktree: newWorktree && baseBranch != nil, baseBranch: baseBranch
        )
        Task {
            do {
                let ref = try await model.launch(request)
                Drafts.save("", for: "new-thread")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
                try? await Task.sleep(for: .milliseconds(350))
                router.open(ref)
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }
}

/// Projects across connected Macs, searchable.
struct ProjectPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let selectedEnvironment: String?
    let selectedProject: String?
    let onPick: (EnvironmentSession, Project) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.project.id) { entry in
                    Button {
                        onPick(entry.environment, entry.project)
                    } label: {
                        HStack(spacing: 12) {
                            ProjectIcon(project: entry.project, environment: entry.environment, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.project.title).font(Typography.body).foregroundStyle(Palette.text)
                                Text(shortPath(entry.project.workspaceRoot))
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
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filtered: [(environment: EnvironmentSession, project: Project)] {
        let all = model.allProjects()
        guard !query.isEmpty else { return all }
        return all.filter { $0.project.title.localizedCaseInsensitiveContains(query) || $0.project.workspaceRoot.localizedCaseInsensitiveContains(query) }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
    }
}
