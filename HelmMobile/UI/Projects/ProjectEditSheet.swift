import SwiftUI

/// A project's name, icon and defaults for new threads, and deleting it. A sheet from a long press on
/// a project chip or a project in the picker; a page in Settings › Projects.
struct ProjectEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let environment: EnvironmentSession
    let project: Project
    /// Pushed in a navigation stack (Settings) rather than presented in its own.
    var asPage = false
    /// After the project is gone, so the caller can drop a filter or selection pointing at it.
    var onDeleted: () -> Void = {}

    @State private var title: String
    @State private var icon: Project.IconChoice
    @State private var modelSelection: ModelSelection?
    @State private var envMode: String?
    @State private var editingIcon = false
    @State private var saving = false
    @State private var error: String?
    @State private var deleting: ProjectDeletion?

    init(environment: EnvironmentSession, project: Project, asPage: Bool = false, onDeleted: @escaping () -> Void = {}) {
        self.environment = environment
        self.project = project
        self.asPage = asPage
        self.onDeleted = onDeleted
        _title = State(initialValue: project.title)
        _icon = State(initialValue: project.iconChoice)
        _modelSelection = State(initialValue: project.defaultModelSelection)
        _envMode = State(initialValue: project.defaultThreadEnvMode)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Only what changed goes to the Mac.
    private var changes: [String: JSON] {
        var fields: [String: JSON] = [:]
        if trimmedTitle != project.title { fields["title"] = .string(trimmedTitle) }
        if icon != project.iconChoice { fields.merge(ProjectCommands.iconFields(icon)) { _, new in new } }
        if modelSelection != project.defaultModelSelection { fields["defaultModelSelection"] = modelSelection?.json ?? .null }
        if envMode != project.defaultThreadEnvMode { fields["defaultThreadEnvMode"] = envMode.map(JSON.string) ?? .null }
        return fields
    }

    var body: some View {
        if asPage {
            form
        } else {
            NavigationStack {
                form.toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                }
            }
        }
    }

    private var form: some View {
        List {
            Section {
                Button {
                    editingIcon = true
                } label: {
                    VStack(spacing: 10) {
                        ProjectIcon(project: project.with(icon), environment: environment, size: 88)
                        Text("Change icon")
                            .font(Typography.subheadline.weight(.medium))
                            .foregroundStyle(Palette.accentText)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("changeProjectIcon")
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("Name", text: $title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .submitLabel(.done)
                    .accessibilityIdentifier("projectName")
            } header: {
                Text("Name")
            }
            .listRowBackground(Palette.surface)
            Section {
                HStack {
                    Text(FolderPath.short(project.workspaceRoot))
                        .font(Typography.mono(13))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "lock")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.placeholder)
                }
            } header: {
                Text("Folder on the Mac")
            }
            .listRowBackground(Palette.surface)
            if let config = environment.config {
                defaultsSection(config)
            }
            Section {
                Button(role: .destructive) {
                    deleting = ProjectDeletion(environment: environment, project: project, in: model)
                } label: {
                    Text("Delete project…").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("deleteProject")
            } footer: {
                if let error {
                    Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                }
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle(asPage ? project.title : String(localized: "Edit project"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $editingIcon) {
            ProjectIconEditor(environment: environment, project: project, choice: $icon)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save", action: save)
                        .disabled(changes.isEmpty || trimmedTitle.isEmpty)
                        .accessibilityIdentifier("saveProject")
                }
            }
        }
        .projectDeletionAlert($deleting) { _ in
            dismiss()
            onDeleted()
        }
    }

    /// The model and checkout new threads in this project start with; each can follow the Mac's default.
    @ViewBuilder
    private func defaultsSection(_ config: ServerConfig) -> some View {
        Section {
            NavigationLink {
                ProjectModelPicker(config: config, selection: $modelSelection)
            } label: {
                HStack {
                    Text("Model").foregroundStyle(Palette.text)
                    Spacer()
                    Text(modelSelection.map { config.modelLabel(for: $0) } ?? String(localized: "Helm's default"))
                        .foregroundStyle(Palette.textMuted)
                }
                .font(Typography.body)
            }
            Picker(selection: $envMode) {
                Text("Helm's default").tag(String?.none)
                Text("Current checkout").tag(String?.some("local"))
                Text("New worktree").tag(String?.some("worktree"))
            } label: {
                Text("Workspace").font(Typography.body).foregroundStyle(Palette.text)
            }
            .pickerStyle(.menu)
            .tint(Palette.textMuted)
        } header: {
            Text("New threads")
        } footer: {
            Text("Where a new thread in this project starts. You can still change it before sending.")
        }
        .listRowBackground(Palette.surface)
    }

    private func save() {
        let fields = changes
        saving = true
        error = nil
        Task {
            do {
                try await environment.updateProject(project.id, fields)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// A project's default model: one of the usable providers' models, or the Mac's own default.
struct ProjectModelPicker: View {
    let config: ServerConfig
    @Binding var selection: ModelSelection?
    @State private var showLegacy = false

    var body: some View {
        List {
            Section {
                Button {
                    selection = nil
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Helm's default").font(Typography.body).foregroundStyle(Palette.text)
                            Text(config.modelLabel(for: config.defaultModelSelection))
                                .font(Typography.footnote).foregroundStyle(Palette.textMuted)
                        }
                        Spacer()
                        if selection == nil {
                            Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Palette.surface)
            Section {
                ForEach(config.usableProviders) { provider in
                    let models = provider.models.filter { showLegacy || !$0.isLegacy || $0.slug == selection?.model }
                    if !models.isEmpty {
                        Menu {
                            ForEach(models) { model in
                                Button {
                                    selection = ModelSelection(instanceId: provider.instanceId, model: model.slug)
                                } label: {
                                    if selection?.instanceId == provider.instanceId && selection?.model == model.slug {
                                        Label(model.name, systemImage: "checkmark")
                                    } else {
                                        Text(model.name)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                ProviderIcon(driver: provider.driver, iconUrl: provider.iconUrl, size: 18)
                                    .frame(width: 22)
                                Text(provider.displayName).foregroundStyle(Palette.text)
                                Spacer()
                                if selection?.instanceId == provider.instanceId {
                                    Text(config.modelLabel(for: selection)).foregroundStyle(Palette.accentText)
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.placeholder)
                            }
                            .font(Typography.body)
                        }
                    }
                }
                Toggle("Show older models", isOn: $showLegacy)
                    .font(Typography.subheadline)
                    .tint(Palette.accent)
            } header: {
                Text("Model")
            }
            .listRowBackground(Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Default model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The icon kinds the Mac stores: an image from the project folder, an emoji, or letters on a colour.
struct ProjectIconEditor: View {
    let environment: EnvironmentSession
    let project: Project
    @Binding var choice: Project.IconChoice

    enum Kind: Hashable { case image, emoji, letters }

    @State private var kind: Kind
    @State private var images: [String]?
    @State private var emoji = ""
    @State private var letters: String
    @State private var color: String

    private static let emojis = "📝 💬 🎬 🌊 🚩 📚 🛋️ 🧭 🎧 🗂️ 🧪 🛠️ 🎨 📦 🔖 🌱 🧩 ⚡️ 🐙 🍋 🎯 🪐 📷 🎮 🤖 🧠 🏠 💡 🔥 ✈️"
        .split(separator: " ").map(String.init)

    init(environment: EnvironmentSession, project: Project, choice: Binding<Project.IconChoice>) {
        self.environment = environment
        self.project = project
        _choice = choice
        switch choice.wrappedValue {
        case .automatic, .image: _kind = State(initialValue: .image)
        case .emoji: _kind = State(initialValue: .emoji)
        case .letters: _kind = State(initialValue: .letters)
        }
        if case let .letters(text, color) = choice.wrappedValue {
            _letters = State(initialValue: text)
            _color = State(initialValue: color)
        } else {
            _letters = State(initialValue: project.initials)
            _color = State(initialValue: project.iconColor ?? "orange")
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 18) {
                    ProjectIcon(project: project.with(choice), environment: environment, size: 88)
                    Picker("Kind", selection: $kind) {
                        Text("Image").tag(Kind.image)
                        Text("Emoji").tag(Kind.emoji)
                        Text("Letters").tag(Kind.letters)
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            switch kind {
            case .image: imageSection
            case .emoji: emojiSection
            case .letters: lettersSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kind) { _, kind in
            // Letters always have something to show; the others wait for a pick.
            if kind == .letters { pickLetters() }
        }
        .task {
            images = (try? await environment.projectImages(project)) ?? []
        }
    }

    // MARK: Image

    @ViewBuilder
    private var imageSection: some View {
        Section {
            row(selected: choice == .automatic) {
                ProjectIcon(project: project.with(.automatic), environment: environment, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic").font(Typography.body).foregroundStyle(Palette.text)
                    Text("What Helm finds in the folder").font(Typography.footnote).foregroundStyle(Palette.textMuted)
                }
            } action: {
                choice = .automatic
            }
            if let images {
                ForEach(images, id: \.self) { path in
                    row(selected: choice == .image(path)) {
                        ProjectIcon(project: project.with(.image(path)), environment: environment, size: 30)
                        Text(path)
                            .font(Typography.mono(13))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } action: {
                        choice = .image(path)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("From the project folder")
        } footer: {
            Text(images?.isEmpty == true
                ? "No images in the project. A new one is drawn on the Mac: ask an agent to make the icon."
                : "A new image is drawn on the Mac: ask an agent to make the icon.")
        }
        .listRowBackground(Palette.surface)
    }

    private func row<Label: View>(selected: Bool, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                label()
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Emoji

    @ViewBuilder
    private var emojiSection: some View {
        Section {
            TextField("Any emoji", text: $emoji)
                .font(Typography.body)
                .onChange(of: emoji) { _, text in
                    guard let last = text.last(where: \.isEmoji) else { return }
                    choice = .emoji(String(last))
                    emoji = String(last)
                }
        } footer: {
            Text("Type one from the emoji keyboard, or pick below.")
        }
        .listRowBackground(Palette.surface)
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.emojis, id: \.self) { item in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        choice = .emoji(item)
                    } label: {
                        Text(item)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(choice == .emoji(item) ? Palette.surfaceRaised : .clear, in: .rect(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: choice == .emoji(item) ? 2 : 0)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: Letters

    @ViewBuilder
    private var lettersSection: some View {
        Section {
            HStack {
                TextField("Letters", text: $letters)
                    .font(Typography.body)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: letters) { _, text in
                        // The Mac takes letters and digits only.
                        let clean = String(text.filter { $0.isLetter || $0.isNumber }.prefix(2))
                        if clean != text { letters = clean }
                        pickLetters()
                    }
                Text("1–2 letters").font(Typography.footnote).foregroundStyle(Palette.textMuted)
            }
        } header: {
            Text("Letters")
        }
        .listRowBackground(Palette.surface)
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                ForEach(ProjectIcon.colorNames, id: \.self) { name in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        color = name
                        pickLetters()
                    } label: {
                        Circle()
                            .fill(ProjectIcon.namedColors[name] ?? .gray)
                            .frame(width: 32, height: 32)
                            .padding(3)
                            .overlay { Circle().stroke(Palette.text, lineWidth: color == name ? 2 : 0) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Colour")
        }
        .listRowBackground(Palette.surface)
    }

    private func pickLetters() {
        guard !letters.isEmpty else { return }
        choice = .letters(letters, color: color)
    }
}

private extension Character {
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}

/// A project whose edit sheet is open.
struct ProjectEditing: Identifiable {
    var environment: EnvironmentSession
    var project: Project
    var id: String { "\(environment.id)|\(project.id)" }
}

/// A project about to be deleted, with how many of its threads go with it.
struct ProjectDeletion: Identifiable {
    var environment: EnvironmentSession
    var project: Project
    var threads: Int
    var id: String { "\(environment.id)|\(project.id)" }

    @MainActor
    init(environment: EnvironmentSession, project: Project, in model: AppModel) {
        self.environment = environment
        self.project = project
        threads = model.allThreads().count { $0.ref.environmentId == environment.id && $0.thread.projectId == project.id }
    }
}

extension View {
    /// "Delete “name”?" for `deletion`; deletes the project with its threads when confirmed.
    func projectDeletionAlert(_ deletion: Binding<ProjectDeletion?>,
                              onDeleted: @escaping (ProjectDeletion) -> Void = { _ in }) -> some View {
        modifier(ProjectDeletionAlert(deletion: deletion, onDeleted: onDeleted))
    }
}

private struct ProjectDeletionAlert: ViewModifier {
    @Binding var deletion: ProjectDeletion?
    let onDeleted: (ProjectDeletion) -> Void
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .alert(Text("Delete “\(deletion?.project.title ?? "")”?"),
                   isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
                   presenting: deletion) { deletion in
                Button(role: .destructive) {
                    delete(deletion)
                } label: {
                    if deletion.threads > 0 {
                        Text("Delete project and \(deletion.threads) threads")
                    } else {
                        Text("Delete project")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { deletion in
                if deletion.threads > 0 {
                    Text("Its \(deletion.threads) threads are deleted for good. The folder on the Mac stays as it is.")
                } else {
                    Text("The folder on the Mac stays as it is.")
                }
            }
            .alert("Couldn't delete the project",
                   isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func delete(_ deletion: ProjectDeletion) {
        Task {
            do {
                try await deletion.environment.deleteProject(deletion.project.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onDeleted(deletion)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
