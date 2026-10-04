import SwiftUI

/// The branch a new worktree starts from: local branches from `vcs.listRefs`, searched on the
/// server and paged 100 at a time, plus whether to start from origin's copy of it.
struct BranchPicker: View {
    let environment: EnvironmentSession
    let cwd: String
    let selected: String?
    let showsOriginToggle: Bool
    @Binding var startFromOrigin: Bool
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var refs: [GitRef] = []
    @State private var nextCursor: Int?
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var error: String?

    /// The server matches loosely; keep only local branches that contain the query.
    private var visible: [GitRef] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return refs.filter { !$0.isRemote && (trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed)) }
    }

    var body: some View {
        NavigationStack {
            List {
                if showsOriginToggle {
                    Section {
                        Toggle(isOn: $startFromOrigin) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start from origin").font(Typography.body)
                                Text("Fetch origin/\(selected ?? "main") and branch off that")
                                    .font(Typography.footnote)
                                    .foregroundStyle(Palette.textMuted)
                            }
                        }
                        .tint(Palette.accent)
                        .accessibilityIdentifier("startFromOrigin")
                    }
                    .listRowBackground(Palette.surface)
                }
                Section {
                    ForEach(visible) { ref in
                        Button {
                            onPick(ref.name)
                            dismiss()
                        } label: {
                            row(ref)
                        }
                        .accessibilityIdentifier("branchOption")
                        .onAppear {
                            if ref == visible.last { Task { await loadMore() } }
                        }
                    }
                    if loadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if loaded, visible.isEmpty {
                        Text(query.isEmpty ? "No branches" : "No branches match")
                            .font(Typography.subheadline)
                            .foregroundStyle(Palette.textMuted)
                    }
                    if let error {
                        Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .overlay {
                if !loaded, error == nil { ProgressView() }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search branches")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Base branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .task(id: query) {
                if loaded { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                await loadFirst()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ ref: GitRef) -> some View {
        HStack(spacing: 8) {
            Text(ref.name)
                .font(Typography.mono(14))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            if ref.current { badge("current") }
            if ref.isDefault { badge("default") }
            Spacer()
            if ref.name == selected {
                Image(systemName: "checkmark").foregroundStyle(Palette.accentText)
            }
        }
    }

    private func badge(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Typography.caption)
            .foregroundStyle(Palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Palette.canvas, in: .capsule)
    }

    private func loadFirst() async {
        do {
            let page = try await environment.listRefs(cwd: cwd, query: query)
            guard !Task.isCancelled else { return }
            refs = page.refs
            nextCursor = page.nextCursor
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let requested = query
        do {
            let page = try await environment.listRefs(cwd: cwd, query: requested, cursor: cursor)
            guard requested == query else { return }
            refs = RefPage.merge(refs, page.refs)
            nextCursor = page.nextCursor
        } catch {
            self.error = error.localizedDescription
        }
    }
}
