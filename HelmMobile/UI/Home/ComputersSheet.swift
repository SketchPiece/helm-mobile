import SwiftUI

/// The paired Macs and what the phone can do with each: its screen (from anywhere), the remote
/// (only beside it, on the same network), a new thread there. Home's computer button opens it.
struct ComputersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.environments) { environment in
                        ComputerCard(environment: environment)
                    }
                    Button {
                        router.showComputers = false
                        router.showPairing = true
                    } label: {
                        Label("Connect a computer", systemImage: "plus")
                            .font(Typography.body)
                            .foregroundStyle(Palette.accentText)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 16)
                            .background(Palette.surface, in: .rect(cornerRadius: 18))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Palette.canvas)
            .navigationTitle("Computers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// One Mac in Computers: its name and state, and what can be done with it right now.
private struct ComputerCard: View {
    let environment: EnvironmentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The name opens the Mac's page; the buttons under it stay buttons, not part of the link.
            NavigationLink {
                EnvironmentDetailView(environment: environment)
            } label: {
                header
            }
            .buttonStyle(.plain)
            ComputerActions(environment: environment)
        }
        .padding(14)
        .background(Palette.surface, in: .rect(cornerRadius: 20))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(environment.label)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.text)
                ComputerStatusLine(environment: environment)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.textMuted)
        }
        .contentShape(.rect)
    }
}

/// "Connected · on this network", with its lamp.
struct ComputerStatusLine: View {
    let environment: EnvironmentSession

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(environment.isLive ? Palette.done : environment.status == .connecting ? Palette.accent : Palette.error)
                .frame(width: 7, height: 7)
            Text(text)
                .font(Typography.footnote)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
        }
    }

    private var text: String {
        guard environment.isLive else { return environment.statusText }
        return NearbyMacs.shared.contains(environment.id)
            ? String(localized: "Connected · on this network")
            : String(localized: "Connected · from afar")
    }
}

/// Screen, Remote and New thread for a connected Mac; Reconnect (or Pair again) for one that isn't.
struct ComputerActions: View {
    let environment: EnvironmentSession
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if environment.isLive {
                    if canShowScreen {
                        action("Screen", symbol: "display", prominent: true) {
                            ScreenRemotePresenter.present(environment)
                        }
                    }
                    action("Remote", symbol: "appletvremote.gen4", enabled: isNearby) {
                        leave { router.showingMacRemote = true }
                    }
                    action("New thread", symbol: "square.and.pencil") {
                        router.showComputers = false
                        router.showSettings = false
                        router.startNewThread(in: NewThreadTarget(environmentId: environment.id, projectId: nil))
                    }
                } else if environment.status == .unauthorized {
                    action("Pair again", symbol: "key", prominent: true) {
                        leave { router.showPairing = true }
                    }
                } else {
                    action("Reconnect", symbol: "arrow.clockwise", prominent: true) {
                        environment.reconnectNow(reason: "computers sheet")
                    }
                }
            }
            if environment.isLive, !isNearby {
                Text("The remote works on the same network as the computer; the screen works from anywhere.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isNearby: Bool { NearbyMacs.shared.contains(environment.id) }
    private var canShowScreen: Bool { environment.config?.capability("screenRemote") == true }

    /// Closes Computers (or Settings) first: the next sheet comes up from Home once this one is gone.
    private func leave(then open: @escaping @MainActor () -> Void) {
        router.showComputers = false
        router.showSettings = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            open()
        }
    }

    private func action(_ title: LocalizedStringKey, symbol: String, prominent: Bool = false, enabled: Bool = true,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                Text(title)
                    .font(Typography.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? Palette.accentForeground : Palette.text)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(prominent ? Palette.accent : Palette.surfaceRaised, in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
