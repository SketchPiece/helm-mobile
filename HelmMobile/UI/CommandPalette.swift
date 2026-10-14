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
        return NewThreadOption(environment: environment, project: environment.config?.isScratch(project) == true ? nil : project)
    }

    /// Where ⌘N can start: what's open first, then "no project", then every project, the latest worked in first.
    func newThreadOptions(in model: AppModel) -> [NewThreadOption] {
        var options: [NewThreadOption] = []
        if let current = currentProject(in: model) { options.append(current) }
        if !options.contains(where: { $0.project == nil }),
           let environment = model.environments.first(where: { $0.isLive && $0.config?.scratchWorkspaceRoot != nil })
        {
            options.insert(NewThreadOption(environment: environment, project: nil), at: min(1, options.count))
        }
        for (environment, project) in model.allProjects() where environment.config?.isScratch(project) != true {
            let option = NewThreadOption(environment: environment, project: project)
            if !options.contains(where: { $0.id == option.id }) { options.append(option) }
        }
        return options
    }

    /// ⌘N: the project list when there's a choice to make, New Thread right away when there isn't.
    func startNewThreadFromKeyboard(in model: AppModel) {
        let options = newThreadOptions(in: model)
        if options.count > 1 {
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
        guard let environment = model.environments.first(where: { $0.isLive && $0.config?.scratchWorkspaceRoot != nil }) else {
            return startNewThread()
        }
        startNewThread(in: NewThreadTarget(environmentId: environment.id, projectId: nil))
    }

    func togglePalette() {
        palette = palette == nil ? .root : nil
    }
}

/// One row of the palette.
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
    var shortcut: String?
    var effect: Effect
}

private struct PaletteSection: Identifiable {
    var id: String
    var title: String
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
                CommandPalette(startMode: mode)
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
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @FocusedValue(\.openThread) private var thread
    @State private var mode: PaletteMode?
    @State private var query = ""
    @State private var selection = 0

    private var current: PaletteMode { mode ?? startMode }

    var body: some View {
        let sections = sections
        let items = sections.flatMap(\.items)
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { router.palette = nil }
                card(sections: sections, items: items, height: proxy.size.height)
                    .frame(maxWidth: min(600, proxy.size.width - 32))
                    .padding(.top, min(96, proxy.size.height * 0.1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: query) { selection = 0 }
        // Escape never reaches the text field (the system takes it first); a shortcut does.
        .background {
            Button("Close") { router.palette = nil }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
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
                    onMove: { move($0, count: items.count) },
                    onSubmit: { if items.indices.contains(selection) { perform(items[selection]) } },
                    onEscape: { router.palette = nil },
                    onBackspaceWhenEmpty: { back() },
                    onNumber: { number in
                        guard current == .newThreadIn, items.indices.contains(number - 1) else { return }
                        perform(items[number - 1])
                    }
                )
                .frame(height: 28)
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
                    .frame(maxHeight: min(460, height * 0.6))
            }
            Divider().overlay(Palette.border)
            footer
        }
        .background(Palette.surface, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }

    private func list(sections: [PaletteSection], items: [PaletteItem]) -> some View {
        let selectedId = items.indices.contains(selection) ? items[selection].id : nil
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(Typography.sectionHeader)
                            .foregroundStyle(Palette.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.items) { item in
                            row(item, selected: item.id == selectedId)
                                .id(item.id)
                                .onTapGesture { perform(item) }
                                .onHover { inside in
                                    if inside, let index = items.firstIndex(where: { $0.id == item.id }) { selection = index }
                                }
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

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            icon(item.icon)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                item.title
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
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
        .frame(minHeight: 44)
        .background(selected ? Palette.text.opacity(0.08) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("paletteRow")
    }

    @ViewBuilder
    private func icon(_ icon: PaletteItem.Icon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textMuted)
        case .project(let environment, let project?):
            ProjectIcon(project: project, environment: environment, size: 24)
        case .project(_, nil):
            ScratchIcon(size: 24)
        case .thread(let entry, let environment):
            ProjectIcon(project: entry.project, environment: environment, size: 24)
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

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "Navigate")
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

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + step + count) % count
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
            let projects = filter(projectItems, words)
            return projects.isEmpty ? [] : [PaletteSection(id: "projects", title: String(localized: "Projects"), items: projects)]
        case .root:
            var sections: [PaletteSection] = []
            let actions = filter(actionItems, words)
            if !actions.isEmpty { sections.append(PaletteSection(id: "actions", title: String(localized: "Actions"), items: actions)) }
            if words.isEmpty {
                let recent = recentThreads.map(threadItem)
                if !recent.isEmpty {
                    sections.append(PaletteSection(id: "recent", title: String(localized: "Recent threads"), items: recent))
                }
            } else {
                let projects = filter(openProjectItems, words)
                if !projects.isEmpty { sections.append(PaletteSection(id: "projects", title: String(localized: "Projects"), items: projects)) }
                let threads = filter(allThreadItems, words).prefix(40)
                if !threads.isEmpty { sections.append(PaletteSection(id: "threads", title: String(localized: "Threads"), items: Array(threads))) }
            }
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
        let place = option.project?.workspaceRoot ?? String(localized: "Scratch folder")
        return showsComputer ? "\(option.environment.label) · \(place)" : place
    }

    /// ⌘N's list, ⌘1–9 on the first nine.
    private var projectItems: [PaletteItem] {
        router.newThreadOptions(in: model).enumerated().map { index, option in
            let name = option.project?.title ?? String(localized: "No project")
            return PaletteItem(
                id: "new|\(option.id)",
                icon: .project(option.environment, option.project),
                title: Text(verbatim: name),
                terms: option.project == nil ? [name, "none", "without project", "scratch"] : [name, option.environment.label],
                subtitle: projectSubtitle(option),
                shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                effect: .run { [router] in router.startNewThread(in: option.target) }
            )
        }
    }

    /// Typed in ⌘K: a project opens its latest thread, or New Thread there if it has none.
    private var openProjectItems: [PaletteItem] {
        let threads = model.allThreads()
        return model.allProjects().compactMap { environment, project in
            guard environment.config?.isScratch(project) != true else { return nil }
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
                shortcut: nil,
                effect: .run { [router] in
                    if let latest { router.open(latest.ref) } else { router.startNewThread(in: option.target) }
                }
            )
        }
    }

    private var actionItems: [PaletteItem] {
        var items: [PaletteItem] = []
        let current = router.currentProject(in: model)
        if let current {
            let name = current.project?.title ?? String(localized: "No project")
            items.append(PaletteItem(
                id: "newHere", icon: .symbol("square.and.pencil"),
                title: Text("New thread in \(Text(verbatim: name).fontWeight(.semibold))"),
                terms: [String(localized: "New thread in \(name)"), "new thread", "create"],
                subtitle: nil, shortcut: "⇧⌘N",
                effect: .run { [router, model] in router.startNewThreadHere(in: model) }
            ))
        }
        items.append(PaletteItem(
            id: "newIn", icon: .symbol("folder.badge.plus"),
            title: Text("New thread in…"),
            terms: [String(localized: "New thread in…"), "new thread", "project", "create"],
            subtitle: nil, shortcut: "⌘N",
            effect: .open(.newThreadIn)
        ))
        if current?.project != nil, model.environments.contains(where: { $0.isLive && $0.config?.scratchWorkspaceRoot != nil }) {
            items.append(PaletteItem(
                id: "newScratch", icon: .symbol("text.bubble"),
                title: Text("New thread without a project"),
                terms: [String(localized: "New thread without a project"), "new thread", "no project", "scratch"],
                subtitle: nil, shortcut: "⌥⌘N",
                effect: .run { [router, model] in router.startNewThreadWithoutProject(in: model) }
            ))
        }
        if let thread {
            if thread.isWorking {
                items.append(PaletteItem(
                    id: "stop", icon: .symbol("stop.circle"), title: Text("Stop Agent"),
                    terms: [String(localized: "Stop Agent"), "interrupt"], subtitle: nil, shortcut: "⌘.",
                    effect: .run { thread.stop() }
                ))
            }
            if thread.hasChanges {
                let title = thread.isReviewing ? String(localized: "Hide Changes") : String(localized: "Review Changes")
                items.append(PaletteItem(
                    id: "review", icon: .symbol("plus.forwardslash.minus"), title: Text(verbatim: title),
                    terms: [title, "diff"], subtitle: nil, shortcut: "⌥⌘I",
                    effect: .run { thread.toggleReview() }
                ))
            }
            let settle = thread.isSettled ? String(localized: "Reopen") : String(localized: "Settle")
            items.append(PaletteItem(
                id: "settle", icon: .symbol(thread.isSettled ? "arrow.uturn.backward" : "checkmark.circle"),
                title: Text(verbatim: settle), terms: [settle, "done", "archive"], subtitle: nil, shortcut: "⇧⌘E",
                effect: .run { thread.perform(thread.isSettled ? .unsettle : .settle) }
            ))
            let pin = thread.isPinned ? String(localized: "Unpin") : String(localized: "Pin")
            items.append(PaletteItem(
                id: "pin", icon: .symbol(thread.isPinned ? "pin.slash" : "pin"),
                title: Text(verbatim: pin), terms: [pin], subtitle: nil, shortcut: nil,
                effect: .run { thread.perform(thread.isPinned ? .unpin : .pin) }
            ))
            items.append(PaletteItem(
                id: "unread", icon: .symbol("circle.badge"), title: Text("Mark as Unread"),
                terms: [String(localized: "Mark as Unread")], subtitle: nil, shortcut: "⇧⌘U",
                effect: .run { thread.markUnread() }
            ))
        }
        items.append(PaletteItem(
            id: "search", icon: .symbol("magnifyingglass"), title: Text("Search Threads"),
            terms: [String(localized: "Search Threads"), "find"], subtitle: nil, shortcut: "⇧⌘F",
            effect: .run { [router] in router.isSearching = true }
        ))
        items.append(PaletteItem(
            id: "snoozed", icon: .symbol("moon.zzz"), title: Text("Snoozed"),
            terms: [String(localized: "Snoozed"), "later"], subtitle: nil, shortcut: nil,
            effect: .run { [router] in router.openShelf(.snoozed, projectId: nil) }
        ))
        items.append(PaletteItem(
            id: "settled", icon: .symbol("checkmark.circle"), title: Text("Settled"),
            terms: [String(localized: "Settled"), "done", "archive"], subtitle: nil, shortcut: nil,
            effect: .run { [router] in router.openShelf(.settled, projectId: nil) }
        ))
        items.append(PaletteItem(
            id: "usage", icon: .symbol("gauge.with.dots.needle.50percent"), title: Text("Usage"),
            terms: [String(localized: "Usage"), "limits"], subtitle: nil, shortcut: nil,
            effect: .run { [router] in
                router.settingsPath = [.usage]
                router.showSettings = true
            }
        ))
        items.append(PaletteItem(
            id: "settings", icon: .symbol("gearshape"), title: Text("Settings"),
            terms: [String(localized: "Settings"), "preferences"], subtitle: nil, shortcut: "⌘,",
            effect: .run { [router] in router.showSettings = true }
        ))
        return items
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
            shortcut: nil,
            effect: .run { [router] in router.open(entry.ref) }
        )
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// The palette's search field: a UIKit one, so the arrows, Return, Escape and ⌘1–9 reach the
/// palette before the text field (or the system) takes them.
private struct PaletteField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMove: (Int) -> Void
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
        DispatchQueue.main.async { field.becomeFirstResponder() }
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
            move: onMove, escape: onEscape, backspaceWhenEmpty: onBackspaceWhenEmpty, number: onNumber
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
            for number in 1...9 {
                commands.append(UIKeyCommand(input: "\(number)", modifierFlags: .command, action: #selector(pickNumber(_:))))
            }
            commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
            return commands + (super.keyCommands ?? [])
        }

        @objc private func up() { handlers?.move(-1) }
        @objc private func down() { handlers?.move(1) }
        @objc private func escape() { handlers?.escape() }

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
