import SwiftUI
import UIKit
import VisionKit

/// Connect a Helm server. Three ways in, one screen: scan the QR code, paste the pairing link,
/// or type the address. With an address and no code, Helm on the Mac is asked to approve this
/// phone (works over Tailscale for the Mac's own account).
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var code = ""
    @State private var phase = Phase.idle
    @State private var showScanner = false
    @State private var found: [FoundHelm] = []
    /// Allowed on the Mac over the local network: the code it shows goes back with this request.
    @State private var codeRequest: CodeRequest?
    @State private var shownCode = ""
    @State private var wrongCode = false

    struct CodeRequest: Equatable {
        var id: String
        var base: URL
    }

    struct FoundHelm: Identifiable, Hashable {
        var host: String
        var label: String
        /// Seen on the local network only.
        var local = false
        /// A Helm that approves devices only over Tailscale: on the local network it takes the
        /// pairing code from Settings.
        var needsCode = false
        var id: String { host }
    }
    @FocusState private var focused: Field?

    enum Field { case address, code, shownCode }

    enum Phase: Equatable {
        case idle
        case working(String)
        case waitingForApproval
        case enteringCode
        case failed(String)
    }

    var body: some View {
        HelmForm {
            if codeRequest != nil {
                Section {
                    TextField("0000", text: $shownCode)
                        .font(Typography.mono(34))
                        .multilineTextAlignment(.center)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused, equals: .shownCode)
                        .accessibilityIdentifier("shownCode")
                        .onChange(of: shownCode) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(4))
                            if digits != value { shownCode = digits }
                            if !digits.isEmpty { wrongCode = false }
                            if digits.count == 4 { confirmShownCode() }
                        }
                } header: {
                    Text("Code on the computer").sectionLabelStyle()
                } footer: {
                    if wrongCode {
                        Text("That's not the code on the computer. Try again.")
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.errorText)
                    } else {
                        Text("Helm on the computer shows four digits. Type them here to finish connecting.")
                            .font(Typography.footnote)
                    }
                }
            }
            if !found.isEmpty {
                Section {
                    ForEach(found) { helm in
                        Button {
                            address = helm.host
                            code = ""
                            if helm.needsCode { focused = .code } else { connect() }
                        } label: {
                            HStack(spacing: 12) {
                                HelmMark(size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(helm.label).font(Typography.bodyMedium).foregroundStyle(Palette.text)
                                    Text(helm.host).font(Typography.mono(12)).foregroundStyle(Palette.textMuted)
                                }
                                Spacer()
                                Text(helm.needsCode ? "Enter code" : "Connect")
                                    .font(Typography.subheadline.weight(.semibold))
                                    .foregroundStyle(Palette.accentText)
                            }
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier("foundHelm")
                    }
                } header: {
                    Text(found.allSatisfy(\.needsCode) ? "Found on this network" : "Found nearby").sectionLabelStyle()
                } footer: {
                    if found.contains(where: \.needsCode) {
                        Text("On the local network Helm needs the pairing code: on the computer, Helm → Settings → Connections → Pair a device. Over Tailscale it asks you to allow this phone instead.")
                            .font(Typography.footnote)
                    } else if found.contains(where: \.local) {
                        Text("Helm on the computer asks you to allow this device, then shows a code to type here.")
                            .font(Typography.footnote)
                    } else {
                        Text("Helm on the computer asks you to allow this phone. No code needed.")
                            .font(Typography.footnote)
                    }
                }
            }

            if DataScannerViewController.isSupported {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                            .font(Typography.bodyMedium)
                    }
                } footer: {
                    Text("On the computer: Helm → Settings → Connections → Pair a device.")
                        .font(Typography.footnote)
                }
            }

            Section {
                TextField("100.64.0.1 or my-mac.tailnet.ts.net", text: $address)
                    .font(Typography.mono(16))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focused = .code }
                    .onChange(of: address) { _, value in absorbLink(value) }
                TextField("Pairing code (optional)", text: $code)
                    .font(Typography.mono(16))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .code)
                    .submitLabel(.go)
                    .onSubmit(connect)
            } header: {
                Text("Address").sectionLabelStyle()
            } footer: {
                Text("Paste a pairing link into the address field, or leave the code empty to approve this phone on the computer (Tailscale, same account).")
                    .font(Typography.footnote)
            }

            Section {
                Button(action: connect) {
                    HStack {
                        Spacer()
                        switch phase {
                        case .working(let label):
                            ProgressView().padding(.trailing, 6)
                            Text(label)
                        case .waitingForApproval:
                            ProgressView().padding(.trailing, 6)
                            Text("Allow it in Helm on the computer")
                        case .enteringCode:
                            Text("Type the code from the computer")
                        default:
                            Text(code.isEmpty ? "Ask Helm to allow this phone" : "Connect")
                        }
                        Spacer()
                    }
                    .font(Typography.headline)
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
                if case .failed(let message) = phase {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .labelStyle(.tight)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }

            Section {
                Button {
                    if let text = UIPasteboard.general.string { address = text }
                } label: {
                    Label("Paste pairing link", systemImage: "doc.on.clipboard")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Connect to Helm")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .cancel) { dismiss() }
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { payload in
                showScanner = false
                address = payload
            }
            .ignoresSafeArea()
        }
        .task { await discover() }
        // The local network answers later (and only once iOS has asked to allow it).
        .onChange(of: NearbyMacs.shared.environmentIds) { Task { await discover() } }
    }

    /// Probes for Helm: the Macs baked into this build, every online computer the built-in
    /// Tailscale node can see (Helm listens on 3783 and up; T3 Code on 3773), and the Helm servers
    /// announcing themselves on this network over Bonjour.
    private func discover() async {
        var hosts = (Bundle.main.object(forInfoDictionaryKey: "HelmSuggestedHosts") as? String ?? "")
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if model.tailscale.isRunning {
            for peer in model.tailscale.peers where peer.isComputer && peer.online {
                for port in [3783, 3784, 3785, 3773] where !hosts.contains("\(peer.address):\(port)") {
                    hosts.append("\(peer.address):\(port)")
                }
            }
        }
        let tailnetHosts = Set(hosts)
        hosts += await nearbyHosts().filter { !tailnetHosts.contains($0) }
        let paired = Set(model.environments.map(\.id))
        var byEnvironment: [String: FoundHelm] = [:]
        await withTaskGroup(of: (FoundHelm, String)?.self) { group in
            for host in hosts {
                let local = !tailnetHosts.contains(host)
                group.addTask {
                    guard let base = PairingTarget.normalizeHost(host, defaultScheme: nil) else { return nil }
                    let http = HelmHTTP(baseURL: base, token: nil)
                    guard let descriptor = try? await http.descriptor(), !paired.contains(descriptor.environmentId) else { return nil }
                    // An older Helm approves only over Tailscale; a newer one, with a code, here too.
                    let needsCode = local ? !(await http.probeTailnetPairing()) : false
                    return (FoundHelm(host: host, label: descriptor.label, local: local, needsCode: needsCode),
                            descriptor.environmentId)
                }
            }
            // One row per Mac; its tailnet address wins, since there it can approve without a code.
            for await result in group {
                guard let (helm, environmentId) = result else { continue }
                if let existing = byEnvironment[environmentId], !existing.local { continue }
                byEnvironment[environmentId] = helm
            }
        }
        let results = byEnvironment.values.sorted { $0.label < $1.label }
        withAnimation { found = results }
        if results.isEmpty, focused == nil { focused = .address }
    }

    /// `host:port` of the Helm servers on this network, waiting a moment for their addresses.
    private func nearbyHosts() async -> [String] {
        let nearby = NearbyMacs.shared
        nearby.start()
        for _ in 0..<15 where nearby.environmentIds.contains(where: { nearby.address($0) == nil }) || nearby.environmentIds.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nearby.environmentIds.compactMap { nearby.address($0) }.compactMap { url in
            guard let host = url.host(), let port = url.port else { return nil }
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .working, .waitingForApproval, .enteringCode: true
        default: false
        }
    }

    /// A pasted or scanned pairing link fills both fields and connects right away.
    private func absorbLink(_ value: String) {
        guard value.contains("token="), let target = PairingTarget.parse(link: value) else { return }
        var host = target.baseURL.host() ?? ""
        if let port = target.baseURL.port { host += ":\(port)" }
        address = host
        code = target.code
        connect()
    }

    private func connect() {
        guard !isBusy else { return }
        let address = address
        let code = code
        Task {
            do {
                if code.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Over the local network the Mac's answer is a code to type, not the pairing yet.
                    guard try await requestApproval(address: address) else { return }
                } else {
                    guard let target = PairingTarget.manual(host: address, code: code) else {
                        phase = .failed(String(localized: "That address doesn't look right."))
                        return
                    }
                    phase = .working(String(localized: "Connecting…"))
                    try await model.pair(target)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                router.showPairing = false
                dismiss()
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Helm's own pairing: the Mac shows "allow this phone?", we poll until it answers. True once
    /// paired; false when the Mac allowed it over the local network and now shows a code to type.
    private func requestApproval(address: String) async throws -> Bool {
        guard let base = PairingTarget.normalizeHost(address, defaultScheme: nil) else {
            throw HelmHTTPError.unreachable("")
        }
        phase = .working(String(localized: "Looking for Helm…"))
        let http = HelmHTTP(baseURL: base, token: nil)
        _ = try await http.descriptor()
        guard await http.probeTailnetPairing() else {
            throw PairingError.needsCode
        }
        let requestId = try await http.requestTailnetPairing(label: UIDevice.current.name)
        phase = .waitingForApproval
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            switch try await http.tailnetPairingStatus(id: requestId) {
            case .pending: continue
            case .approved(let credential):
                phase = .working(String(localized: "Connecting…"))
                try await model.pair(PairingTarget(baseURL: base, code: credential))
                return true
            case .enterCode, .wrongCode:
                shownCode = ""
                codeRequest = CodeRequest(id: requestId, base: base)
                phase = .enteringCode
                focused = .shownCode
                return false
            case .denied: throw PairingError.denied
            case .expired: throw PairingError.expired
            }
        }
        throw PairingError.expired
    }

    /// The four digits from the Mac's screen: a match brings the credential, and pairing finishes.
    private func confirmShownCode() {
        guard let request = codeRequest else { return }
        let entered = shownCode
        Task {
            do {
                let http = HelmHTTP(baseURL: request.base, token: nil)
                switch try await http.confirmTailnetPairing(id: request.id, code: entered) {
                case .approved(let credential):
                    phase = .working(String(localized: "Connecting…"))
                    try await model.pair(PairingTarget(baseURL: request.base, code: credential))
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    router.showPairing = false
                    dismiss()
                case .wrongCode, .enterCode, .pending:
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    shownCode = ""
                    wrongCode = true
                    phase = .enteringCode
                case .denied:
                    codeRequest = nil
                    throw PairingError.denied
                case .expired:
                    codeRequest = nil
                    throw PairingError.expired
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                codeRequest = nil
                phase = .failed(error.localizedDescription)
            }
        }
    }

    enum PairingError: LocalizedError {
        case needsCode, denied, expired
        var errorDescription: String? {
            switch self {
            case .needsCode:
                String(localized: "This Helm can't approve phones directly. Enter the pairing code from Settings → Connections.")
            case .denied: String(localized: "Helm on the computer said no.")
            case .expired: String(localized: "Nobody answered on the computer. Try again.")
            }
        }
    }
}

/// VisionKit QR scanner; reports the first barcode payload.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var done = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    onScan(payload)
                    return
                }
            }
        }
    }
}
