import Foundation
import Network
import Observation

/// Paired Macs on the same local network as this phone. Helm's server announces itself over
/// Bonjour (`_helm._tcp`, its environment id in the TXT record); a Mac reached only over
/// Tailscale or from another Wi-Fi never shows up here. Browses only while the app is open.
/// Each one found is also resolved to its address on this network, so a session can reach it
/// directly while the built-in Tailscale node is still coming up.
@MainActor
@Observable
final class NearbyMacs {
    static let shared = NearbyMacs()
    static let serviceType = "_helm._tcp"

    /// Environment ids of the Helm servers seen on this network.
    private(set) var environmentIds: Set<String> = []
    /// `http://<LAN address>:<port>/` of each nearby Helm server, once resolved.
    @ObservationIgnored private(set) var addresses: [String: URL] = [:]

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]
    /// The app is open; a failed browser comes back only then.
    @ObservationIgnored private var wanted = false

    func contains(_ environmentId: String) -> Bool { environmentIds.contains(environmentId) }

    func address(_ environmentId: String) -> URL? { addresses[environmentId] }

    func start() {
        wanted = true
        guard browser == nil, !AppModel.isUnitTestHost else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { result -> (id: String, endpoint: NWEndpoint)? in
                guard case .bonjour(let txt) = result.metadata, let id = txt["environmentId"] else { return nil }
                return (id, result.endpoint)
            }
            Task { @MainActor in NearbyMacs.shared.update(found) }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ConnectionLog.shared.log("nearby", "looking for computers on this network")
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
        addresses = [:]
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        Task {
            try? await Task.sleep(for: .seconds(5))
            if wanted { start() }
        }
    }

    private func update(_ found: [(id: String, endpoint: NWEndpoint)]) {
        let ids = Set(found.map(\.id))
        for id in addresses.keys where !ids.contains(id) { addresses[id] = nil }
        for (id, connection) in resolving where !ids.contains(id) {
            connection.cancel()
            resolving[id] = nil
        }
        for (id, endpoint) in found where addresses[id] == nil && resolving[id] == nil {
            resolve(id, endpoint)
        }
        guard ids != environmentIds else { return }
        ConnectionLog.shared.log("nearby", ids.isEmpty ? "no Mac on this network" : "\(ids.count) Mac(s) on this network")
        environmentIds = ids
    }

    /// Opens a TCP connection to the Bonjour service just to learn its IPv4 address and port.
    private func resolve(_ id: String, _ endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[id] = connection
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint
                connection.cancel()
                Task { @MainActor in NearbyMacs.shared.resolved(id, remote, by: connection) }
            case .failed(let error), .waiting(let error):
                connection.cancel()
                Task { @MainActor in NearbyMacs.shared.resolved(id, nil, by: connection, error: error) }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func resolved(_ id: String, _ remote: NWEndpoint?, by connection: NWConnection, error: NWError? = nil) {
        guard resolving[id] === connection else { return }
        resolving[id] = nil
        guard case .hostPort(let host, let port) = remote, let url = Self.url(host: host, port: port) else {
            ConnectionLog.shared.log("nearby", "could not resolve \(id.prefix(8))'s address" + (error.map { ": \($0)" } ?? ""))
            return
        }
        ConnectionLog.shared.log("nearby", "\(id.prefix(8)) at \(url.host ?? "?"):\(port.rawValue)")
        addresses[id] = url
    }

    private static func url(host: NWEndpoint.Host, port: NWEndpoint.Port) -> URL? {
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .ipv6(let address): text = "[\("\(address)".split(separator: "%").first.map(String.init) ?? "\(address)")]"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return URL(string: "http://\(text):\(port.rawValue)/")
    }
}
