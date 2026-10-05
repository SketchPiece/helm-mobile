import Foundation
import Observation
import UIKit

/// Rewrites tailnet URLs to the in-app node's loopback forwarders. Off until this phone has
/// logged in to the built-in node, so the Tailscale VPN app keeps working on its own.
enum TailnetRouting {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabledFlag = false

    static var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabledFlag }
        set { lock.lock(); enabledFlag = newValue; lock.unlock() }
    }

    /// 100.64.0.0/10, Tailscale's IPv6 range, or a MagicDNS name.
    static func isTailnetHost(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower.hasSuffix(".ts.net") || lower.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Plain http/ws to a tailnet host goes through the node; TLS can't be re-pointed at
    /// loopback, and everything else is left alone.
    static func route(_ url: URL) -> URL {
        guard isEnabled, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "ws",
              let host = components.host, isTailnetHost(host)
        else { return url }
        let port = components.port ?? 80
        let local: Int
        do {
            local = try TailnetNode.shared.forward(host: host, port: port)
        } catch {
            ConnectionLog.shared.log("tailscale", "no loopback forwarder for \(host):\(port), going direct: \(error.localizedDescription)")
            return url
        }
        components.host = "127.0.0.1"
        components.port = local
        return components.url ?? url
    }

    /// True when requests to this address go through the built-in node.
    static func usesNode(_ url: URL) -> Bool {
        guard isEnabled, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "ws",
              let host = url.host
        else { return false }
        return isTailnetHost(host)
    }

    /// Right after launch the node needs a few seconds to come up; a connection tried before
    /// that is refused. Waits up to `timeout` and returns whether it is running.
    static func waitForNode(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if await Task.detached(operation: { TailnetNode.shared.isRunning() }).value { return true }
            if ContinuousClock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

struct TailnetPeer: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var address: String
    var os: String
    var online: Bool

    var isComputer: Bool { ["macos", "linux", "windows", "freebsd", "openbsd"].contains(os.lowercased()) }
}

/// The built-in Tailscale node, as the app sees it.
@MainActor
@Observable
final class TailscaleService {
    enum State: Equatable {
        case off
        case starting
        case needsLogin(URL?)
        case running(tailnet: String, phone: String, address: String)
        case failed(String)

        var logLabel: String {
            switch self {
            case .off: "off"
            case .starting: "starting"
            case .needsLogin: "needs login"
            case .running(let tailnet, _, let address): "running (\(tailnet), \(address))"
            case .failed(let message): "failed: \(message)"
            }
        }
    }

    private(set) var state = State.off {
        didSet {
            guard state.logLabel != oldValue.logLabel else { return }
            ConnectionLog.shared.log("tailscale", "node \(state.logLabel)")
        }
    }
    private(set) var peers: [TailnetPeer] = []
    /// Called once the node reaches Running, so dropped connections retry immediately.
    var onRunning: (() -> Void)?

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var openedAuthURL: URL?
    @ObservationIgnored private var watchers = 0

    var isRunning: Bool { if case .running = state { true } else { false } }
    var hasLogin: Bool { TailnetNode.shared.hasState }

    /// Set once the node has reached Running; a login abandoned halfway must not cut the
    /// app off from Macs it can reach through the Tailscale VPN app.
    private static let loggedInKey = "tailscale.loggedIn"

    /// At launch: a phone that logged in before starts its node and routes through it.
    func startIfConfigured() {
        guard TailnetNode.shared.hasState else { return }
        TailnetRouting.isEnabled = UserDefaults.standard.bool(forKey: Self.loggedInKey)
        start()
    }

    func start() {
        state = .starting
        let hostname = Self.hostname
        Task.detached {
            do {
                try TailnetNode.shared.start(hostname: hostname)
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
                return
            }
            await self.refresh()
        }
        ensurePolling()
    }

    func logout() {
        poller?.cancel()
        poller = nil
        TailnetRouting.isEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.loggedInKey)
        Task.detached { TailnetNode.shared.logout() }
        state = .off
        peers = []
        openedAuthURL = nil
    }

    /// The settings screen polls while it is visible; otherwise polling stops once running.
    func watch() {
        watchers += 1
        ensurePolling()
    }

    func unwatch() { watchers = max(0, watchers - 1) }

    var authURL: URL? { if case .needsLogin(let url) = state { url } else { nil } }

    private func ensurePolling() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self else { return }
                if self.isRunning && self.watchers == 0 { break }
                try? await Task.sleep(for: .milliseconds(1500))
            }
            self?.poller = nil
        }
    }

    func refresh() async {
        let json = await Task.detached { try? TailnetNode.shared.statusJSON() }.value
        guard let json, let data = json.data(using: .utf8), let status = try? JSON.parse(data) else { return }
        let wasRunning = isRunning
        let backend = status["BackendState"]?.string ?? ""
        switch backend {
        case "Running":
            let me = status["Self"]
            state = .running(
                tailnet: status["CurrentTailnet"]?["Name"]?.string ?? "",
                phone: Self.displayName(me),
                address: me?["TailscaleIPs"]?[0]?.string ?? ""
            )
            TailnetRouting.isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.loggedInKey)
            peers = (status["Peer"]?.object?.values.map { $0 } ?? []).compactMap { peer in
                guard let address = peer["TailscaleIPs"]?.array?.compactMap(\.string).first(where: { !$0.contains(":") })
                        ?? peer["TailscaleIPs"]?[0]?.string
                else { return nil }
                return TailnetPeer(
                    id: peer["ID"]?.string ?? address,
                    name: Self.displayName(peer),
                    address: address,
                    os: peer["OS"]?.string ?? "",
                    online: peer["Online"]?.bool ?? false
                )
            }
            .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
            if !wasRunning { onRunning?() }
        case "NeedsLogin", "NeedsMachineAuth":
            let url = status["AuthURL"]?.string.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            state = .needsLogin(url)
        case "Starting", "NoState", "":
            if case .needsLogin = state {} else { state = .starting }
        default:
            state = .starting
        }
    }

    /// Opens a fresh login link once; "Open login again" passes force.
    func openLogin(force: Bool = false) {
        guard let url = authURL, force || url != openedAuthURL else { return }
        openedAuthURL = url
        UIApplication.shared.open(url)
    }

    private static func displayName(_ node: JSON?) -> String {
        if let dns = node?["DNSName"]?.string, let first = dns.split(separator: ".").first, !first.isEmpty {
            return String(first)
        }
        return node?["HostName"]?.string ?? "?"
    }

    /// One name per phone, so several devices don't collide as "helm-phone".
    private static var hostname: String {
        let base = UIDevice.current.name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let ascii = base.unicodeScalars.allSatisfy(\.isASCII) && !base.isEmpty ? base : "phone"
        return "helm-\(ascii.prefix(40))"
    }
}
