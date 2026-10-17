import GameController
import SwiftUI

/// What the command palette shows: everything (⌘K), or straight to picking a project for a new
/// thread (⌘N), as Helm on the Mac does.
enum PaletteMode: Equatable {
    case root
    case newThreadIn
}

/// A place to start a thread from the keyboard; no project is the Mac's "no project" scratch folder.
struct NewThreadOption: Identifiable {
    var environment: EnvironmentSession
    var project: Project?
    var id: String { "\(environment.id)|\(project?.id ?? "-")" }
    var target: NewThreadTarget { NewThreadTarget(environmentId: environment.id, projectId: project?.id) }
}

extension Router {
    /// The project of what's open: the thread's, or the one New Thread is writing in.
    func currentProject(in model: AppModel) -> NewThreadOption? {
        let environmentId: String
        let projectId: String
        switch path.last {
        case .thread(let ref):
            guard let thread = model.environment(ref.environmentId)?.thread(ref.threadId) else { return nil }
            environmentId = ref.environmentId
            projectId = thread.projectId
        case .newThread:
            // "new:<environment>:<project>"
            let parts = newThreadDraftKey.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "new" else { return nil }
            environmentId = parts[1]
            projectId = parts[2]
        default:
            return nil
        }
        guard let environment = model.environment(environmentId), let project = environment.project(projectId) else { return nil }
        return NewThreadOption(environment: environment, project: environment.isScratch(project) ? nil : project)
    }

    /// Where ⌘N can start: what's open first, then "no project", then every project, the latest worked in first.
    func newThreadOptions(in model: AppModel) -> [NewThreadOption] {
        var options: [NewThreadOption] = []
        if let current = currentProject(in: model) { options.append(current) }
        if !options.contains(where: { $0.project == nil }),
           let environment = model.scratchEnvironment
        {
            options.insert(NewThreadOption(environment: environment, project: nil), at: min(1, options.count))
        }
        for (environment, project) in model.allProjects() where !environment.isScratch(project) {
            let option = NewThreadOption(environment: environment, project: project)
            if !options.contains(where: { $0.id == option.id }) { options.append(option) }
        }
        return options
    }

    /// ⌘N: the project list when there's a choice to make, New Thread right away when there isn't.
    func startNewThreadFromKeyboard(in model: AppModel) {
        let options = newThreadOptions(in: model)
        if options.count > 1 {
            paletteByTouch = false
            palette = .newThreadIn
        } else {
            palette = nil
            if let only = options.first { startNewThread(in: only.target) } else { startNewThread() }
        }
    }

    /// ⇧⌘N: in the project of what's open, no questions asked.
    func startNewThreadHere(in model: AppModel) {
        palette = nil
        if let current = currentProject(in: model) { startNewThread(in: current.target) } else { startNewThread() }
    }

    /// ⌥⌘N: in the Mac's scratch folder.
    func startNewThreadWithoutProject(in model: AppModel) {
        palette = nil
        guard let environment = model.scratchEnvironment else {
            return startNewThread()
        }
        startNewThread(in: NewThreadTarget(environmentId: environment.id, projectId: nil))
    }

    func togglePalette() {
        paletteByTouch = false
        palette = palette == nil ? .root : nil
    }

    /// The project list for a new thread, opened by a tap (New Thread's project, "All projects…"): on
    /// iPad the palette's list rather than the phone's sheet, so a tap and ⌘N pick from the same place.
    func pickProject() {
        paletteByTouch = true
        palette = .newThreadIn
    }
}

/// One row or chip of the palette.
private struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case project(EnvironmentSession, Project?)
        case thread(ThreadListEntry, EnvironmentSession?)
    }

    enum Effect {
        case run(@MainActor () -> Void)
        case open(PaletteMode)
    }

    var id: String
    var icon: Icon
    var title: Text
    /// What typing matches, the title first.
    var terms: [String]
    var subtitle: String?
    /// The subtitle is a folder path.
    var monoSubtitle = false
    var shortcut: String?
    /// The project New Thread is writing in.
    var checked = false
    /// A project of the list: Edit and Delete in its context menu.
    var editable: (EnvironmentSession, Project)?
    var effect: Effect
}

private struct PaletteSection: Identifiable {
    enum Style {
        case rows
        /// Short choices side by side: where to start a thread, places to go.
        case chips
    }

    var id: String
    var title: String?
    var style: Style = .rows
    var items: [PaletteItem]
}

extension View {
    /// The command palette over the window, opened by ⌘K and ⌘N.
    func commandPalette() -> some View { modifier(CommandPaletteHost()) }
}

private struct CommandPaletteHost: ViewModifier {
    @Environment(Router.self) private var router

    func body(content: Content) -> some View {
        content.overlay {
            if let mode = router.palette {
                CommandPalette(startMode: mode, byTouch: router.paletteByTouch)
                    // ⌘N while ⌘K is open goes to the project list, fresh.
                    .id(mode)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: router.palette)
    }
}

private struct CommandPalette: View {
    let startMode: PaletteMode
    /// Opened by a tap: the field isn't focused and the keyboard hints stay hidden, unless a
    /// keyboard is attached.
    let byTouch: Bool
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @FocusedValue(\.openThread) private var thread
    @State private var mode: PaletteMode?
    @State private var query = ""
    @State private var selection = 0
    @State private var hasKeyboard = GCKeyboard.coalesced != nil
    @State private var showAdd = false
    @State private var editing: ProjectEditing?
    @State private var deleting: ProjectDeletion?

    private var current: PaletteMode { mode ?? startMode }
    /// Shortcuts and the hint footer: only when there are keys to press.
    private var showsKeys: Bool { hasKeyboard || !byTouch }

    var body: some View {
        let sections = sections
        let items = sections.flatMap(\.items)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { router.palette = nil }
                card(sections: sections, items: items, height: proxy.size.height)
                    .frame(maxWidth: min(620, proxy.size.width - 32))
                    .padding(.top, min(96, proxy.size.height * 0.1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: query) { selection = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in hasKeyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hasKeyboard = GCKeyboard.coalesced != nil
        }
        // Escape never reaches the text field (the system takes it first); a shortcut does.
        .background {
            Button("Close") { router.palette = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showAdd) {
            AddProjectSheet(environmentId: router.currentProject(in: model)?.environment.id) { environment, project in
                showAdd = false
                router.palette = nil
                router.startNewThread(in: NewThreadTarget(environmentId: environment.id, projectId: project.id))
            }
        }
        .sheet(item: $editing) { editing in
            ProjectEditSheet(environment: editing.environment, project: editing.project)
        }
        .projectDeletionAlert($deleting)
        .accessibilityAddTraits(.isModal)
    }

    private func card(sections: [PaletteSection], items: [PaletteItem], height: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if mode != nil {
                    Button { back() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textMuted)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.textMuted)
                        .frame(width: 28, height: 28)
                }
                PaletteField(
                    text: $query,
                    placeholder: current == .root
                        ? String(localized: "Search commands, projects, and threads…")
                        : String(localized: "Search projects…"),
                    focusesOnAppear: showsKeys,
                    onMove: { move($0, sections: sections) },
                    onSideways: { sideways($0, sections: sections) },
                    onSubmit: { if items.indices.contains(selection) { perform(items[selection]) } },
                    onEscape: { router.palette = nil },
                    onBackspaceWhenEmpty: { back() },
                    onNumber: { number in
                        guard current == .newThreadIn, items.indices.contains(number - 1) else { return }
                        perform(items[number - 1])
                    }
                )
                .frame(height: 28)
                if current == .newThreadIn {
                    Button { showAdd = true } label: {
                        Label("Add", systemImage: "plus")
                            .labelStyle(.tight)
                            .font(Typography.footnote.weight(.medium))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Palette.text.opacity(0.06), in: .capsule)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -6)
                    .accessibilityLabel("Add project")
                    .accessibilityIdentifier("addProject")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider().overlay(Palette.border)
            if items.isEmpty {
                Text(current == .root ? "No matching commands, projects, or threads." : "No matching projects.")
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                list(sections: sections, items: items)
                    .frame(maxHeight: min(560, height * 0.68))
            }
            if showsKeys {
                Divider().overlay(Palette.border)
                footer(chips: sections.contains { $0.style == .chips })
            }
        }
        .background(Palette.surface, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }

    private func list(sections: [PaletteSection], items: [PaletteItem]) -> some View {
        let selectedId = items.indices.contains(selection) ? items[selection].id : nil
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(Typography.sectionHeader)
                                .foregroundStyle(Palette.textMuted)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 6)
                        }
                        switch section.style {
                        case .rows:
                            ForEach(section.items) { item in
                                interactive(row(item, selected: item.id == selectedId), item, items: items)
                            }
                        case .chips:
                            ChipFlow(spacing: 8) {
                                ForEach(section.items) { item in
                                    interactive(chip(item, selected: item.id == selectedId), item, items: items)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                        }
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) {
                guard let selectedId else { return }
                scroller.scrollTo(selectedId)
            }
        }
    }

    private func interactive(_ view: some View, _ item: PaletteItem, items: [PaletteItem]) -> some View {
        view
            .id(item.id)
            .onTapGesture { perform(item) }
            .onHover { inside in
                if inside, let index = items.firstIndex(where: { $0.id == item.id }) { selection = index }
            }
            .contextMenu {
                if let (environment, project) = item.editable {
                    Button("Edit project…", systemImage: "pencil") {
                        editing = ProjectEditing(environment: environment, project: project)
                    }
                    Divider()
                    Button("Delete project…", systemImage: "trash", role: .destructive) {
                        deleting = ProjectDeletion(environment: environment, project: project, in: model)
                    }
                }
            }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        // Projects and threads are 52pt, with a picture and a second line; commands 44pt.
        let tall = item.subtitle != nil
        return HStack(spacing: 12) {
            icon(item.icon, size: tall ? 30 : 24)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                item.title
                    .font(tall ? Typography.body : Typography.subheadline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(item.monoSubtitle ? Typography.mono(12) : Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if item.checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accentText)
            }
            if showsKeys, let shortcut = item.shortcut {
                Text(verbatim: shortcut)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.textMuted)
            }
            if case .open = item.effect {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: tall ? 52 : 44)
        .background(selected ? Palette.text.opacity(0.07) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("paletteRow")
    }

    private func chip(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            icon(item.icon, size: 22)
            item.title
                .font(Typography.subheadline.weight(.medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            if showsKeys, let shortcut = item.shortcut {
                Text(verbatim: shortcut)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
            }
            if case .open = item.effect {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(selected ? Palette.accent.opacity(0.22) : Palette.text.opacity(0.05),
                    in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.accent.opacity(0.75), lineWidth: 1.5)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("paletteChip")
    }

    @ViewBuilder
    private func icon(_ icon: PaletteItem.Icon, size: CGFloat) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        case .project(let environment, let project?):
            ProjectIcon(project: project, environment: environment, size: size)
        case .project(_, nil):
            ScratchIcon(size: size)
        case .thread(let entry, let environment):
            ProjectIcon(project: entry.project, environment: environment, size: size)
                .grayscale(entry.thread.isSettled ? 1 : 0)
                .opacity(entry.thread.isSettled ? 0.5 : 1)
                .overlay(alignment: .bottomTrailing) {
                    let phase = entry.thread.phase
                    if phase != .idle {
                        Circle()
                            .fill(phase.color)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                }
        }
    }

    private func footer(chips: Bool) -> some View {
        HStack(spacing: 16) {
            hint("↑↓", "Navigate")
            if chips { hint("←→", "Within row") }
            hint("↵", "Choose")
            if current == .newThreadIn { hint("⌘1–9", "Pick") }
            if mode != nil { hint("⌫", "Back") }
            Spacer()
            hint("esc", "Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key)
                .font(Typography.caption.weight(.medium))
                .foregroundStyle(Palette.text)
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.textMuted)
        }
    }

    // MARK: Behaviour

    /// What ↑↓ step through: each row on its own, a section of chips as one line.
    private func lines(_ sections: [PaletteSection]) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        for section in sections {
            switch section.style {
            case .rows:
                lines += (start..<start + section.items.count).map { $0..<$0 + 1 }
            case .chips:
                if !section.items.isEmpty { lines.append(start..<start + section.items.count) }
            }
            start += section.items.count
        }
        return lines
    }

    /// Up and down: to the next line, the first chip of a row of chips.
    private func move(_ step: Int, sections: [PaletteSection]) {
        let lines = lines(sections)
        guard !lines.isEmpty else { return }
        let line = lines.firstIndex { $0.contains(selection) } ?? 0
        selection = lines[(line + step + lines.count) % lines.count].lowerBound
    }

    /// Left and right: along a row of chips. False when the selection is a row, so the field moves its caret.
    private func sideways(_ step: Int, sections: [PaletteSection]) -> Bool {
        guard let line = lines(sections).first(where: { $0.contains(selection) }), line.count > 1 else { return false }
        selection = line.lowerBound + (selection - line.lowerBound + step + line.count) % line.count
        return true
    }

    private func back() {
        guard mode != nil else { return }
        mode = nil
        query = ""
        selection = 0
    }

    private func perform(_ item: PaletteItem) {
        switch item.effect {
        case .open(let next):
            mode = next
            query = ""
            selection = 0
        case .run(let action):
            router.palette = nil
            action()
        }
    }

    // MARK: Contents

    private var sections: [PaletteSection] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        switch current {
        case .newThreadIn:
            let projects = projectItems
            guard words.isEmpty else {
                let found = filter(projects, words)
                return found.isEmpty ? [] : [PaletteSection(id: "projects", title: String(localized: "Projects"), items: found)]
            }
            // What's open and "no project" on top, then the rest.
            let top = projects.prefix { item in
                guard case .project(_, let project) = item.icon else { return false }
                return project == nil || item.id == projects.first?.id
            }
            let rest = projects.dropFirst(top.count)
            return [
                PaletteSection(id: "top", title: nil, items: Array(top)),
                PaletteSection(id: "projects", title: String(localized: "All projects"), items: Array(rest)),
            ].filter { !$0.items.isEmpty }
        case .root:
            guard words.isEmpty else {
                var sections: [PaletteSection] = []
                let actions = filter(newThreadActions + threadActions + placeActions, words)
                if !actions.isEmpty { sections.append(PaletteSection(id: "actions", title: String(localized: "Actions"), items: actions)) }
                let projects = filter(openProjectItems, words)
                if !projects.isEmpty { sections.append(PaletteSection(id: "projects", title: String(localized: "Projects"), items: projects)) }
                let threads = filter(allThreadItems, words).prefix(40)
                if !threads.isEmpty { sections.append(PaletteSection(id: "threads", title: String(localized: "Threads"), items: Array(threads))) }
                return sections
            }
            var sections = [PaletteSection(id: "start", title: String(localized: "New thread in"), style: .chips, items: startChips)]
            let actions = threadActions
            if !actions.isEmpty {
                sections.append(PaletteSection(id: "thread", title: String(localized: "This thread"), style: .chips, items: actions))
            }
            let recent = recentThreads.map(threadItem)
            if !recent.isEmpty {
                sections.append(PaletteSection(id: "recent", title: String(localized: "Recent threads"), items: recent))
            }
            sections.append(PaletteSection(id: "go", title: String(localized: "Go to"), style: .chips, items: placeActions))
            return sections
        }
    }

    /// Every word must be somewhere in the item's terms; a title that starts with the query comes first.
    private func filter(_ items: [PaletteItem], _ words: [String]) -> [PaletteItem] {
        guard !words.isEmpty else { return items }
        let phrase = words.joined(separator: " ")
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, PaletteItem)? in
            let haystack = item.terms.joined(separator: " ").lowercased()
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            let title = item.terms.first?.lowercased() ?? ""
            let rank = title.hasPrefix(phrase) ? 0 : title.contains(phrase) ? 1 : 2
            return (rank, index, item)
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private var showsComputer: Bool { model.environments.count > 1 }

    private func projectSubtitle(_ option: NewThreadOption) -> String? {
        let place = option.project.map { FolderPath.short($0.workspaceRoot) } ?? String(localized: "Scratch folder")
        return showsComputer ? "\(option.environment.label) · \(place)" : place
    }

    /// ⌘N's list (and a tap on New Thread's project), ⌘1–9 on the first nine.
    private var projectItems: [PaletteItem] {
        let current = router.currentProject(in: model)
        let inNewThread = router.path.last == .newThread
        return router.newThreadOptions(in: model).enumerated().map { index, option in
            let name = option.project?.title ?? String(localized: "No project — just a task")
            return PaletteItem(
                id: "new|\(option.id)",
                icon: .project(option.environment, option.project),
                title: Text(verbatim: name),
                terms: option.project == nil ? [name, "none", "without project", "scratch"] : [name, option.environment.label],
                subtitle: projectSubtitle(option),
                monoSubtitle: option.project != nil,
                shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                checked: inNewThread && option.id == current?.id,
                editable: option.project.map { (option.environment, $0) },
                effect: .run { [router] in router.startNewThread(in: option.target) }
            )
        }
    }

    /// ⌘K's first line: the project of what's open, no project, the latest ones, then the whole list.
    private var startChips: [PaletteItem] {
        let current = router.currentProject(in: model)
        var chips = router.newThreadOptions(in: model).prefix(4).map { option in
            let name = option.project?.title ?? String(localized: "No project")
            let shortcut: String? = option.id == current?.id ? "⇧⌘N" : option.project == nil ? "⌥⌘N" : nil
            return PaletteItem(
                id: "start|\(option.id)",
                icon: .project(option.environment, option.project),
                title: Text(verbatim: name),
                terms: [name],
                shortcut: shortcut,
                effect: .run { [router] in router.startNewThread(in: option.target) }
            )
        }
        chips.append(PaletteItem(
            id: "newIn", icon: .symbol("folder"),
            title: Text("All projects"),
            terms: [String(localized: "All projects")],
            shortcut: "⌘N",
            effect: .open(.newThreadIn)
        ))
        return chips
    }

    /// Typed in ⌘K: a project opens its latest thread, or New Thread there if it has none.
    private var openProjectItems: [PaletteItem] {
        let threads = model.allThreads()
        return model.allProjects().compactMap { environment, project in
            guard !environment.isScratch(project) else { return nil }
            let option = NewThreadOption(environment: environment, project: project)
            let latest = threads
                .filter { $0.ref.environmentId == environment.id && $0.thread.projectId == project.id }
                .max { ($0.thread.updatedAt ?? .distantPast) < ($1.thread.updatedAt ?? .distantPast) }
            return PaletteItem(
                id: "project|\(option.id)",
                icon: .project(environment, project),
                title: Text(verbatim: project.title),
                terms: [project.title, environment.label],
                subtitle: projectSubtitle(option),
                monoSubtitle: true,
                effect: .run { [router] in
                    if let latest { router.open(latest.ref) } else { router.startNewThread(in: option.target) }
                }
            )
        }
    }

    /// Typed in ⌘K, the ways to start a thread as commands.
    private var newThreadActions: [PaletteItem] {
        var items: [PaletteItem] = []
        let current = router.currentProject(in: model)
        if let current {
            let name = current.project?.title ?? String(localized: "No project")
            items.append(PaletteItem(
                id: "newHere", icon: .symbol("square.and.pencil"),
                title: Text("New thread in \(Text(verbatim: name).fontWeight(.semibold))"),
                terms: [String(localized: "New thread in \(name)"), "new thread", "create"],
                shortcut: "⇧⌘N",
                effect: .run { [router, model] in router.startNewThreadHere(in: model) }
            ))
        }
        items.append(PaletteItem(
            id: "newIn", icon: .symbol("folder.badge.plus"),
            title: Text("New thread in…"),
            terms: [String(localized: "New thread in…"), "new thread", "project", "create"],
            shortcut: "⌘N",
            effect: .open(.newThreadIn)
        ))
        if current?.project != nil, model.scratchEnvironment != nil {
            items.append(PaletteItem(
                id: "newScratch", icon: .symbol("text.bubble"),
                title: Text("New thread without a project"),
                terms: [String(localized: "New thread without a project"), "new thread", "no project", "scratch"],
                shortcut: "⌥⌘N",
                effect: .run { [router, model] in router.startNewThreadWithoutProject(in: model) }
            ))
        }
        return items
    }

    /// What can be done to the open thread.
    private var threadActions: [PaletteItem] {
        guard let thread else { return [] }
        var items: [PaletteItem] = []
        if thread.isWorking {
            items.append(PaletteItem(
                id: "stop", icon: .symbol("stop.circle"), title: Text("Stop Agent"),
                terms: [String(localized: "Stop Agent"), "interrupt"], shortcut: "⌘.",
                effect: .run { thread.stop() }
            ))
        }
        if thread.hasChanges {
            let title = thread.isReviewing ? String(localized: "Hide Changes") : String(localized: "Review Changes")
            items.append(PaletteItem(
                id: "review", icon: .symbol("plus.forwardslash.minus"), title: Text(verbatim: title),
                terms: [title, "diff"], shortcut: "⌥⌘I",
                effect: .run { thread.toggleReview() }
            ))
        }
        let settle = thread.isSettled ? String(localized: "Reopen") : String(localized: "Settle")
        items.append(PaletteItem(
            id: "settle", icon: .symbol(thread.isSettled ? "arrow.uturn.backward" : "checkmark.circle"),
            title: Text(verbatim: settle), terms: [settle, "done", "archive"], shortcut: "⇧⌘E",
            effect: .run { thread.perform(thread.isSettled ? .unsettle : .settle) }
        ))
        let pin = thread.isPinned ? String(localized: "Unpin") : String(localized: "Pin")
        items.append(PaletteItem(
            id: "pin", icon: .symbol(thread.isPinned ? "pin.slash" : "pin"),
            title: Text(verbatim: pin), terms: [pin],
            effect: .run { thread.perform(thread.isPinned ? .unpin : .pin) }
        ))
        items.append(PaletteItem(
            id: "unread", icon: .symbol("circle.badge"), title: Text("Mark as Unread"),
            terms: [String(localized: "Mark as Unread")], shortcut: "⇧⌘U",
            effect: .run { thread.markUnread() }
        ))
        return items
    }

    /// Places to go: search, the shelves, usage, settings.
    private var placeActions: [PaletteItem] {
        [
            PaletteItem(
                id: "search", icon: .symbol("magnifyingglass"), title: Text("Search Threads"),
                terms: [String(localized: "Search Threads"), "find"], shortcut: "⇧⌘F",
                effect: .run { [router] in router.isSearching = true }
            ),
            PaletteItem(
                id: "snoozed", icon: .symbol("moon.zzz"), title: Text("Snoozed"),
                terms: [String(localized: "Snoozed"), "later"],
                effect: .run { [router] in router.openShelf(.snoozed, projectId: nil) }
            ),
            PaletteItem(
                id: "settled", icon: .symbol("checkmark.circle"), title: Text("Settled"),
                terms: [String(localized: "Settled"), "done", "archive"],
                effect: .run { [router] in router.openShelf(.settled, projectId: nil) }
            ),
            PaletteItem(
                id: "usage", icon: .symbol("gauge.with.dots.needle.50percent"), title: Text("Usage"),
                terms: [String(localized: "Usage"), "limits"],
                effect: .run { [router] in
                    router.settingsPath = [.usage]
                    router.showSettings = true
                }
            ),
            PaletteItem(
                id: "settings", icon: .symbol("gearshape"), title: Text("Settings"),
                terms: [String(localized: "Settings"), "preferences"], shortcut: "⌘,",
                effect: .run { [router] in router.showSettings = true }
            ),
        ]
    }

    /// Home's order (needing you, pinned, active), as the sidebar shows them.
    private var recentThreads: [ThreadListEntry] {
        let entries = model.allThreads()
        let byRef = Dictionary(entries.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = router.homeOrder.compactMap { byRef[$0] }
        let list = ordered.isEmpty
            ? entries.sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
            : ordered
        return Array(list.prefix(12))
    }

    private var allThreadItems: [PaletteItem] {
        model.allThreads()
            .sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
            .map(threadItem)
    }

    private func threadItem(_ entry: ThreadListEntry) -> PaletteItem {
        let project = entry.project?.title
        var subtitle = [project, showsComputer ? entry.environmentLabel : nil].compactMap(\.self)
        if router.selectedThread == entry.ref {
            subtitle.append(String(localized: "Current thread"))
        } else if let updated = entry.thread.updatedAt {
            subtitle.append(Self.relative.localizedString(for: updated, relativeTo: Date()))
        }
        return PaletteItem(
            id: "thread|\(entry.ref.environmentId)|\(entry.ref.threadId)",
            icon: .thread(entry, model.environment(entry.ref.environmentId)),
            title: Text(verbatim: entry.thread.displayTitle),
            terms: [entry.thread.displayTitle, project ?? "", entry.thread.branch ?? ""],
            subtitle: subtitle.joined(separator: " · "),
            effect: .run { [router] in router.open(entry.ref) }
        )
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// Chips left to right, wrapping onto the next line when the row is full.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += (row.map(\.height).max() ?? 0) + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        return rows
    }
}

/// The palette's search field: a UIKit one, so the arrows, Return, Escape and ⌘1–9 reach the
/// palette before the text field (or the system) takes them.
private struct PaletteField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Takes the keyboard as it appears; opened by a tap it waits for one, so no on-screen keyboard covers the list.
    var focusesOnAppear = true
    var onMove: (Int) -> Void
    /// Left and right; false lets the field move its caret.
    var onSideways: (Int) -> Bool
    var onSubmit: () -> Void
    var onEscape: () -> Void
    var onBackspaceWhenEmpty: () -> Void
    var onNumber: (Int) -> Void

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.accessibilityIdentifier = "commandPaletteField"
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "IBMPlexSans", size: 17) ?? .systemFont(ofSize: 17))
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .never
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // On screen first, then focused: an off-window field can't take the keyboard.
        if focusesOnAppear { DispatchQueue.main.async { field.becomeFirstResponder() } }
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.textColor = UIColor(Palette.text)
        field.tintColor = UIColor(Palette.accent)
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: UIColor(Palette.placeholder)]
        )
        field.handlers = Field.Handlers(
            move: onMove, sideways: onSideways, escape: onEscape, backspaceWhenEmpty: onBackspaceWhenEmpty, number: onNumber
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PaletteField
        init(parent: PaletteField) { self.parent = parent }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }
    }

    final class Field: UITextField {
        struct Handlers {
            var move: (Int) -> Void
            var sideways: (Int) -> Bool
            var escape: () -> Void
            var backspaceWhenEmpty: () -> Void
            var number: (Int) -> Void
        }

        var handlers: Handlers?

        override var keyCommands: [UIKeyCommand]? {
            var commands = [
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(up)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(down)),
                UIKeyCommand(input: "p", modifierFlags: .control, action: #selector(up)),
                UIKeyCommand(input: "n", modifierFlags: .control, action: #selector(down)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
            ]
            // Along a row of chips, while there's no text for the caret to move in.
            if text?.isEmpty ?? true {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(left)))
                commands.append(UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(right)))
            }
            for number in 1...9 {
                commands.append(UIKeyCommand(input: "\(number)", modifierFlags: .command, action: #selector(pickNumber(_:))))
            }
            commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
            return commands + (super.keyCommands ?? [])
        }

        @objc private func up() { handlers?.move(-1) }
        @objc private func down() { handlers?.move(1) }
        @objc private func escape() { handlers?.escape() }
        @objc private func left() { _ = handlers?.sideways(-1) }
        @objc private func right() { _ = handlers?.sideways(1) }

        @objc private func pickNumber(_ command: UIKeyCommand) {
            if let number = command.input.flatMap(Int.init) { handlers?.number(number) }
        }

        /// Escape doesn't arrive as a key command while text is being edited; the press does.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.contains(where: { $0.key?.keyCode == .keyboardEscape && $0.key?.modifierFlags.isEmpty != false }) {
                handlers?.escape()
                return
            }
            super.pressesBegan(presses, with: event)
        }

        override func deleteBackward() {
            if text?.isEmpty ?? true { handlers?.backspaceWhenEmpty() }
            super.deleteBackward()
        }
    }
}
