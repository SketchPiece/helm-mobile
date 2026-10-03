import SwiftUI

/// Settings, split the way the app is: this phone, the connected Macs, and about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.environments) { environment in
                        NavigationLink {
                            EnvironmentDetailView(environment: environment)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer")
                                    .foregroundStyle(Palette.textMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(environment.label).font(Typography.body)
                                    Text(environment.statusText)
                                        .font(Typography.footnote)
                                        .foregroundStyle(environment.isLive ? Palette.done : Palette.textMuted)
                                }
                            }
                        }
                    }
                    Button {
                        router.showPairing = true
                    } label: {
                        Label("Connect a Mac", systemImage: "plus")
                    }
                } header: {
                    Text("Macs").sectionLabelStyle()
                }

                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        HStack {
                            Text("Language and text size").foregroundStyle(Palette.text)
                            Spacer()
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(Palette.textMuted)
                        }
                    }
                } header: {
                    Text("This phone").sectionLabelStyle()
                } footer: {
                    Text("Helm follows the phone's language and Dynamic Type text size.")
                        .font(Typography.footnote)
                }

                Section {
                    HStack(spacing: 12) {
                        HelmMark(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Helm").font(Typography.wordmark)
                            Text("Version \(version)")
                                .font(Typography.footnote)
                                .foregroundStyle(Palette.textMuted)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("About").sectionLabelStyle()
                } footer: {
                    Text("A native client for Helm, built on T3 Code's open protocol.")
                        .font(Typography.footnote)
                }
            }
            .font(Typography.body)
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

struct EnvironmentDetailView: View {
    let environment: EnvironmentSession
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                row(String(localized: "Status"), environment.statusText)
                row(String(localized: "Address"), environment.saved.baseURL.absoluteString, mono: true)
                if let version = environment.config?.serverVersion {
                    row(String(localized: "Helm version"), version, mono: true)
                }
                row(String(localized: "Paired"), environment.saved.pairedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let config = environment.config {
                Section {
                    ForEach(config.providers) { provider in
                        HStack(spacing: 10) {
                            ProviderGlyph(driver: provider.driver)
                            Text(provider.displayName)
                            Spacer()
                            Text(provider.isUsable ? String(localized: "Ready") : String(localized: "Unavailable"))
                                .font(Typography.footnote)
                                .foregroundStyle(provider.isUsable ? Palette.done : Palette.textMuted)
                        }
                    }
                } header: {
                    Text("Agents").sectionLabelStyle()
                }
            }
            Section {
                Button("Reconnect") { environment.reconnectNow() }
                Button("Pair again") { router.showPairing = true }
                Button("Remove this Mac", role: .destructive) { confirmRemove = true }
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle(environment.label)
        .confirmationDialog("Remove \(environment.label)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.remove(environment)
                dismiss()
            }
        } message: {
            Text("This phone forgets the Mac. Threads stay on the Mac.")
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.text)
            Spacer()
            Text(value)
                .font(mono ? Typography.mono(13) : Typography.body)
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
