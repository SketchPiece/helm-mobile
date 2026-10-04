import SwiftUI

/// Archived threads across connected Macs: the way back from "Archive".
struct ArchivedThreadsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ThreadListEntry] = []
    @State private var loading = true
    @State private var deleting: ThreadListEntry?
    @State private var error: String?

    var body: some View {
        List {
            ForEach(entries) { entry in
                ThreadRow(entry: entry, environment: model.environment(entry.ref.environmentId))
                    .listRowBackground(Palette.canvas)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { restore(entry) } label: { Label("Restore", systemImage: "tray.and.arrow.up") }
                            .tint(Palette.working)
                        Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { restore(entry) } label: { Label("Restore", systemImage: "tray.and.arrow.up") }
                        Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .overlay {
            if loading {
                ProgressView()
            } else if entries.isEmpty {
                ContentUnavailableView("No archived threads", systemImage: "archivebox")
            }
        }
        .navigationTitle("Archived threads")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            "Delete this thread?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = deleting { run(.delete, entry) }
            }
        } message: {
            Text("The conversation and its terminal history are removed from the computer.")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func load() async {
        var result: [ThreadListEntry] = []
        for environment in model.environments where environment.isLive {
            guard let snapshot = try? await environment.call("orchestration.getArchivedShellSnapshot") else { continue }
            let projects = Dictionary(
                (snapshot["projects"]?.array ?? []).compactMap(Project.init(json:)).map { ($0.id, $0) },
                uniquingKeysWith: { a, _ in a }
            )
            for thread in (snapshot["threads"]?.array ?? []).compactMap(ThreadSummary.init(json:)) where !thread.isSubagent {
                result.append(ThreadListEntry(
                    ref: ThreadRef(environmentId: environment.id, threadId: thread.id),
                    thread: thread,
                    project: projects[thread.projectId] ?? environment.shell.projects[thread.projectId],
                    environmentLabel: environment.label
                ))
            }
        }
        entries = result.sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
        loading = false
    }

    private func restore(_ entry: ThreadListEntry) { run(.unarchive, entry) }

    private func run(_ action: AppModel.ThreadAction, _ entry: ThreadListEntry) {
        Task {
            do {
                try await model.perform(action, on: entry.ref)
                withAnimation { entries.removeAll { $0.id == entry.id } }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
