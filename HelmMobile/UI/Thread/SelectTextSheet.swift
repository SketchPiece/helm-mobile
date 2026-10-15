import SwiftUI
import UIKit

/// A message's text to pick part of. SwiftUI's `.textSelection` on iOS only copies a whole `Text`,
/// so "Select text" in a message's menu opens it here, in a UITextView with ordinary selection.
struct SelectableText: Identifiable {
    let id = UUID()
    let text: String
}

struct SelectTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .background(Palette.canvas.ignoresSafeArea())
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            UIPasteboard.general.string = text
                            dismiss()
                        } label: { Label("Copy all", systemImage: "doc.on.doc") }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = [.link]
        view.accessibilityIdentifier = "selectTextView"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.textColor = UIColor(Palette.text)
        guard view.text != text else { return }
        let base = UIFont(name: "IBMPlexSans-Regular", size: 17) ?? .systemFont(ofSize: 17)
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
        view.text = text
    }
}
