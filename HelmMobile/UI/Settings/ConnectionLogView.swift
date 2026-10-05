import SwiftUI

/// Settings → Connection log: every connection attempt and why it failed, newest at the bottom.
struct ConnectionLogView: View {
    @State private var text = ConnectionLog.shared.text
    @State private var confirmClear = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? String(localized: "Nothing logged yet.") : text)
                    .font(Typography.mono(11))
                    .foregroundStyle(text.isEmpty ? Palette.textMuted : Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Palette.canvas)
        .navigationTitle("Connection log")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { text = ConnectionLog.shared.text }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                    .disabled(text.isEmpty)
                Menu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                    Button("Clear", systemImage: "trash", role: .destructive) { confirmClear = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(text.isEmpty)
            }
        }
        .confirmationDialog("Clear the connection log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                ConnectionLog.shared.clear()
                text = ""
            }
        }
    }
}
