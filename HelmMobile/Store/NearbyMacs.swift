import Foundation
import Network
import Observation

/// Paired Macs on the same local network as this phone. Helm's server announces itself over
/// Bonjour (`_helm._tcp`, its environment id in the TXT record); a Mac reached only over
/// Tailscale or from another Wi-Fi never shows up here. Browses only while the app is open.
@MainActor
@Observable
final class NearbyMacs {
    static let shared = NearbyMacs()
    static let serviceType = "_helm._tcp"

    /// Environment ids of the Helm servers seen on this network.
    private(set) var environmentIds: Set<String> = []

    @ObservationIgnored private var browser: NWBrowser?
    /// The app is open; a failed browser comes back only then.
    @ObservationIgnored private var wanted = false

    func contains(_ environmentId: String) -> Bool { environmentIds.contains(environmentId) }

    func start() {
        wanted = true
        guard browser == nil, !AppModel.isUnitTestHost else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let ids = Set(results.compactMap { result -> String? in
                guard case .bonjour(let txt) = result.metadata else { return nil }
                return txt["environmentId"]
            })
            Task { @MainActor in NearbyMacs.shared.update(ids) }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error), .waiting(let error):
                ConnectionLog.shared.log("nearby", "browsing: \(error)")
                if case .failed = state { Task { @MainActor in NearbyMacs.shared.restart() } }
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        wanted = false
        browser?.cancel()
        browser = nil
        environmentIds = []
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        Task {
            try? await Task.sleep(for: .seconds(5))
            if wanted { start() }
        }
    }

    private func update(_ ids: Set<String>) {
        guard ids != environmentIds else { return }
        ConnectionLog.shared.log("nearby", ids.isEmpty ? "no Mac on this network" : "\(ids.count) Mac(s) on this network")
        environmentIds = ids
    }
}
