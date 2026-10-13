import SwiftUI

/// Home: every thread across connected Macs. What needs you comes first, then pinned and active
/// threads in the order the user arranged on any client; snoozed and settled threads are tucked
/// behind two shelf rows at the end, each opening its own screen.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.isSidebar) private var isSidebar
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    @State private var search = ""
    @State private var projectFilter: String?
    @State private var settledLimit = 20
    @State private var renaming: ThreadListEntry?
    @State private var renameText = ""
    @State private var deleting: ThreadListEntry?
    @State private var snoozingCustom: ThreadListEntry?
    /// The row whose swipe asked "snooze until when?".
    @State private var snoozeChoosing: ThreadListEntry?
    @State private var actionError: String?
    @State private var fan = NewThreadFanState()
    /// The fan's "All projects…": the picker, and New Thread in whatever is picked.
    @State private var pickingProject = false
    @State private var editingProject: ProjectEditing?
    @State private var deletingProject: ProjectDeletion?
    /// Moves on when the next snoozed thread is due, so it walks back into the list (as "Woke")
    /// at its wake time rather than at the next unrelated update.
    @State private var now = Date()
    /// The thread open in Helm on a Mac nearby, as a pill above the bar and a remote sheet.
    @State private var remote = MacRemote()

    var body: some View {
        let entries = filteredEntries
        let sections = HomeSections(entries: entries, now: now)
        List {
            if !chips.isEmpty {
                ProjectChips(chips: chips, selection: $projectFilter) { chip, action in
                    switch action {
                    case .newThread:
                        router.startNewThread(in: NewThreadTarget(environmentId: chip.environment.id, projectId: chip.project.id))
                    case .edit:
                        editingProject = ProjectEditing(environment: chip.environment, project: chip.project)
                    case .delete:
                        deletingProject = ProjectDeletion(environment: chip.environment, project: chip.project, in: model)
                    }
                }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            connectionBanner
            draftRow

            if !sections.attention.isEmpty {
                Section {
                    rows(sections.attention)
                } header: {
                    sectionHeader(String(localized: "Needs you"), count: sections.attention.count)
                }
            }
            if !sections.pinned.isEmpty {
                Section {
                    rows(sections.pinned, arrangedAs: .pinned)
                } header: {
                    sectionHeader(String(localized: "Pinned"), count: sections.pinned.count)
                }
            }
            if !sections.active.isEmpty {
                Section {
                    rows(sections.active, arrangedAs: .active)
                } header: {
                    if !sections.attention.isEmpty || !sections.pinned.isEmpty {
                        sectionHeader(String(localized: "Active"), count: sections.active.count)
                    }
                }
            }
            if search.isEmpty {
                if !sections.snoozed.isEmpty || !sections.settled.isEmpty {
                    Section {
                        if !sections.snoozed.isEmpty { shelfRow(.snoozed, sections.snoozed) }
                        if !sections.settled.isEmpty { shelfRow(.settled, sections.settled) }
                    }
                }
            } else {
                // A search reaches into the shelves and lists what it finds right here.
                if !sections.snoozed.isEmpty {
                    Section {
                        rows(sections.snoozed)
                    } header: {
                        sectionHeader(String(localized: "Snoozed"), count: sections.snoozed.count)
                    }
                }
                if !sections.settled.isEmpty {
                    Section {
                        rows(Array(sections.settled.prefix(settledLimit)))
                        if sections.settled.count > settledLimit {
                            Color.clear.frame(height: 1)
                                .listRowBackground(Color.clear)
                                .onAppear { settledLimit += 25 }
                        }
                    } header: {
                        sectionHeader(String(localized: "Settled"), count: sections.settled.count)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .overlay { emptyState(entries: entries) }
        .undoToast()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacRemotePill(remote: remote) { router.showingMacRemote = true }
                .animation(.snappy(duration: 0.35), value: remote.target)
        }
        // After the pill, so the fan opens over it.
        .overlay { NewThreadFan(state: fan) }
        .sheet(isPresented: Binding(get: { router.showingMacRemote }, set: { router.showingMacRemote = $0 })) {
            MacRemoteSheet(remote: remote) { ref in router.path = [.thread(ref)] }
        }
        .onChange(of: model.macRemoteTarget(), initial: true) { _, target in
            withAnimation(.snappy(duration: 0.35)) { remote.follow(target, in: model) }
        }
        .onChange(of: remote.voice.state) {
            if remote.voice.state == .idle { remote.follow(model.macRemoteTarget(), in: model) }
        }
        .onChange(of: remote.thread?.phase) { old, phase in
            // A short tap when the run on the Mac finishes or the agent needs you.
            guard remote.target != nil, let phase, let old, old != phase else { return }
            if phase == .done || phase == .failed || phase == .limited {
                UINotificationFeedbackGenerator().notificationOccurred(phase == .done ? .success : .warning)
            } else if phase == .approval || phase == .input {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        .task {
            // The remote lingers a while after the Mac was last used; let it go when that runs out.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                remote.follow(model.macRemoteTarget(), in: model)
            }
        }
        .navigationTitle(navigationTitle)
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $search, isPresented: searchPresented, prompt: Text("Search"))
        .onChange(of: sections.order, initial: true) { _, order in router.homeOrder = order }
        .toolbar { toolbarContent }
        .refreshable { model.environments.forEach { $0.reconnectNow(reason: "pull to refresh") } }
        .task(id: nextWake) {
            guard let nextWake else { return }
            try? await Task.sleep(for: .seconds(max(0, nextWake.timeIntervalSinceNow) + 0.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.3)) { now = Date() }
        }
        .alert("Rename thread", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let entry = renaming { run(.rename(renameText), on: entry) }
            }
        }
        .confirmationDialog(
            "Delete this thread?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = deleting { run(.delete, on: entry) }
            }
        } message: {
            Text("The conversation and its terminal history are removed from the computer.")
        }
        // The swipe's "Snooze": the same choices as the context menu, in a bottom sheet.
        .sheet(item: $snoozeChoosing) { entry in
            SnoozeChooserSheet(threadTitle: entry.thread.displayTitle) { date in
                try await model.perform(.snooze(date), on: entry.ref)
            } custom: {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    snoozingCustom = entry
                }
            }
        }
        .sheet(item: $snoozingCustom) { entry in
            CustomSnoozeSheet { date in try await model.perform(.snooze(date), on: entry.ref) }
        }
        .sheet(item: $editingProject) { editing in
            ProjectEditSheet(environment: editing.environment, project: editing.project) {
                if projectFilter == editing.project.id { projectFilter = nil }
            }
        }
        .projectDeletionAlert($deletingProject) { deletion in
            if projectFilter == deletion.project.id { projectFilter = nil }
        }
        .sheet(isPresented: $pickingProject) {
            ProjectPicker(selectedEnvironment: nil, selectedProject: nil) { environment, project in
                pickingProject = false
                router.startNewThread(in: NewThreadTarget(environmentId: environment.id, projectId: project.id))
            }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    /// ⌘K opens the search field from anywhere.
    private var searchPresented: Binding<Bool> {
        Binding { router.isSearching } set: { router.isSearching = $0 }
    }

    private var navigationTitle: String {
        if let projectFilter, let project = model.allProjects().first(where: { $0.project.id == projectFilter }) {
            return project.project.title
        }
        return String(localized: "Helm")
    }

    // MARK: Data

    private var chips: [ProjectChips.Chip] {
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for entry in model.allThreads() where !entry.thread.isSettled {
            guard let project = entry.project else { continue }
            counts[project.id, default: 0] += 1
            latest[project.id] = max(latest[project.id] ?? .distantPast, entry.thread.updatedAt ?? .distantPast)
        }
        return model.allProjects()
            .filter { counts[$0.project.id] != nil }
            .sorted { (latest[$0.project.id] ?? .distantPast) > (latest[$1.project.id] ?? .distantPast) }
            .map { ProjectChips.Chip(project: $0.project, environment: $0.environment, count: counts[$0.project.id] ?? 0) }
    }

    /// The soonest wake time still ahead.
    private var nextWake: Date? {
        model.allThreads().compactMap(\.thread.snoozedUntil).filter { $0 > now }.min()
    }

    private var filteredEntries: [ThreadListEntry] {
        var entries = model.allThreads()
        if let projectFilter { entries = entries.filter { $0.project?.id == projectFilter } }
        return entries.matching(search)
    }

    // MARK: Rows

    /// Unsent new threads (written here or in Helm on the Mac), unless a search or another
    /// project's filter hides them.
    private var visibleDrafts: [NewThreadDraft] {
        guard search.isEmpty else { return [] }
        let drafts = Drafts.shared.newThreadDrafts
        guard let projectFilter else { return drafts }
        return drafts.filter { $0.projectId == projectFilter }
    }

    @ViewBuilder
    private var draftRow: some View {
        ForEach(visibleDrafts) { draft in
            let environment = draft.environmentId.flatMap { model.environment($0) }
            Button {
                router.resume(draft)
            } label: {
                DraftRow(draft: draft, project: environment?.project(draft.projectId), environment: environment,
                         showsProject: projectFilter == nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newThreadDraft")
            .listRowBackground(rowBackground(selected: router.path.first == .newThread && draft.key == router.newThreadDraftKey))
            .listRowSeparatorTint(Palette.border)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    withAnimation { router.discardNewThreadDraft(draft.key) }
                } label: {
                    Label("Discard", systemImage: "trash")
                }
            }
        }
    }

    /// The sections whose order the user can change with Move up / Move down.
    enum Arrangement { case pinned, active }

    @ViewBuilder
    private func rows(_ entries: [ThreadListEntry], arrangedAs arrangement: Arrangement? = nil) -> some View {
        ForEach(entries) { entry in
            Button {
                router.open(entry.ref)
            } label: {
                ThreadRow(entry: entry, environment: model.environment(entry.ref.environmentId),
                          showsProject: projectFilter == nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("threadRow")
            .listRowBackground(rowBackground(selected: router.selectedThread == entry.ref))
            .listRowSeparatorTint(Palette.border)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe(entry) }
            .swipeActions(edge: .leading) { leadingSwipe(entry).labelStyle(.iconOnly) }
            .contextMenu {
                contextMenu(entry, arrangement: arrangement, in: entries)
            } preview: {
                ThreadPreviewCard(entry: entry, environment: model.environment(entry.ref.environmentId),
                                  showsComputer: model.environments.count > 1)
            }
        }
    }

    @ViewBuilder
    private func trailingSwipe(_ entry: ThreadListEntry) -> some View {
        let thread = entry.thread
        if thread.isSettled {
            Button { run(.unsettle, on: entry) } label: { Label("Reopen", systemImage: "tray.and.arrow.up") }
                .tint(Palette.working)
        } else if thread.isSnoozed() {
            Button { run(.unsnooze, on: entry) } label: { Label("Wake", systemImage: "sun.max") }
                .tint(Palette.accent)
        } else {
            Button { run(.settle, on: entry) } label: { Label("Settle", systemImage: "checkmark.circle") }
                .tint(Palette.done)
            Button { snoozeChoosing = entry } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
            .tint(Palette.question)
        }
    }

    @ViewBuilder
    private func leadingSwipe(_ entry: ThreadListEntry) -> some View {
        if entry.thread.pinnedAt == nil {
            Button { run(.pin, on: entry) } label: { Label("Pin", systemImage: "pin") }.tint(Palette.accent)
        } else {
            Button { run(.unpin, on: entry) } label: { Label("Unpin", systemImage: "pin.slash") }.tint(Palette.textMuted)
        }
    }

    @ViewBuilder
    private func contextMenu(_ entry: ThreadListEntry, arrangement: Arrangement?, in entries: [ThreadListEntry]) -> some View {
        let thread = entry.thread
        if supportsMultipleWindows {
            Button { openWindow(id: ThreadWindow.id, value: entry.ref) } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        if let environment = model.environment(entry.ref.environmentId), NearbyMacs.shared.contains(environment.id) {
            OpenOnComputerButton(environment: environment, threadId: entry.ref.threadId)
        }
        if supportsMultipleWindows || model.environment(entry.ref.environmentId).map({ NearbyMacs.shared.contains($0.id) }) == true {
            Divider()
        }
        if thread.isSettled {
            Button { run(.unsettle, on: entry) } label: { Label("Reopen", systemImage: "tray.and.arrow.up") }
        } else {
            Button { run(.settle, on: entry) } label: { Label("Settle", systemImage: "checkmark.circle") }
        }
        if thread.isSnoozed(), let wake = thread.snoozedUntil {
            Button { run(.unsnooze, on: entry) } label: {
                Label("Wake now", systemImage: "sun.max")
                Text("Snoozed until \(Snooze.wakeDescription(until: wake))")
            }
        } else {
            SnoozeMenu { run(.snooze($0), on: entry) } custom: { snoozingCustom = entry }
        }
        if thread.pinnedAt == nil {
            Button { run(.pin, on: entry) } label: { Label("Pin", systemImage: "pin") }
        } else {
            Button { run(.unpin, on: entry) } label: { Label("Unpin", systemImage: "pin.slash") }
        }
        if let arrangement, entries.count > 1, model.canReorder(entry.ref, pinned: arrangement == .pinned) {
            if entries.first?.id != entry.id {
                Button { move(entry, .up, in: entries, arrangement) } label: { Label("Move up", systemImage: "arrow.up") }
            }
            if entries.last?.id != entry.id {
                Button { move(entry, .down, in: entries, arrangement) } label: { Label("Move down", systemImage: "arrow.down") }
            }
        }
        Button { run(.markUnread, on: entry) } label: { Label("Mark as unread", systemImage: "circlebadge") }
        Divider()
        Button {
            renameText = thread.title
            renaming = entry
        } label: { Label("Rename", systemImage: "pencil") }
        Button { run(.regenerateTitle, on: entry) } label: { Label("Regenerate title", systemImage: "sparkles") }
        Button {
            UIPasteboard.general.string = thread.id
        } label: { Label("Copy thread ID", systemImage: "number") }
        Divider()
        Button { run(.archive, on: entry) } label: { Label("Archive", systemImage: "archivebox") }
        Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
    }

    private func run(_ action: AppModel.ThreadAction, on entry: ThreadListEntry) {
        Task {
            do {
                try await model.perform(action, on: entry.ref)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func move(_ entry: ThreadListEntry, _ direction: OrderKeys.Direction, in entries: [ThreadListEntry], _ arrangement: Arrangement) {
        Task {
            do {
                try await model.move(entry.ref, direction, in: entries.map(\.ref), pinned: arrangement == .pinned)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Connections and Settings are separate buttons up top; the bottom is only Search and the
        // amber New thread, each in its own glass.
        ToolbarItem(placement: .topBarTrailing) {
            EnvironmentStatusButton()
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings")
        }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // Tap: New Thread as it was left. Long press and slide up: right into a recent project.
            Button {
                if !fan.justClosed { router.startNewThread() }
            } label: {
                // The toolbar paints a prominent button's label white; the colour has to sit on the symbol.
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.accentForeground)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .newThreadFan($fan) {
                NewThreadFanItem.recent(in: model)
            } onPick: { item in
                switch item.kind {
                case let .project(environment, project):
                    router.startNewThread(in: NewThreadTarget(environmentId: environment.id, projectId: project?.id))
                case .allProjects:
                    pickingProject = true
                }
            }
            .accessibilityLabel("New thread")
            .accessibilityIdentifier("newThread")
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        let offline = model.environments.filter { !$0.isLive }
        if !offline.isEmpty, model.environments.allSatisfy({ !$0.isLive }) || offline.contains(where: { $0.status == .unauthorized }) {
            ForEach(offline) { environment in
                ConnectionBanner(environment: environment)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }

    /// In the iPad sidebar, the row of what's open on the right is lit, like a selection in Mail.
    private func rowBackground(selected: Bool) -> some View {
        Palette.canvas.overlay {
            if isSidebar, selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.accent.opacity(0.16))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(Palette.placeholder)
        }
        .sectionLabelStyle()
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private func shelfRow(_ shelf: Router.Shelf, _ entries: [ThreadListEntry]) -> some View {
        Button {
            router.openShelf(shelf, projectId: projectFilter)
        } label: {
            ShelfRow(shelf: shelf, entries: entries)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shelf-\(shelf == .snoozed ? "Snoozed" : "Settled")")
        .listRowBackground(rowBackground(selected: router.path.first == .shelf(shelf, projectId: projectFilter)))
        .listRowSeparatorTint(Palette.border)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder
    private func emptyState(entries: [ThreadListEntry]) -> some View {
        if entries.isEmpty, visibleDrafts.isEmpty {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if model.environments.contains(where: { $0.status == .connecting }) && model.allThreads().isEmpty {
                ProgressView().controlSize(.large)
            } else if model.allThreads().isEmpty {
                ContentUnavailableView {
                    Label("No threads yet", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Start one and your agent gets to work on the computer.")
                } actions: {
                    Button("New thread") { router.startNewThread() }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                        .foregroundStyle(Palette.accentForeground)
                }
            }
        }
    }
}

extension [ThreadListEntry] {
    /// The threads a search finds: by title, project, branch or the latest message.
    func matching(_ search: String) -> [ThreadListEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return self }
        return filter {
            $0.thread.title.localizedCaseInsensitiveContains(query)
                || ($0.project?.title.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.thread.branch?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.thread.latestMessageText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

/// Splits the list into its sections.
struct HomeSections {
    var attention: [ThreadListEntry] = []
    var pinned: [ThreadListEntry] = []
    var active: [ThreadListEntry] = []
    var snoozed: [ThreadListEntry] = []
    var settled: [ThreadListEntry] = []

    /// The threads in the list itself, top to bottom (shelves aside).
    var order: [ThreadRef] { (attention + pinned + active).map(\.ref) }

    init(entries: [ThreadListEntry], now: Date = Date()) {
        for entry in entries {
            let thread = entry.thread
            if thread.needsAttention {
                attention.append(entry)
            } else if thread.isSettled {
                settled.append(entry)
            } else if thread.isSnoozed(now: now) {
                snoozed.append(entry)
            } else if thread.pinnedAt != nil {
                pinned.append(entry)
            } else {
                active.append(entry)
            }
        }
        let byRecent: (ThreadListEntry, ThreadListEntry) -> Bool = {
            ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast)
        }
        attention.sort(by: byRecent)
        pinned = pinned.sortedPinned()
        active = active.sortedActive()
        snoozed.sort { ($0.thread.snoozedUntil ?? .distantFuture) < ($1.thread.snoozedUntil ?? .distantFuture) }
        settled.sort(by: byRecent)
    }
}
