import Foundation
import Security

/// A paired Helm server. The bearer lives in the Keychain; the rest in UserDefaults.
struct SavedEnvironment: Codable, Identifiable, Hashable, Sendable {
    var id: String  // environmentId
    var label: String
    var baseURL: URL
    var pairedAt: Date
}

enum SavedEnvironments {
    private static let key = "helm.environments.v1"

    static func load() -> [SavedEnvironment] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedEnvironment].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [SavedEnvironment]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum Keychain {
    private static let service = "com.sketchpiece.helmnative.bearer"

    static func token(for environmentId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String?, for environmentId: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: environmentId,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
