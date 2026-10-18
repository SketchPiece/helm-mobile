import SwiftUI

/// Pick a project, say the task: the thread starts on the Mac with the project's defaults.
struct NewThreadView: View {
    let onStarted: (String) -> Void
    @Environment(WatchStore.self) private var store
    @State private var sending: WatchProject?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.error)
                    .listRowBackground(Color.clear)
            }
            let showMac = Set(store.snapshot.projects.map(\.environmentId)).count > 1
            ForEach(store.snapshot.projects) { project in
                TextFieldLink(prompt: Text("What should the agent do?")) {
                    HStack(spacing: 8) {
                        ProjectBadge(icon: project.icon)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.title).font(.headline).lineLimit(2)
                            if showMac {
                                Text(project.macLabel).font(.caption2).foregroundStyle(WatchPalette.textMuted)
                            }
                        }
                        Spacer(minLength: 0)
                        if sending == project { ProgressView().frame(width: 20) }
                    }
                } onSubmit: { text in
                    start(project, text: text)
                }
                .disabled(sending != nil)
            }
        }
        .navigationTitle("New thread")
    }

    private func start(_ project: WatchProject, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sending = project
        error = nil
        Task {
            let reply = await store.perform(.launch(environmentId: project.environmentId, projectId: project.projectId, text: trimmed))
            sending = nil
            if reply.ok, let threadId = reply.threadId {
                await store.refresh()
                onStarted("\(project.environmentId)|\(threadId)")
            } else if !reply.ok {
                error = reply.error
            }
        }
    }
}
