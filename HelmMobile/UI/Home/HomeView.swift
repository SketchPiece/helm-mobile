import SwiftUI

/// Home: every thread across connected Macs. What needs you comes first, then pinned and active
/// threads in the order the user arranged on any client; snoozed and settled threads are tucked
/// into sections at the bottom.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var search = ""
    @State private var projectFilter: String?
    @State private var showSnoozed = false
    @State private var showSettled = false
    @State private var settledLimit = 20
    @State private var renaming: ThreadListEntry?
    @State private var renameText = ""
    @State private var deleting: ThreadListEntry?
    @State private var snoozingCustom: ThreadListEntry?
    /// The row whose swipe asked "snooze until when?".
    @State private var snoozeChoosing: ThreadListEntry?
    @State private var actionError: String?
    @State private var fan = NewThreadFanState()

    var body: some View {
        let entries = filteredEntries
        let sections = HomeSections(entries: entries)
        List {
            if !chips.isEmpty {
                ProjectChips(chips: chips, selection: $projectFilter)
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
            if !sections.snoozed.isEmpty {
                Section {
                    if showSnoozed || !search.isEmpty { rows(sections.snoozed) }
                } header: {
                    shelfHeader(String(localized: "Snoozed"), count: sections.snoozed.count, expanded: $showSnoozed)
                }
            }
            if !sections.settled.isEmpty {
                Section {
                    if showSettled || !search.isEmpty {
                        rows(Array(sections.settled.prefix(settledLimit)))
                        if sections.settled.count > settledLimit {
                            Color.clear.frame(height: 1)
                                .listRowBackground(Color.clear)
                                .onAppear { settledLimit += 25 }
                        }
                    }
                } header: {
                    shelfHeader(String(localized: "Settled"), count: sections.settled.count, expanded: $showSettled)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .overlay { emptyState(entries: entries) }
        .overlay { NewThreadFan(state: fan) }
        .navigationTitle(navigationTitle)
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $search, prompt: Text("Search"))
        .toolbar { toolbarContent }
        .refreshable { model.environments.forEach { $0.reconnectNow() } }
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
            Text("The conversation and its terminal history are removed from the Mac.")
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
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
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

    private var filteredEntries: [ThreadListEntry] {
        var entries = model.allThreads()
        if let projectFilter { entries = entries.filter { $0.project?.id == projectFilter } }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            entries = entries.filter {
                $0.thread.title.localizedCaseInsensitiveContains(query)
                    || ($0.project?.title.localizedCaseInsensitiveContains(query) ?? false)
                    || ($0.thread.branch?.localizedCaseInsensitiveContains(query) ?? false)
                    || ($0.thread.latestMessageText?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return entries
    }

    // MARK: Rows

    /// The unsent new thread, unless a search or another project's filter hides it.
    private var visibleDraft: NewThreadDraft? {
        guard let draft = router.newThreadDraft, search.isEmpty else { return nil }
        if let projectFilter, draft.projectId != projectFilter { return nil }
        return draft
    }

    @ViewBuilder
    private var draftRow: some View {
        if let draft = visibleDraft {
            let environment = draft.environmentId.flatMap { model.environment($0) }
            Button {
                router.startNewThread()
            } label: {
                DraftRow(draft: draft, project: environment?.project(draft.projectId), environment: environment,
                         showsProject: projectFilter == nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("newThreadDraft")
            .listRowBackground(Palette.canvas)
            .listRowSeparatorTint(Palette.border)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    withAnimation { router.discardNewThreadDraft() }
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
            .listRowBackground(Palette.canvas)
            .listRowSeparatorTint(Palette.border)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe(entry) }
            .swipeActions(edge: .leading) { leadingSwipe(entry) }
            .contextMenu { contextMenu(entry, arrangement: arrangement, in: entries) }
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
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .semibold))
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .foregroundStyle(Palette.accentForeground)
            .newThreadFan($fan) {
                NewThreadFanItem.recent(in: model)
            } onPick: { item in
                router.startNewThread(in: item.target)
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

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(Palette.placeholder)
        }
        .sectionLabelStyle()
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private func shelfHeader(_ title: String, count: Int, expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").foregroundStyle(Palette.placeholder)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
            }
            .sectionLabelStyle()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shelf-\(title)")
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
    }

    @ViewBuilder
    private func emptyState(entries: [ThreadListEntry]) -> some View {
        if entries.isEmpty, visibleDraft == nil {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if model.environments.contains(where: { $0.status == .connecting }) && model.allThreads().isEmpty {
                ProgressView().controlSize(.large)
            } else if model.allThreads().isEmpty {
                ContentUnavailableView {
                    Label("No threads yet", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Start one and your agent gets to work on the Mac.")
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

/// Splits the list into its sections.
struct HomeSections {
    var attention: [ThreadListEntry] = []
    var pinned: [ThreadListEntry] = []
    var active: [ThreadListEntry] = []
    var snoozed: [ThreadListEntry] = []
    var settled: [ThreadListEntry] = []

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
