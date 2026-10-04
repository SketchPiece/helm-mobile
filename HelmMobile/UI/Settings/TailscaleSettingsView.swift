import SwiftUI

/// The built-in Tailscale node: log in once and the app reaches your Macs on its own, with
/// the Tailscale VPN off or another VPN on.
struct TailscaleSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var confirmLogout = false

    private var tailscale: TailscaleService { model.tailscale }

    var body: some View {
        Form {
            Section {
                switch tailscale.state {
                case .off:
                    Text("Log in once and Helm reaches your Macs by itself, even with the Tailscale VPN off or another VPN on.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Palette.textMuted)
                    Button {
                        tailscale.start()
                    } label: {
                        Label("Log in to Tailscale", systemImage: "person.badge.key")
                            .font(Typography.bodyMedium)
                    }
                    .accessibilityIdentifier("tailscaleLogin")
                case .starting:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Starting Tailscale…").foregroundStyle(Palette.textMuted)
                    }
                case .needsLogin(let url):
                    Text("Finish logging in in the browser. This screen updates by itself.")
                        .font(Typography.subheadline)
                        .foregroundStyle(Palette.textMuted)
                    Button {
                        tailscale.openLogin(force: true)
                    } label: {
                        Label("Open login again", systemImage: "safari")
                    }
                    .disabled(url == nil)
                case .running(let tailnet, let phone, let address):
                    row(String(localized: "Tailnet"), tailnet)
                    row(String(localized: "This phone"), "\(phone) · \(address)", mono: true)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Palette.errorText)
                    Button("Try again") { tailscale.start() }
                }
            } header: {
                Text("Built-in Tailscale").sectionLabelStyle()
            }

            if tailscale.isRunning {
                Section {
                    let computers = tailscale.peers.filter(\.isComputer)
                    if computers.isEmpty {
                        Text("No computers on this tailnet yet.").foregroundStyle(Palette.textMuted)
                    }
                    ForEach(computers) { peer in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(peer.online ? Palette.done : Palette.placeholder)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name).font(Typography.body)
                                Text("\(peer.address) · \(peer.os)")
                                    .font(Typography.mono(12))
                                    .foregroundStyle(Palette.textMuted)
                            }
                        }
                    }
                    Button {
                        router.showPairing = true
                    } label: {
                        Label("Connect a Mac", systemImage: "plus")
                    }
                } header: {
                    Text("Computers").sectionLabelStyle()
                } footer: {
                    Text("On the Mac, turn on Helm → Settings → Connections → Network access.")
                        .font(Typography.footnote)
                }

                Section {
                    Button("Log out of Tailscale", role: .destructive) { confirmLogout = true }
                }
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Tailscale")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { tailscale.watch() }
        .onDisappear { tailscale.unwatch() }
        .onChange(of: tailscale.authURL) { _, url in
            if url != nil { tailscale.openLogin() }
        }
        .confirmationDialog("Log out of Tailscale?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { tailscale.logout() }
        } message: {
            Text("Helm will reach your Macs only through the Tailscale VPN app. Remove this phone in the Tailscale admin console if you no longer need it.")
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(mono ? Typography.mono(13) : Typography.body)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
