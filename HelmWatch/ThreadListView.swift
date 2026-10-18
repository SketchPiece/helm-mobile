import SwiftUI

/// Home: who needs you first, then what is running, then the rest. A tap opens the thread.
struct ThreadListView: View {
    @Environment(WatchStore.self) private var store
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Helm")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: WatchRoute.newThread) {
                            Image(systemName: "plus")
                                .foregroundStyle(WatchPalette.accentForeground)
                        }
                        .accessibilityLabel(Text("New thread"))
                        .disabled(store.snapshot.projects.isEmpty)
                    }
                }
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .thread(let id): ThreadDetailView(threadId: id)
                    case .newThread: NewThreadView { id in path = [.thread(id)] }
                    }
                }
        }
        .onAppear {
            if path.isEmpty, let route = WatchDemo.initialRoute { path = [route] }
        }
    }

    @ViewBuilder
    private var content: some View {
        let snapshot = store.snapshot
        if snapshot.macs.isEmpty {
            EmptyState(
                symbol: snapshot.updatedAt == .distantPast ? "iphone.gen3" : "desktopcomputer",
                title: snapshot.updatedAt == .distantPast ? String(localized: "Open Helm on your iPhone") : String(localized: "No Mac paired"),
                detail: snapshot.updatedAt == .distantPast
                    ? String(localized: "The watch works through Helm on the iPhone.")
                    : String(localized: "Pair a Mac in Helm on your iPhone.")
            )
        } else {
            List {
                ConnectionBanner()
                let threads = snapshot.threads
                let needsYou = threads.filter { $0.phase.needsYou && !$0.isSettled }
                let active = threads.filter { !$0.phase.needsYou && !$0.isSettled }
                let settled = threads.filter(\.isSettled)
                if needsYou.isEmpty && active.isEmpty {
                    Section {
                        Label("All caught up", systemImage: "checkmark.seal")
                            .foregroundStyle(WatchPalette.textMuted)
                    }
                }
                if !needsYou.isEmpty {
                    Section("Needs you") { rows(needsYou) }
                }
                if !active.isEmpty {
                    Section("Active") { rows(active) }
                }
                if !settled.isEmpty {
                    Section("Settled") { rows(settled) }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private func rows(_ threads: [WatchThread]) -> some View {
        ForEach(threads) { thread in
            NavigationLink(value: WatchRoute.thread(thread.id)) {
                ThreadRowView(thread: thread)
            }
            .listItemTint(thread.phase.needsYou ? thread.phase.color.opacity(0.22) : nil)
        }
    }
}

enum WatchRoute: Hashable {
    case thread(String)
    case newThread
}

struct ThreadRowView: View {
    let thread: WatchThread

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ProjectBadge(icon: thread.icon)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.headline)
                    .lineLimit(2)
                PhaseLabel(phase: thread.phase)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(WatchPalette.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "now", "4m", "2h", "3d": a row has no room for "4 minutes ago".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let duration: Duration = .seconds(seconds)
        if seconds < 60 { return String(localized: "now") }
        if seconds < 3600 { return duration.formatted(.units(allowed: [.minutes], width: .narrow)) }
        if seconds < 86400 { return duration.formatted(.units(allowed: [.hours], width: .narrow)) }
        return duration.formatted(.units(allowed: [.days], width: .narrow))
    }

    private var subtitle: String {
        guard let date = thread.updatedAt else { return thread.projectTitle }
        return "\(thread.projectTitle) · \(Self.age(of: date))"
    }
}

/// Shown above the list when the phone (or its Mac) can't be reached, so a stale list says so.
struct ConnectionBanner: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        if let message {
            Label(message, systemImage: store.isReachable ? "desktopcomputer.trianglebadge.exclamationmark" : "iphone.slash")
                .font(.caption2)
                .foregroundStyle(WatchPalette.textMuted)
                .listRowBackground(Color.clear)
        }
    }

    private var message: String? {
        if !store.isActivated { return String(localized: "Connecting to iPhone…") }
        if !store.isReachable { return String(localized: "iPhone isn't reachable. Showing the last list.") }
        let offline = store.snapshot.macs.filter { !$0.isLive }
        if offline.count == store.snapshot.macs.count, let mac = offline.first {
            return offline.count == 1 ? String(localized: "\(mac.label) is offline.") : String(localized: "Macs are offline.")
        }
        return nil
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(WatchPalette.accent)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(WatchPalette.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
