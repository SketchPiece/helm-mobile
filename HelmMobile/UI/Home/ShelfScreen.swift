import SwiftUI

extension Router.Shelf {
    var title: String {
        switch self {
        case .snoozed: String(localized: "Snoozed")
        case .settled: String(localized: "Settled")
        }
    }

    var symbol: String {
        switch self {
        case .snoozed: "moon.zzz"
        case .settled: "checkmark.circle"
        }
    }
}

/// A shelf at the end of Home, built like a thread row: a quiet tile, the shelf's name and one line
/// of detail. Tapping it opens the shelf's own screen.
struct ShelfRow: View {
    let shelf: Router.Shelf
    /// The shelf's threads; snoozed ones in wake order.
    let entries: [ThreadListEntry]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: shelf.symbol)
                .font(.system(size: 19))
                .foregroundStyle(Palette.textMuted)
                .frame(width: 44, height: 44)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.title)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                detail
                    .font(Typography.subheadline)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.placeholder)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var detail: Text {
        let count = Text("\(entries.count) threads").foregroundStyle(Palette.textMuted)
        if shelf == .snoozed, let wake = entries.first?.thread.snoozedUntil {
            let next = Text("next wakes \(Snooze.wakeDescription(until: wake))").foregroundStyle(Palette.question)
            return Text("\(count)\(Text(" · ").foregroundStyle(Palette.placeholder))\(next)")
        }
        return count
    }
}

/// Snoozed or Settled threads on their own screen: snoozed by when they wake, settled by day.
/// Settled keeps growing, so it has its own search; snoozed threads are few enough to see at once.
/// Project chips filter the shelf on its own; they start from Home's filter and don't change it.
struct ShelfScreen: View {
    let shelf: Router.Shelf

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var projectFilter: String?
    @State private var limit = 40
    @State private var search = ""
    @State private var actionError: String?

    /// `projectId` is Home's project filter when the shelf was opened.
    init(shelf: Router.Shelf, projectId: String?) {
        self.shelf = shelf
        _projectFilter = State(initialValue: projectId)
    }

    var body: some View {
        let shelfEntries = self.shelfEntries
        let chips = Self.chips(shelfEntries, model: model)
        let entries = filtered(shelfEntries)
        List {
            // One project has nothing to choose between, unless the filter came from Home and needs "All".
            if chips.count > 1 || (projectFilter != nil && chips.map(\.id) != [projectFilter]) {
                ProjectChips(chips: chips, selection: $projectFilter)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(Self.groups(Array(entries.prefix(limit)), shelf: shelf), id: \.title) { group in
                Section {
                    rows(group.entries)
                } header: {
                    Text(group.title)
                        .sectionLabelStyle()
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                }
            }
            if entries.count > limit {
                Color.clear.frame(height: 1)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .onAppear { limit += 40 }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .overlay {
            if entries.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView(shelf == .snoozed ? "Nothing snoozed" : "Nothing settled", systemImage: shelf.symbol)
                }
            }
        }
        .undoToast()
        .navigationTitle(shelf.title)
        .toolbarTitleDisplayMode(.inlineLarge)
        .modifier(SettledSearch(isOn: shelf == .settled, text: $search))
        .alert("Couldn't do that", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Every thread on this shelf, in its order, before the project filter and search.
    private var shelfEntries: [ThreadListEntry] {
        let sections = HomeSections(entries: model.allThreads())
        return shelf == .snoozed ? sections.snoozed : sections.settled
    }

    private func filtered(_ entries: [ThreadListEntry]) -> [ThreadListEntry] {
        var entries = entries
        if let projectFilter { entries = entries.filter { $0.project?.id == projectFilter } }
        return shelf == .settled ? entries.matching(search) : entries
    }

    /// Projects with threads on this shelf, most recently touched first, counted on this shelf.
    private static func chips(_ entries: [ThreadListEntry], model: AppModel) -> [ProjectChips.Chip] {
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for entry in entries {
            guard let project = entry.project else { continue }
            counts[project.id, default: 0] += 1
            latest[project.id] = max(latest[project.id] ?? .distantPast, entry.thread.updatedAt ?? .distantPast)
        }
        return model.allProjects()
            .filter { counts[$0.project.id] != nil }
            .sorted { (latest[$0.project.id] ?? .distantPast) > (latest[$1.project.id] ?? .distantPast) }
            .map { ProjectChips.Chip(project: $0.project, environment: $0.environment, count: counts[$0.project.id] ?? 0) }
    }

    @ViewBuilder
    private func rows(_ entries: [ThreadListEntry]) -> some View {
        ForEach(entries) { entry in
            Button {
                router.push(entry.ref)
            } label: {
                ThreadRow(entry: entry, environment: model.environment(entry.ref.environmentId),
                          showsProject: projectFilter == nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("threadRow")
            .listRowBackground(Palette.canvas)
            .listRowSeparatorTint(Palette.border)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { bringBack(entry) }
            .contextMenu {
                bringBack(entry)
                Button { run(.archive, on: entry) } label: { Label("Archive", systemImage: "archivebox") }
            }
        }
    }

    @ViewBuilder
    private func bringBack(_ entry: ThreadListEntry) -> some View {
        if shelf == .settled {
            Button { run(.unsettle, on: entry) } label: { Label("Reopen", systemImage: "tray.and.arrow.up") }
                .tint(Palette.working)
        } else {
            Button { run(.unsnooze, on: entry) } label: { Label("Wake", systemImage: "sun.max") }
                .tint(Palette.accent)
        }
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

    /// Search in the bottom bar, as on Home; only Settled has it.
    private struct SettledSearch: ViewModifier {
        let isOn: Bool
        @Binding var text: String

        func body(content: Content) -> some View {
            if isOn {
                content
                    .searchable(text: $text, prompt: Text("Search settled"))
                    .toolbar { DefaultToolbarItem(kind: .search, placement: .bottomBar) }
            } else {
                content
            }
        }
    }

    struct Group {
        var title: String
        var entries: [ThreadListEntry]
    }

    /// Snoozed: Today, Tomorrow, Later by wake time. Settled: Today, Yesterday, This week, Earlier.
    /// `entries` are already in the shelf's order, so each group keeps it.
    static func groups(_ entries: [ThreadListEntry], shelf: Router.Shelf, now: Date = Date(),
                       calendar: Calendar = .current) -> [Group] {
        var groups: [Group] = []
        for entry in entries {
            let date = shelf == .snoozed ? entry.thread.snoozedUntil : entry.thread.updatedAt
            let days = date.map {
                calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: $0)).day ?? 0
            }
            let title: String
            switch (shelf, days) {
            case (.snoozed, let days?) where days <= 0: title = String(localized: "Today")
            case (.snoozed, 1): title = String(localized: "Tomorrow")
            case (.snoozed, _): title = String(localized: "Later")
            case (.settled, let days?) where days >= 0: title = String(localized: "Today")
            case (.settled, -1): title = String(localized: "Yesterday")
            case (.settled, let days?) where days > -7: title = String(localized: "This week")
            case (.settled, _): title = String(localized: "Earlier")
            }
            if groups.last?.title == title {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(Group(title: title, entries: [entry]))
            }
        }
        return groups
    }
}
