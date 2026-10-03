import SwiftUI

/// Home: every thread across connected Macs. What needs you comes first, then recent work;
/// snoozed and settled threads are tucked into sections at the bottom.
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
    @State private var actionError: String?

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

            if !sections.attention.isEmpty {
                Section {
                    rows(sections.attention)
                } header: {
                    sectionHeader(String(localized: "Needs you"), count: sections.attention.count)
                }
            }
            if !sections.active.isEmpty {
                Section {
                    rows(sections.active)
                } header: {
                    if !sections.attention.isEmpty {
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

    @ViewBuilder
    private func rows(_ entries: [ThreadListEntry]) -> some View {
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
            .contextMenu { contextMenu(entry) }
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
            Button { run(.snooze(SnoozePreset.tomorrowMorning.date()), on: entry) } label: {
                Label("Tomorrow", systemImage: "moon.zzz")
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
    private func contextMenu(_ entry: ThreadListEntry) -> some View {
        let thread = entry.thread
        if thread.isSettled {
            Button { run(.unsettle, on: entry) } label: { Label("Reopen", systemImage: "tray.and.arrow.up") }
        } else {
            Button { run(.settle, on: entry) } label: { Label("Settle", systemImage: "checkmark.circle") }
        }
        if thread.isSnoozed() {
            Button { run(.unsnooze, on: entry) } label: { Label("Wake now", systemImage: "sun.max") }
        } else {
            Menu {
                ForEach(SnoozePreset.allCases) { preset in
                    Button(preset.title) { run(.snooze(preset.date()), on: entry) }
                }
            } label: {
                Label("Snooze", systemImage: "moon.zzz")
            }
        }
        if thread.pinnedAt == nil {
            Button { run(.pin, on: entry) } label: { Label("Pin", systemImage: "pin") }
        } else {
            Button { run(.unpin, on: entry) } label: { Label("Unpin", systemImage: "pin.slash") }
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

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings")
        }
        ToolbarItem(placement: .bottomBar) {
            EnvironmentStatusButton()
        }
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button {
                router.showNewThread = true
            } label: {
                Image(systemName: "square.and.pencil")
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
        if entries.isEmpty {
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
                    Button("New thread") { router.showNewThread = true }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }
}

/// Splits the list into its sections.
struct HomeSections {
    var attention: [ThreadListEntry] = []
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
            } else {
                active.append(entry)
            }
        }
        let byRecent: (ThreadListEntry, ThreadListEntry) -> Bool = {
            ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast)
        }
        attention.sort(by: byRecent)
        // Pinned first, then working, then by latest activity.
        active.sort { a, b in
            let pinA = a.thread.pinnedAt != nil, pinB = b.thread.pinnedAt != nil
            if pinA != pinB { return pinA }
            return byRecent(a, b)
        }
        snoozed.sort { ($0.thread.snoozedUntil ?? .distantFuture) < ($1.thread.snoozedUntil ?? .distantFuture) }
        settled.sort(by: byRecent)
    }
}

enum SnoozePreset: String, CaseIterable, Identifiable {
    case oneHour, threeHours, tonight, tomorrowMorning, nextWeek
    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: String(localized: "1 hour")
        case .threeHours: String(localized: "3 hours")
        case .tonight: String(localized: "This evening")
        case .tomorrowMorning: String(localized: "Tomorrow morning")
        case .nextWeek: String(localized: "Next week")
        }
    }

    func date(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .threeHours: return now.addingTimeInterval(3 * 3600)
        case .tonight:
            let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now) ?? now
            return evening > now ? evening : now.addingTimeInterval(3600)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .nextWeek:
            let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2),
                                           matchingPolicy: .nextTime) ?? now
            return monday
        }
    }
}
