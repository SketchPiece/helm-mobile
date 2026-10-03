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
    @FocusState private var focused: Field?

    enum Field { case address, code }

    enum Phase: Equatable {
        case idle
        case working(String)
        case waitingForApproval
        case failed(String)
    }

    var body: some View {
        Form {
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
                Text("Paste a pairing link into the address field, or leave the code empty to approve this phone on the Mac (Tailscale, same account).")
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
                            Text("Allow it in Helm on the Mac")
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
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.errorText)
                }
            }

            if DataScannerViewController.isSupported {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("On the Mac: Helm → Settings → Connections → Pair a device.")
                        .font(Typography.footnote)
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
        .onAppear { focused = .address }
    }

    private var isBusy: Bool {
        switch phase {
        case .working, .waitingForApproval: true
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
                    try await requestApproval(address: address)
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

    /// Helm's tailnet pairing: the Mac shows "allow this phone?", we poll until it answers.
    private func requestApproval(address: String) async throws {
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
                return
            case .denied: throw PairingError.denied
            case .expired: throw PairingError.expired
            }
        }
        throw PairingError.expired
    }

    enum PairingError: LocalizedError {
        case needsCode, denied, expired
        var errorDescription: String? {
            switch self {
            case .needsCode:
                String(localized: "This Helm can't approve phones directly. Enter the pairing code from Settings → Connections.")
            case .denied: String(localized: "Helm on the Mac said no.")
            case .expired: String(localized: "Nobody answered on the Mac. Try again.")
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
