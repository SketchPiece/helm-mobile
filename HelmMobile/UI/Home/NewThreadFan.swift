import SwiftUI

/// What a long press on New thread offers: the last few projects, then "no project" at the top.
struct NewThreadFanItem: Identifiable {
    var environment: EnvironmentSession
    /// Nil is the Mac's "no project" scratch folder.
    var project: Project?
    var id: String { "\(environment.id)|\(project?.id ?? "-")" }
    var target: NewThreadTarget { NewThreadTarget(environmentId: environment.id, projectId: project?.id) }

    /// The projects of the most recently active threads, newest first, and "no project" when a Mac has it.
    @MainActor
    static func recent(in model: AppModel, limit: Int = 4) -> [NewThreadFanItem] {
        var items: [NewThreadFanItem] = []
        var seen = Set<String>()
        let entries = model.allThreads().sorted { ($0.thread.updatedAt ?? .distantPast) > ($1.thread.updatedAt ?? .distantPast) }
        for entry in entries where items.count < limit {
            guard let project = entry.project, let environment = model.environment(entry.ref.environmentId),
                  environment.config?.isScratch(project) != true
            else { continue }
            let item = NewThreadFanItem(environment: environment, project: project)
            if seen.insert(item.id).inserted { items.append(item) }
        }
        if let environment = model.environments.first(where: { $0.isLive && $0.config?.scratchWorkspaceRoot != nil }) {
            items.append(NewThreadFanItem(environment: environment, project: nil))
        }
        return items
    }
}

/// Press, slide up, let go: the fan rises from the New thread button, nearest is the latest project,
/// the far end is "no project". Letting go anywhere else cancels.
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

    /// The item under the finger. Past the far end still counts as the last one, so "no project"
    /// is a long pull; too far sideways or back on the button is nothing.
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
                    row(item, selected: selected)
                        .scaleEffect(state.isOpen ? (selected ? 1.12 : 1) : 0.3, anchor: .trailing)
                        .opacity(state.isOpen ? 1 : 0)
                        // Rises out of the button, the nearest first.
                        .offset(y: state.isOpen ? 0 : state.anchor.midY - center.y)
                        .animation(.spring(duration: 0.32, bounce: 0.25).delay(state.isOpen ? Double(index) * 0.03 : 0),
                                   value: state.isOpen)
                        .animation(.snappy(duration: 0.15), value: selected)
                        .frame(width: 300, alignment: .trailing)
                        .position(x: center.x - origin.x - 150 + NewThreadFanState.bubble / 2, y: center.y - origin.y)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ item: NewThreadFanItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(item.project?.title ?? String(localized: "No project"))
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

    @ViewBuilder
    private func bubble(_ item: NewThreadFanItem) -> some View {
        let size = NewThreadFanState.bubble
        if let project = item.project {
            ProjectIcon(project: project, environment: item.environment, size: size)
        } else {
            Image(systemName: "text.bubble")
                .font(.system(size: 21))
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
