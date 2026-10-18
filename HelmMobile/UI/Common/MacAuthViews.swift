import SwiftUI

extension View {
    /// Shows a card over everything while a Mac waits for Face ID (sudo, a password prompt).
    func macAuthRequests() -> some View { modifier(MacAuthOverlay()) }
}

private struct MacAuthOverlay: ViewModifier {
    @Environment(AppModel.self) private var model

    private var pending: (EnvironmentSession, MacAuthRequest)? {
        for environment in model.environments {
            if let request = environment.macAuth.requests.first { return (environment, request) }
        }
        return nil
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let (environment, request) = pending {
                MacAuthCard(environment: environment, request: request)
                    .id(request.id)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 520)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: pending?.1.id)
        .passwordSaveOffer(Binding(
            get: { model.environments.lazy.compactMap(\.macAuth.saveOffer).first },
            set: { offer in
                if offer == nil { model.environments.forEach { $0.macAuth.saveOffer = nil } }
            }
        ))
    }
}

extension View {
    /// After a password typed on the phone worked on the Mac: keep it in the Keychain for Face ID?
    func passwordSaveOffer(_ offer: Binding<PasswordSaveOffer?>) -> some View {
        modifier(PasswordSaveOfferAlert(offer: offer))
    }
}

private struct PasswordSaveOfferAlert: ViewModifier {
    @Binding var offer: PasswordSaveOffer?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "Save the password?"),
                isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
                presenting: offer
            ) { offer in
                Button("Save for Face ID") {
                    do { try offer.keep() } catch { failure = error.localizedDescription }
                    self.offer = nil
                }
                Button("Don't ask again") {
                    MacSecret.neverOffer(offer.kind, environmentId: offer.environmentId)
                    self.offer = nil
                }
                Button("Not now", role: .cancel) { self.offer = nil }
            } message: { offer in
                Text("Next time \(offer.kind.title) goes in with Face ID instead of typing. It stays in this phone's Keychain.")
            }
            .alert(String(localized: "Couldn't save the password"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }
}

/// One request: what the Mac wants, and Face ID to let it.
struct MacAuthCard: View {
    let environment: EnvironmentSession
    let request: MacAuthRequest
    @State private var busy: String?
    @State private var error: String?
    @State private var done: String?
    /// Typed here when none is saved (or the saved one stopped working); only this view holds it.
    @State private var password = ""
    @State private var typing = false
    @State private var typedKind: MacSecret.Kind?
    @FocusState private var passwordFocused: Bool

    private var sync: MacAuthSync { environment.macAuth }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(Palette.accent).frame(width: 7, height: 7)
                Text(label).sectionLabelStyle()
                Spacer()
                if let expiresAt = request.expiresAt {
                    Text(expiresAt, style: .timer)
                        .font(Typography.footnote.monospacedDigit())
                        .foregroundStyle(Palette.textMuted)
                }
            }
            Text(headline)
                .font(Typography.headline)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if request.kind == .sudo {
                Text(request.sudo?.command ?? request.title)
                    .font(Typography.mono(13))
                    .foregroundStyle(Palette.codeText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Palette.code, in: .rect(cornerRadius: 12))
            } else if !request.detail.isEmpty {
                Text(request.detail)
                    .font(Typography.subheadline)
                    .foregroundStyle(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
            if let done {
                Label(done, systemImage: "checkmark.circle.fill")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.done)
            } else if let error {
                Text(error).font(Typography.footnote).foregroundStyle(Palette.errorText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private var label: String {
        request.kind == .sudo
            ? String(localized: "sudo on \(environment.label)")
            : String(localized: "Unlock on \(environment.label)")
    }

    private var headline: String {
        switch request.kind {
        case .sudo: String(localized: "Run as root?")
        case .prompt: request.title.isEmpty ? String(localized: "A password prompt is open") : request.title
        }
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(spacing: 8) {
            if request.kind == .sudo {
                if SudoKey.publicKey == nil || !sync.sudoSetup.approvesHere {
                    Text("This phone isn't set up to approve sudo here yet.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                }
                primaryButton(String(localized: "Approve with Face ID"), id: "approve") {
                    try await sync.approve(request)
                }
            } else {
                // A saved password the Mac turned down (changed there) is typed afresh.
                let stored = request.secretKinds.filter {
                    MacSecret.has($0, environmentId: environment.id) && !MacSecret.isStale($0, environmentId: environment.id)
                }
                if request.secretKinds.isEmpty {
                    Text("This prompt only takes Touch ID.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.textMuted)
                } else if stored.isEmpty || typing {
                    passwordField(for: typedKind ?? request.secretKinds[0])
                } else {
                    primaryButton(String(localized: "Unlock with Face ID"), id: stored[0].rawValue) {
                        try await sync.approve(request, with: stored[0])
                    }
                    ForEach(stored.dropFirst()) { kind in
                        Button {
                            run(kind.rawValue) { try await sync.approve(request, with: kind) }
                        } label: {
                            Text("Use \(kind.title)").font(Typography.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    Button {
                        typedKind = stored[0]
                        typing = true
                    } label: {
                        Text("Type the password").font(Typography.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            Button {
                run("deny") {
                    try await sync.deny(request)
                    return String(localized: "Cancelled.")
                }
            } label: {
                Group {
                    if busy == "deny" { ProgressView() } else {
                        Text(request.kind == .sudo ? String(localized: "Decline") : String(localized: "Cancel on the Mac"))
                    }
                }
                .font(Typography.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .foregroundStyle(Palette.errorText)
        }
        .disabled(busy != nil || done != nil)
    }

    /// The password typed into the card; once it works, the phone offers to keep it for Face ID.
    @ViewBuilder
    private func passwordField(for kind: MacSecret.Kind) -> some View {
        let kinds = request.secretKinds
        if kinds.count > 1 {
            Picker("Password", selection: Binding(get: { typedKind ?? kinds[0] }, set: { typedKind = $0 })) {
                ForEach(kinds) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        HStack(spacing: 8) {
            SecureField(kind.title, text: $password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($passwordFocused)
                .onSubmit { submitTyped(kind) }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Palette.code, in: .capsule)
            Button {
                submitTyped(kind)
            } label: {
                Group {
                    if busy == "typed" { ProgressView() } else { Text("Unlock") }
                }
                .font(Typography.headline)
                .frame(minWidth: 72, minHeight: 28)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.accent)
            .foregroundStyle(Palette.accentForeground)
            .disabled(password.isEmpty)
        }
        .onAppear { passwordFocused = true }
    }

    private func submitTyped(_ kind: MacSecret.Kind) {
        guard !password.isEmpty, busy == nil else { return }
        let typed = password
        password = ""
        run("typed") { try await sync.approve(request, with: kind, typed: typed) }
    }

    private func primaryButton(_ title: String, id: String, action: @escaping () async throws -> String) -> some View {
        Button {
            run(id, action)
        } label: {
            Group {
                if busy == id { ProgressView() } else { Label(title, systemImage: "faceid") }
            }
            .font(Typography.headline)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
        .foregroundStyle(Palette.accentForeground)
    }

    private func run(_ id: String, _ action: @escaping () async throws -> String) {
        busy = id
        error = nil
        Task {
            do {
                done = try await action()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch let failure as MacAuthSync.AnswerError {
                if case .noPassword = failure { typing = true }
                error = failure.errorDescription
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
        }
    }
}

/// Settings → a computer → Face ID: sudo approval and the passwords typed into its prompts.
struct MacAuthSettingsView: View {
    let environment: EnvironmentSession
    @State private var editing: MacSecret.Kind?
    @State private var draft = ""
    @State private var stored: Set<MacSecret.Kind> = []
    @State private var error: String?
    @State private var registering = false
    @State private var copied = false

    private var sync: MacAuthSync { environment.macAuth }

    var body: some View {
        HelmForm {
            if !sync.available {
                Section {
                    Text(environment.isLive
                         ? String(localized: "Helm on this computer is too old for this. Update it.")
                         : String(localized: "Connect to this computer to set this up."))
                        .foregroundStyle(Palette.textMuted)
                }
            }
            sudoSection
            Section {
                ForEach(MacSecret.Kind.allCases) { kind in
                    HStack {
                        Text(kind.title)
                        Spacer()
                        if stored.contains(kind) {
                            Text("Saved").font(Typography.footnote).foregroundStyle(Palette.done)
                        }
                        Menu {
                            Button(stored.contains(kind) ? "Replace…" : "Save…") {
                                draft = ""
                                editing = kind
                            }
                            if stored.contains(kind) {
                                Button("Remove", role: .destructive) {
                                    MacSecret.remove(kind, environmentId: environment.id)
                                    refresh()
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(Palette.textMuted)
                        }
                    }
                }
            } header: {
                Text("Passwords for prompts").sectionLabelStyle()
            } footer: {
                Text(promptsFooter).font(Typography.footnote)
            }
            if let error {
                Section { Text(error).foregroundStyle(Palette.errorText) }
            }
        }
        .font(Typography.body)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Face ID for the Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .alert(editing?.title ?? "", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            SecureField("Password", text: $draft)
            Button("Save") {
                if let kind = editing, !draft.isEmpty {
                    do {
                        try MacSecret.save(draft, as: kind, environmentId: environment.id)
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                draft = ""
                editing = nil
                refresh()
            }
            Button("Cancel", role: .cancel) { draft = ""; editing = nil }
        } message: {
            Text("Kept on this phone behind Face ID. It goes to the Mac only to fill a prompt you approve, sealed for that prompt.")
        }
    }

    @ViewBuilder
    private var sudoSection: some View {
        Section {
            HStack {
                Text("sudo asks this phone")
                Spacer()
                StatusValue(text: sync.sudoSetup.approvesHere ? String(localized: "On") : String(localized: "Off"),
                            isOn: sync.sudoSetup.approvesHere)
            }
            if !sync.sudoSetup.approvesHere {
                if SudoKey.publicKey == nil || !sync.sudoSetup.approvers.contains(SudoKey.publicKey ?? "") {
                    Button {
                        registering = true
                        Task {
                            do { try await sync.registerSudoKey() } catch { self.error = error.localizedDescription }
                            registering = false
                        }
                    } label: {
                        HStack {
                            Text("1. Create this phone's key")
                            if registering { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!sync.available || registering)
                }
                if !sync.sudoSetup.setupCommand.isEmpty {
                    Button {
                        UIPasteboard.general.string = sync.sudoSetup.setupCommand
                        copied = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(copied ? "2. Copied. Run it in a terminal on the Mac" : "2. Run in a terminal on the Mac")
                            Text(sync.sudoSetup.setupCommand)
                                .font(Typography.mono(13))
                                .foregroundStyle(Palette.codeText)
                        }
                    }
                }
            }
        } header: {
            Text("sudo").sectionLabelStyle()
        } footer: {
            Text("sudo in a terminal, or in an agent's shell, waits for Face ID here. Only this phone's Secure Enclave key can approve; if the phone doesn't answer, sudo asks for the password as usual. The setup asks for the Mac's password once.")
                .font(Typography.footnote)
        }
    }

    private var promptsFooter: String {
        let base = String(localized: "When a Touch ID or password sheet opens on the Mac (1Password unlocking, an app asking for your login password), Helm shows it here and types the password after Face ID.")
        guard sync.available, !sync.promptsAvailable else { return base }
        return base + " " + String(localized: "Helm on the Mac needs Accessibility access for this: System Settings → Privacy & Security → Accessibility.")
    }

    private func refresh() {
        stored = Set(MacSecret.Kind.allCases.filter { MacSecret.has($0, environmentId: environment.id) })
    }
}
