import SwiftUI

/// "Settled · Undo" at the bottom of a thread list for a few seconds after a settle, snooze,
/// unpin or archive, wherever it was done (an archive from a thread's menu shows it on Home).
struct UndoToast: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var undoing = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let notice = model.undoNotice {
                    toast(notice)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(notice.kind)
                }
            }
            .onChange(of: model.undoNotice?.id) { _, id in
                guard id != nil, let title = model.undoNotice?.title else { return }
                AccessibilityNotification.Announcement(String(localized: "\(title). Undo is available.")).post()
            }
            .alert("Couldn't undo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private func toast(_ notice: AppModel.UndoNotice) -> some View {
        HStack(spacing: 14) {
            Text(notice.title)
                .font(Typography.subheadline.weight(.medium))
                .foregroundStyle(Palette.text)
                .contentTransition(.numericText())
            Button {
                undoing = true
                Task {
                    do {
                        try await model.undo()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    undoing = false
                }
            } label: {
                Text("Undo")
                    .font(Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accentText)
            }
            .buttonStyle(.plain)
            .disabled(undoing)
            .accessibilityIdentifier("undo")
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(minHeight: 44)
        .glassEffect(.regular, in: .capsule)
        // Swipe it away early.
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height > 10 { model.dismissUndo() }
        })
    }
}

extension View {
    func undoToast() -> some View { modifier(UndoToast()) }
}
