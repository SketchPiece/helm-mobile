import Foundation
import UIKit

/// Where to reach a Helm server and the one-time code that pairs with it.
struct PairingTarget: Equatable, Sendable {
    var baseURL: URL
    var code: String

    /// Accepts a pairing link (`http://host:3783/pair#token=CODE`, `?token=` also works, and the
    /// hosted `https://app.t3.codes/pair?host=…#token=…` form) or a bare host plus a code.
    static func parse(link: String) -> PairingTarget? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme)
        else { return nil }
        let fragmentItems = URLComponents(string: "x://x?\(components.fragment ?? "")")?.queryItems ?? []
        let queryItems = components.queryItems ?? []
        guard let code = (fragmentItems + queryItems).first(where: { $0.name == "token" })?.value,
              !code.isEmpty
        else { return nil }
        if let host = queryItems.first(where: { $0.name == "host" })?.value,
           let base = normalizeHost(host, defaultScheme: "https")
        {
            return PairingTarget(baseURL: base, code: code)
        }
        var origin = URLComponents()
        origin.scheme = (scheme == "wss" || scheme == "https") ? "https" : "http"
        origin.host = components.host
        origin.port = components.port
        origin.path = "/"
        guard let base = origin.url, components.host != nil else { return nil }
        return PairingTarget(baseURL: base, code: code)
    }

    static func manual(host: String, code: String) -> PairingTarget? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let base = normalizeHost(host, defaultScheme: nil) else { return nil }
        return PairingTarget(baseURL: base, code: code)
    }

    /// `192.168.1.5:3783` → http, `mac.tailnet.ts.net` → http (Helm serves plain http on the
    /// tailnet), anything else without a scheme → https. The default port for a bare tailnet or
    /// LAN address is Helm's 3783.
    static func normalizeHost(_ raw: String, defaultScheme: String?) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            let hostPart = text.split(separator: "/").first.map(String.init) ?? text
            let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
            let isLocal = isIPAddress(hostOnly) || hostOnly.hasSuffix(".ts.net") || hostOnly.hasSuffix(".local")
                || !hostOnly.contains(".")
            let scheme = defaultScheme ?? (isLocal ? "http" : "https")
            text = "\(scheme)://\(text)"
            if isLocal, !hostPart.contains(":") { text = "\(scheme)://\(hostOnly):3783" }
        }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        if components.scheme == "ws" { components.scheme = "http" }
        if components.scheme == "wss" { components.scheme = "https" }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } || host.contains(":")
    }
}

struct EnvironmentDescriptor: Codable, Equatable, Sendable {
    var environmentId: String
    var label: String
    var serverVersion: String?
    var orchestrationProtocolVersion: Int?
}

enum HelmHTTPError: Error, LocalizedError {
    case unreachable(String)
    case status(Int, String)
    case incompatible(Int?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            String(localized: "Couldn't reach Helm on that address.") + " " + detail
        case .status(let code, let message):
            code == 401 || code == 400
                ? String(localized: "The pairing code was rejected. Codes work once and expire after 5 minutes.")
                : "HTTP \(code): \(message)"
        case .incompatible:
            String(localized: "This Helm server is too old or too new for this app.")
        case .invalidResponse:
            String(localized: "Helm answered with something unexpected.")
        }
    }
}

/// Plain HTTP calls to a Helm server: the descriptor, pairing, websocket tickets and the
/// Helm-only tailnet pairing route.
struct HelmHTTP: Sendable {
    var baseURL: URL
    var token: String?

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static let mobileScopes = "orchestration:read orchestration:operate terminal:operate review:write relay:read"

    /// Every request, the WebSocket and asset URLs come through here, so this is the one place
    /// tailnet addresses get routed through the built-in Tailscale node when it is in use.
    func url(_ path: String) -> URL {
        TailnetRouting.route(URL(string: path, relativeTo: baseURL)!.absoluteURL)
    }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
        return request
    }

    func send(_ request: URLRequest) async throws -> JSON {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw HelmHTTPError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw HelmHTTPError.invalidResponse }
        let json = (try? JSON.parse(data)) ?? .null
        guard (200..<300).contains(http.statusCode) else {
            let message = json["reason"]?.string ?? json["message"]?.string ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw HelmHTTPError.status(http.statusCode, message)
        }
        return json
    }

    func descriptor() async throws -> EnvironmentDescriptor {
        let json = try await send(request("/.well-known/t3/environment"))
        guard let descriptor = try? json.decode(EnvironmentDescriptor.self) else { throw HelmHTTPError.invalidResponse }
        guard descriptor.orchestrationProtocolVersion == 2 else {
            throw HelmHTTPError.incompatible(descriptor.orchestrationProtocolVersion)
        }
        return descriptor
    }

    /// RFC 8693 token exchange: the one-time pairing code becomes a 30-day bearer.
    func exchange(code: String) async throws -> String {
        var request = request("/oauth/token", method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields: [(String, String)] = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", code),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("scope", Self.mobileScopes),
            ("client_label", "Helm on \(await UIDevice.current.name)"),
            ("client_device_type", "mobile"),
            ("client_os", "iOS"),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let json = try await send(request)
        guard let token = json["access_token"]?.string else { throw HelmHTTPError.invalidResponse }
        return token
    }

    func webSocketTicket() async throws -> String {
        let json = try await send(request("/api/auth/websocket-ticket", method: "POST"))
        guard let ticket = json["ticket"]?.string else { throw HelmHTTPError.invalidResponse }
        return ticket
    }

    func isAuthenticated() async -> Bool? {
        guard let json = try? await send(request("/api/auth/session")) else { return nil }
        return json["authenticated"]?.bool
    }

    func webSocketURL(ticket: String) async -> URL {
        var components = URLComponents(url: url("/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        let device = await UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        components.queryItems = [
            URLQueryItem(name: "wsTicket", value: ticket),
            URLQueryItem(name: "orchestrationProtocol", value: "2"),
            URLQueryItem(name: "clientSurface", value: "mobile"),
            URLQueryItem(name: "clientAppVersion", value: version),
            URLQueryItem(name: "clientDeviceType", value: "phone"),
            URLQueryItem(name: "clientOs", value: "iOS"),
            URLQueryItem(name: "clientOsMajorVersion", value: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)),
            URLQueryItem(name: "clientDeviceModel", value: await device.model),
            URLQueryItem(name: "connectionMethod", value: "direct"),
        ]
        return components.url!
    }

    // MARK: Helm tailnet pairing (apps/server/src/helm/tailnetPairRoute.ts)

    /// True when a Helm server answers the tailnet pairing probe on this base URL.
    func probeTailnetPairing() async -> Bool {
        var request = request("/api/helm/tailnet-pair?id=probe")
        request.timeoutInterval = 4
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true
        else { return false }
        return (try? JSON.parse(data)) != nil
    }

    func requestTailnetPairing(label: String) async throws -> String {
        var request = request("/api/helm/tailnet-pair", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSON.object(["label": .string(label)]).data()
        let json = try await send(request)
        guard let id = json["requestId"]?.string else { throw HelmHTTPError.invalidResponse }
        return id
    }

    enum TailnetPairStatus: Equatable { case pending, approved(String), denied, expired }

    func tailnetPairingStatus(id: String) async throws -> TailnetPairStatus {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        let json = try await send(request("/api/helm/tailnet-pair?id=\(escaped)"))
        switch json["status"]?.string {
        case "approved":
            guard let credential = json["credential"]?.string else { throw HelmHTTPError.invalidResponse }
            return .approved(credential)
        case "denied": return .denied
        case "expired": return .expired
        default: return .pending
        }
    }
}
