import SwiftUI

/// Settings → Performance: turns the diagnostics on and lists the saved recordings.
struct PerfDiagnosticsView: View {
    @AppStorage(PerfMonitor.enabledKey) private var enabled = false
    @State private var monitor = PerfMonitor.shared
    @State private var confirmDelete = false
    @AppStorage(ScrollTrace.enabledKey) private var scrollTrace = false

    var body: some View {
        Form {
            Section {
                Toggle("Record performance", isOn: $enabled)
                if enabled {
                    Button("Save what was recorded") { monitor.save() }
                }
            } footer: {
                Text("Watches for late frames and a busy main thread and shows a counter on screen. Do what stutters, then tap Save on the counter: the recording goes to Documents/Performance as a summary and a JSON file for the Mac.")
            }
            Section {
                Toggle(isOn: $scrollTrace) { Text(verbatim: "Record thread scrolling") }
            } footer: {
                Text(verbatim: "Logs what a thread's scroll view does and why: every jump to the end, sends, new content, the keyboard. Use the thread, tap the flag (or ⌃⌘F) right after something odd, then Save. The trace goes to Documents/Performance as scroll-….txt.")
            }
            if !monitor.reports.isEmpty {
                Section {
                    ForEach(monitor.reports, id: \.self) { url in
                        NavigationLink {
                            PerfReportView(url: url)
                        } label: {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(Typography.mono(13))
                        }
                    }
                    Button("Delete all recordings", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Recordings").sectionLabelStyle()
                }
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Performance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { monitor.refreshReports() }
        .confirmationDialog("Delete all recordings?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { monitor.deleteAll() }
        }
    }
}

/// One recording's summary, with both files to share.
struct PerfReportView: View {
    let url: URL
    @State private var text = ""

    private var files: [URL] {
        [url, url.deletingPathExtension().appendingPathExtension("json")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(Typography.mono(11))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .fixedSize()
                .padding(16)
        }
        .background(Palette.canvas)
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(items: files) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

/// The counter over every window while diagnostics are on: frame rate, late frames, stalls, Save.
struct PerfHUD: View {
    @State private var monitor = PerfMonitor.shared
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var savedFlash = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(monitor.fps) fps")
                    .foregroundStyle(monitor.fps >= 100 || monitor.fps == 0 ? Palette.text : Palette.errorText)
                Text(verbatim: "hitch \(monitor.hitches) · \(Int(monitor.hitchMs)) ms")
                Text(verbatim: "stall \(monitor.stalls) · max \(Int(monitor.worstStallMs)) ms")
                    .foregroundStyle(monitor.worstStallMs > 100 ? Palette.errorText : Palette.textMuted)
            }
            .font(Typography.mono(10))
            .foregroundStyle(Palette.textMuted)
            .monospacedDigit()
            Button {
                monitor.save()
                savedFlash = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    savedFlash = false
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: savedFlash ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: savedFlash ? "Saved" : "\(monitor.recordingSeconds / 60):\(String(format: "%02d", monitor.recordingSeconds % 60))")
                        .font(Typography.mono(9))
                        .monospacedDigit()
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.text)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { offset = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }
                .onEnded { _ in dragStart = offset }
        )
        .padding(.bottom, 90)
        .padding(.leading, 12)
    }
}

extension View {
    /// Starts or stops the diagnostics with the setting and lays the counter over the window.
    func perfDiagnostics() -> some View { modifier(PerfDiagnosticsModifier()) }
}

private struct PerfDiagnosticsModifier: ViewModifier {
    @AppStorage(PerfMonitor.enabledKey) private var enabled = false
    @AppStorage(ScrollTrace.enabledKey) private var scrollTrace = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if enabled { PerfHUD() }
            }
            .overlay(alignment: .topTrailing) {
                if scrollTrace { ScrollTraceHUD() }
            }
            .onChange(of: enabled, initial: true) { PerfMonitor.shared.setEnabled(enabled) }
            .onChange(of: scrollTrace, initial: true) { ScrollTrace.shared.setEnabled(scrollTrace) }
    }
}
