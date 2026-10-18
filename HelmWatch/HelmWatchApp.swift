import SwiftUI

@main
struct HelmWatchApp: App {
    @State private var store = WatchStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ThreadListView()
                .environment(store)
                .tint(WatchPalette.accent)
                .onAppear { store.activate() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
    }
}
