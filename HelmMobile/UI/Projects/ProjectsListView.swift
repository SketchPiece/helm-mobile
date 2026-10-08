import SwiftUI

/// Settings › Projects: every project, the latest worked in first, grouped by Mac when there are
/// several. Tap for its page, swipe to delete, "+" to add one.
struct ProjectsListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var adding = false
    @State private var deleting: ProjectDeletion?

    private var projects: [(environment: EnvironmentSession, project: Project)] {
        let all = model.allProjects().filter { $0.environment.config?.isScratch($0.project) != true }
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.project.title.localizedCaseInsensitiveContains(query) || $0.project.workspaceRoot.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let projects = projects
        let environments = model.environments.filter { environment in projects.contains { $0.environment.id == environment.id } }
        List {
            ForEach(environments) { environment in
                Section {
                    ForEach(projects.filter { $0.environment.id == environment.id }, id: \.project.id) { entry in
                        row(entry.environment, entry.project)
                    }
                } header: {
                    if environments.count > 1 { Text(environment.label) }
                }
                .listRowBackground(Palette.surface)
            }
        }
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView(query.isEmpty ? String(localized: "No projects") : String(localized: "Nothing found"),
                                       systemImage: "folder")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .searchable(text: $query)
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add project")
            }
        }
        .sheet(isPresented: $adding) {
            AddProjectSheet(environmentId: nil) { _, _ in adding = false }
        }
        .projectDeletionAlert($deleting)
    }

    private func row(_ environment: EnvironmentSession, _ project: Project) -> some View {
        NavigationLink {
            ProjectEditSheet(environment: environment, project: project, asPage: true)
        } label: {
            HStack(spacing: 12) {
                ProjectIcon(project: project, environment: environment, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.title).font(Typography.body).foregroundStyle(Palette.text)
                    Text(FolderPath.short(project.workspaceRoot))
                        .font(Typography.mono(12))
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleting = ProjectDeletion(environment: environment, project: project, in: model)
            }
        }
        .contextMenu {
            Button("Delete project…", systemImage: "trash", role: .destructive) {
                deleting = ProjectDeletion(environment: environment, project: project, in: model)
            }
        }
    }
}
