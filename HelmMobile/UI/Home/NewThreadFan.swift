import SwiftUI

/// What a long press on New thread offers: the last few projects, "no project", then all projects at the top.
struct NewThreadFanItem: Identifiable {
    enum Kind {
        /// Nil project is the Mac's "no project" scratch folder.
        case project(EnvironmentSession, Project?)
        /// Every project, in the picker: for one that isn't among the recent.
        case allProjects
    }
    var kind: Kind
    var id: String {
        switch kind {
        case let .project(environment, project): "\(environment.id)|\(project?.id ?? "-")"
        case .allProjects: "all"
        }
    }

    /// The projects of the most recently active threads, newest first, "no project" when a Mac has it,
    /// and all projects last.
    @MainActor
    static func recent(in model: AppModel, limit: Int = 5) -> [NewThreadFanItem] {
        var items: [NewThreadFanItem] = []
        var seen = Set<String>()
        let entries = model.allThreads().sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
        for entry in entries where items.count < limit {
            guard let project = entry.project, let environment = model.environment(entry.ref.environmentId),
                  environment.config?.isScratch(project) != true
            else { continue }
            let item = NewThreadFanItem(kind: .project(environment, project))
            if seen.insert(item.id).inserted { items.append(item) }
        }
        if let environment = model.environments.first(where: { $0.isLive && $0.config?.scratchWorkspaceRoot != nil }) {
            items.append(NewThreadFanItem(kind: .project(environment, nil)))
        }
        if !model.allProjects().isEmpty {
            items.append(NewThreadFanItem(kind: .allProjects))
        }
        return items
    }
}

/// Press, slide up, let go: the fan rises from the New thread button, nearest is the latest project,
/// then "no project", and the far end is all projects. Letting go anywhere else cancels.
struct NewThreadFanState {
    var items: [NewThreadFanItem] = []
    /// The button, in global coordinates; the fan stacks up from it.
    var anchor: CGRect = .zero
    var isOpen = false
    var highlighted: Int?
    /// When the fan last closed: the button's own tap fires on the same release and is ignored.
    var closedAt: Date = .distantPast
    var justClosed: Bool { Date().timeIntervalSince(closedAt) < 0.5 }

    static let bubble: CGFloat = 52
    static let spacing: CGFloat = 14

    /// Where item `index` sits, in global coordinates.
    func center(of index: Int) -> CGPoint {
        let first = anchor.minY - 22 - Self.bubble / 2
        return CGPoint(x: anchor.midX, y: first - CGFloat(index) * (Self.bubble + Self.spacing))
    }

    /// The item under the finger. Past the far end still counts as the last one, so an overshoot
    /// lands on all projects and starts nothing; too far sideways or back on the button is nothing.
    func item(at point: CGPoint) -> Int? {
        guard !items.isEmpty, abs(point.x - anchor.midX) < 110 else { return nil }
        let step = Self.bubble + Self.spacing
        let last = items.count - 1
        if point.y < center(of: last).y { return last }
        for index in items.indices where abs(point.y - center(of: index).y) <= step / 2 {
            return index
        }
        return nil
    }
}

struct NewThreadFan: View {
    let state: NewThreadFanState

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                Palette.canvas.opacity(state.isOpen ? 0.72 : 0)
                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                    let center = state.center(of: index)
                    let selected = state.highlighted == index
                    FanRow(isOpen: state.isOpen, index: index, selected: selected, rise: state.anchor.midY - center.y) {
                        row(item, selected: selected)
                    }
                    .frame(width: 300, alignment: .trailing)
                    .position(x: center.x - origin.x - 150 + NewThreadFanState.bubble / 2, y: center.y - origin.y)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One rising row. Rows are created the moment the fan first opens (cold start, or a project new
    /// to the fan), so each starts closed until it is on screen; otherwise it would appear already open.
    private struct FanRow<Content: View>: View {
        let isOpen: Bool
        let index: Int
        let selected: Bool
        let rise: CGFloat
        @ViewBuilder let content: Content
        @State private var mounted = false

        var body: some View {
            let open = isOpen && mounted
            content
                .scaleEffect(open ? (selected ? 1.12 : 1) : 0.3, anchor: .trailing)
                .opacity(open ? 1 : 0)
                // Rises out of the button, the nearest first.
                .offset(y: open ? 0 : rise)
                .animation(.spring(duration: 0.32, bounce: 0.25).delay(open ? Double(index) * 0.03 : 0), value: open)
                .animation(.snappy(duration: 0.15), value: selected)
                .onAppear { mounted = true }
        }
    }

    private func row(_ item: NewThreadFanItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title(item))
                .font(Typography.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(selected ? Palette.accentForeground : Palette.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(selected ? Palette.accent : Palette.surfaceRaised, in: .capsule)
                .overlay(Capsule().stroke(Palette.border, lineWidth: selected ? 0 : 1))
            bubble(item)
                .overlay {
                    RoundedRectangle(cornerRadius: NewThreadFanState.bubble * 0.25, style: .continuous)
                        .stroke(Palette.accent, lineWidth: selected ? 2.5 : 0)
                }
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
    }

    private func title(_ item: NewThreadFanItem) -> String {
        switch item.kind {
        case let .project(_, project): project?.title ?? String(localized: "No project")
        case .allProjects: String(localized: "All projects…")
        }
    }

    @ViewBuilder
    private func bubble(_ item: NewThreadFanItem) -> some View {
        let size = NewThreadFanState.bubble
        switch item.kind {
        case let .project(environment, project?):
            ProjectIcon(project: project, environment: environment, size: size)
        case .project(_, nil):
            ScratchIcon(size: size)
        case .allProjects:
            Image(systemName: "square.grid.2x2")
                .font(.system(size: size * 0.4))
                .foregroundStyle(Palette.textMuted)
                .frame(width: size, height: size)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: size * 0.25, style: .continuous))
        }
    }
}

extension View {
    /// The long press that opens the fan, on the New thread button. Tap stays the button's own.
    func newThreadFan(_ state: Binding<NewThreadFanState>, items: @escaping () -> [NewThreadFanItem],
                      onPick: @escaping (NewThreadFanItem) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { state.wrappedValue.anchor = $0 }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if !state.wrappedValue.isOpen {
                            let options = items()
                            guard !options.isEmpty else { return }
                            state.wrappedValue.items = options
                            state.wrappedValue.isOpen = true
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        guard let drag else { return }
                        let index = state.wrappedValue.item(at: drag.location)
                        if index != state.wrappedValue.highlighted {
                            state.wrappedValue.highlighted = index
                            if index != nil { UISelectionFeedbackGenerator().selectionChanged() }
                        }
                    }
                    .onEnded { _ in
                        let picked = state.wrappedValue.highlighted.map { state.wrappedValue.items[$0] }
                        guard state.wrappedValue.isOpen else { return }
                        state.wrappedValue.isOpen = false
                        state.wrappedValue.highlighted = nil
                        state.wrappedValue.closedAt = Date()
                        if let picked {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onPick(picked)
                        }
                    }
            )
    }
}
