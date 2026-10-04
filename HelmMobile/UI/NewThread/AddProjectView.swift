import SwiftUI

/// Adds a project from the phone: a folder already on the Mac, a brand new project, or a clone.
/// Every path ends with the project in the shell, handed to `onAdded`.
struct AddProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var environmentId: String?
    let onAdded: (EnvironmentSession, Project) -> Void

    private enum Route: Hashable { case folder, new, clone }

    private var environment: EnvironmentSession? {
        environmentId.flatMap { model.environment($0) } ?? model.environments.first(where: \.isLive)
    }

    var body: some View {
        NavigationStack {
            List {
                if model.environments.count > 1 {
                    Section {
                        Picker("Computer", selection: $environmentId) {
                            ForEach(model.environments) { option in
                                Text(option.label).tag(Optional(option.id))
                            }
                        }
                        .tint(Palette.text)
                    }
                    .listRowBackground(Palette.surface)
                }
                Section {
                    NavigationLink(value: Route.folder) {
                        option("Folder on the computer", detail: "Pick a folder that's already there", symbol: "folder")
                    }
                    .accessibilityIdentifier("addProjectFolder")
                    NavigationLink(value: Route.new) {
                        option("New project", detail: "An empty folder with a README and a first commit", symbol: "plus.rectangle.on.folder")
                    }
                    .disabled(environment?.config?.newProjectsRoot == nil)
                    .accessibilityIdentifier("addProjectNew")
                    NavigationLink(value: Route.clone) {
                        option("Clone a repository", detail: "From GitHub or any git URL", symbol: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("addProjectClone")
                } footer: {
                    if environment?.isLive != true {
                        Text("Connect to this computer to add a project.").font(Typography.footnote)
                    }
                }
                .listRowBackground(Palette.surface)
                .disabled(environment?.isLive != true)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Add project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                if let environment {
                    let added = { (project: Project) in onAdded(environment, project) }
                    switch route {
                    case .folder:
                        FolderBrowser(
                            environment: environment,
                            start: environment.config?.addProjectBaseDirectory ?? "~",
                            actionTitle: "Add this folder",
                            action: { path in added(try await environment.addProject(folder: path)) }
                        )
                    case .new:
                        NewProjectForm(environment: environment, onAdded: added)
                    case .clone:
                        CloneForm(environment: environment, onAdded: added)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if environmentId == nil { environmentId = environment?.id }
        }
    }

    private func option(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.body).foregroundStyle(Palette.text)
                Text(detail).font(Typography.footnote).foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Walks folders on the Mac with `filesystem.browse`, from `start` (a path, `~` allowed) down.
/// The bottom button acts on the folder being shown.
struct FolderBrowser: View {
    let environment: EnvironmentSession
    let start: String
    let actionTitle: LocalizedStringKey
    let action: (String) async throws -> Void

    @State private var directory: String?
    @State private var listing: FolderListing?
    @State private var filter = ""
    @State private var working = false
    @State private var error: String?

    private var visible: [FolderListing.Entry] {
        let showHidden = filter.hasPrefix(".")
        return (listing?.entries ?? []).filter { entry in
            (showHidden || !entry.name.hasPrefix(".")) && (filter.isEmpty || entry.name.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(visible) { entry in
                    Button {
                        filter = ""
                        directory = entry.fullPath
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill").foregroundStyle(Palette.textMuted)
                            Text(entry.name).font(Typography.body).foregroundStyle(Palette.text).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.placeholder)
                        }
                    }
                    .accessibilityIdentifier("folderEntry")
                }
                if listing != nil, visible.isEmpty {
                    Text(filter.isEmpty ? "No folders inside" : "No folders match")
                        .font(Typography.subheadline)
                        .foregroundStyle(Palette.textMuted)
                }
            } header: {
                breadcrumbs
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .overlay {
            if listing == nil, error == nil { ProgressView() }
        }
        .searchable(text: $filter, prompt: "Filter folders")
        .navigationTitle(listing.map { FolderPath.lastSegment($0.path) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PrimaryFooter(title: actionTitle, status: nil, error: error, working: working, enabled: listing != nil, action: run)
        }
        .task(id: directory ?? start) { await load() }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(FolderPath.breadcrumbs(listing?.path ?? start).enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.placeholder)
                    }
                    Button(crumb.name) {
                        filter = ""
                        directory = crumb.path
                    }
                    .font(Typography.mono(13))
                    .foregroundStyle(crumb.path == listing?.path ? Palette.text : Palette.textMuted)
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .textCase(nil)
        .defaultScrollAnchor(.trailing)
    }

    private func load() async {
        error = nil
        do {
            let next = try await environment.browseFolders(directory ?? start)
            guard !Task.isCancelled else { return }
            listing = next
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func run() {
        guard let path = listing?.path else { return }
        working = true
        error = nil
        Task {
            do {
                try await action(path)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// `projects.createNew`, then optionally a private GitHub repository for it.
private struct NewProjectForm: View {
    let environment: EnvironmentSession
    let onAdded: (Project) -> Void

    @State private var name = ""
    @State private var github: GitHubTarget?
    @State private var publish = false
    @State private var working = false
    @State private var status: String?
    @State private var error: String?
    /// Set when the project exists but something after it failed; the button then continues.
    @State private var created: Project?
    @State private var warnings: [String] = []
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .font(Typography.body)
                    .focused($focused)
                    .submitLabel(.done)
                    .disabled(created != nil)
                    .accessibilityIdentifier("newProjectName")
            } footer: {
                if let root = environment.config?.newProjectsRoot {
                    Text("Goes in \(FolderPath.short(root)), with a README and a first commit.").font(Typography.footnote)
                }
            }
            .listRowBackground(Palette.surface)
            if let github {
                Section {
                    Toggle("Create a private GitHub repository", isOn: $publish)
                        .font(Typography.body)
                        .tint(Palette.accent)
                        .disabled(created != nil)
                } footer: {
                    if let account = github.account {
                        Text("Under \(account) on GitHub.").font(Typography.footnote)
                    }
                }
                .listRowBackground(Palette.surface)
            }
            ForEach(warnings, id: \.self) { warning in
                Text(warning).font(Typography.footnote).foregroundStyle(Palette.errorText)
                    .listRowBackground(Palette.warningSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("New project")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PrimaryFooter(
                title: created == nil ? "Create project" : "Continue",
                status: status, error: error, working: working,
                enabled: created != nil || !trimmed.isEmpty, action: create
            )
        }
        .onAppear { focused = true }
        .task { github = await environment.gitHubTarget() }
    }

    private func create() {
        if let created { return onAdded(created) }
        working = true
        error = nil
        Task {
            do {
                status = String(localized: "Creating the project…")
                let (project, commitError) = try await environment.createNewProject(name: trimmed)
                var problems: [String] = []
                if let commitError { problems.append(String(localized: "The first commit failed: \(commitError)")) }
                if publish, let github {
                    status = String(localized: "Creating the GitHub repository…")
                    do {
                        try await environment.publishToGitHub(project, target: github)
                    } catch {
                        problems.append(String(localized: "The GitHub repository wasn't created: \(error.localizedDescription)"))
                    }
                }
                if problems.isEmpty { return onAdded(project) }
                created = project
                warnings = problems
            } catch {
                self.error = error.localizedDescription
            }
            status = nil
            working = false
        }
    }
}

/// Clones a git URL or GitHub `owner/name` into a folder on the Mac. With clone tracking the
/// project exists right away and progress streams in; otherwise the clone is one long call.
private struct CloneForm: View {
    let environment: EnvironmentSession
    let onAdded: (Project) -> Void

    @State private var input = ""
    @State private var directory: String
    @State private var github: GitHubTarget?
    @State private var lookup: RepositoryInfo?
    @State private var lookupError: String?
    @State private var showBrowser = false
    @State private var working = false
    @State private var error: String?
    @State private var cloningId: String?
    @State private var progress: CloneProgress?
    @FocusState private var focused: Bool

    init(environment: EnvironmentSession, onAdded: @escaping (Project) -> Void) {
        self.environment = environment
        self.onAdded = onAdded
        let config = environment.config
        _directory = State(initialValue: config?.addProjectBaseDirectory ?? config?.newProjectsRoot ?? "~")
    }

    private var source: CloneSource? { CloneSource(input) }
    private var destination: String? { source.map { FolderPath.join(directory, $0.directoryName) } }
    private var failed: Bool { progress?.phase == "failed" || progress?.phase == "cancelled" }

    var body: some View {
        Form {
            Section {
                TextField("URL or owner/name", text: $input)
                    .font(Typography.mono(15))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .disabled(cloningId != nil)
                    .accessibilityIdentifier("cloneSource")
            } footer: {
                if let lookup {
                    Label(lookup.nameWithOwner, systemImage: "checkmark.circle").font(Typography.footnote)
                } else if let lookupError {
                    Text(lookupError).font(Typography.footnote)
                }
            }
            .listRowBackground(Palette.surface)
            Section("Into") {
                Button {
                    showBrowser = true
                } label: {
                    HStack {
                        Text(FolderPath.short(destination ?? directory))
                            .font(Typography.mono(13))
                            .foregroundStyle(Palette.text)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.placeholder)
                    }
                }
                .disabled(cloningId != nil)
            }
            .listRowBackground(Palette.surface)
            if let progress, !failed {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(progress.percent ?? 0), total: 100).tint(Palette.working)
                        Text(progress.summary).font(Typography.footnote).foregroundStyle(Palette.textMuted).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Clone a repository")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showBrowser) {
            FolderBrowser(environment: environment, start: directory, actionTitle: "Clone into this folder") { path in
                directory = path
                showBrowser = false
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PrimaryFooter(
                title: failed ? "Try again" : "Clone",
                status: nil, error: error, working: working,
                enabled: source != nil, action: failed ? retry : clone
            )
        }
        .onAppear { focused = true }
        .task { github = await environment.gitHubTarget() }
        .task(id: "\(input)|\(github != nil)") { await lookUp() }
        .task(id: cloningId) { await follow() }
    }

    /// GitHub shorthand is checked against GitHub before cloning; a pasted URL is cloned as is.
    private func lookUp() async {
        lookup = nil
        lookupError = nil
        guard github != nil, let shorthand = source?.shorthand else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let info = try await environment.lookupGitHubRepository(shorthand)
            guard !Task.isCancelled else { return }
            lookup = info
        } catch {
            guard !Task.isCancelled else { return }
            lookupError = error.localizedDescription
        }
    }

    private func clone() {
        guard let source, let destination else { return }
        working = true
        error = nil
        Task {
            do {
                if environment.config?.capability("projectCloneTracking") == true {
                    cloningId = try await environment.startClone(source, repository: lookup, destination: destination)
                } else {
                    onAdded(try await environment.cloneAndAdd(source, repository: lookup, destination: destination))
                }
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }

    private func retry() {
        guard let cloningId else { return }
        working = true
        error = nil
        Task {
            do { try await environment.retryClone(cloningId) } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }

    /// Follows `subscribeProjectClones` until this clone is done (or has dropped off the list).
    private func follow() async {
        guard let cloningId else { return }
        do {
            for try await list in try environment.stream("subscribeProjectClones") {
                guard let next = CloneProgress(projectId: cloningId, in: list), next.phase != "done" else {
                    progress = nil
                    if let project = await environment.waitForProject(cloningId) { onAdded(project) }
                    return
                }
                progress = next
                if failed {
                    error = next.error ?? String(localized: "The clone failed.")
                    working = false
                } else {
                    working = true
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            working = false
        }
    }
}

/// The amber action button pinned under an add-project form, with its status or error above.
private struct PrimaryFooter: View {
    let title: LocalizedStringKey
    let status: String?
    let error: String?
    let working: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            } else if let status {
                Text(status).font(Typography.footnote).foregroundStyle(Palette.textMuted)
            }
            Button(action: action) {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(Palette.accentForeground) }
                    Text(title)
                }
                .font(Typography.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .foregroundStyle(Palette.accentForeground)
            .disabled(!enabled || working)
            .accessibilityIdentifier("addProjectAction")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Palette.canvas)
    }
}
