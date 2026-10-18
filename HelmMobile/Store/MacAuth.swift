import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import Security
import UIKit

/// The Mac asks this phone to confirm with Face ID (`helm.command` "auth.*", contracts/helmAuth.ts on the
/// Mac): `sudo` in a terminal or an agent's shell, or a Touch ID / password sheet on its screen
/// (1Password unlocking, an app asking for the login password).
struct MacAuthRequest: Identifiable, Equatable {
    enum Kind: String { case sudo, prompt }

    let id: String
    let kind: Kind
    /// "1Password", "System Settings", or "sudo".
    let app: String
    /// The sheet's first line, or the sudo command.
    let title: String
    let detail: String
    let createdAt: Date
    let expiresAt: Date?
    let sudo: Sudo?
    /// Stored passwords that can answer a prompt, best first.
    let secretKinds: [MacSecret.Kind]
    /// The Mac helper's key to seal the password to (base64 X9.63).
    let sealingKey: String?

    struct Sudo: Equatable {
        let nonce: String
        let user: String
        let host: String
        let command: String

        /// What the phone signs; pam_helm rebuilds the same bytes.
        var message: Data { Data("helm-sudo-v1\n\(nonce)\n\(user)\n\(host)\n\(command)".utf8) }
    }

    init?(_ json: JSON) {
        guard let id = json["id"]?.string, let kind = json["kind"]?.string.flatMap(Kind.init) else { return nil }
        self.id = id
        self.kind = kind
        app = json["app"]?.string ?? ""
        title = json["title"]?.string ?? ""
        detail = json["detail"]?.string ?? ""
        createdAt = Date(timeIntervalSince1970: (json["createdAt"]?.double ?? 0) / 1000)
        expiresAt = json["expiresAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let sudo = json["sudo"] {
            self.sudo = Sudo(
                nonce: sudo["nonce"]?.string ?? "", user: sudo["user"]?.string ?? "",
                host: sudo["host"]?.string ?? "", command: sudo["command"]?.string ?? "")
        } else {
            sudo = nil
        }
        secretKinds = (json["secretKinds"]?.array ?? []).compactMap { $0.string.flatMap(MacSecret.Kind.init) }
        sealingKey = json["sealingKey"]?.string
    }
}

/// Whether sudo on the Mac asks this phone (`/etc/helm/sudo-approvers` holds its key).
struct MacSudoSetup: Equatable {
    var installed = false
    var approvers: [String] = []
    var setupCommand = ""

    init() {}

    init(_ json: JSON?) {
        installed = json?["installed"]?.bool ?? false
        approvers = (json?["approvers"]?.array ?? []).compactMap(\.string)
        setupCommand = json?["setupCommand"]?.string ?? ""
    }

    /// This phone's key is installed and pam_helm is on.
    var approvesHere: Bool { installed && SudoKey.publicKey.map(approvers.contains) == true }
}

/// Follows one Mac's requests. Servers without the methods leave it empty and `available` false.
@MainActor
@Observable
final class MacAuthSync {
    private(set) var requests: [MacAuthRequest] = []
    private(set) var sudoSetup = MacSudoSetup()
    /// The Mac's screen watcher runs with Accessibility access.
    private(set) var promptsAvailable = false
    /// The server streams the "auth" topic and the snapshot is in.
    private(set) var available = false
    /// A password typed into a card that worked, until the person says whether to keep it.
    var saveOffer: PasswordSaveOffer?

    @ObservationIgnored private weak var environment: EnvironmentSession?

    init(environment: EnvironmentSession) {
        self.environment = environment
    }

    func apply(_ event: JSON) {
        switch event["type"]?.string {
        case "snapshot":
            requests = (event["requests"]?.array ?? []).compactMap(MacAuthRequest.init)
            sudoSetup = MacSudoSetup(event["sudo"])
            promptsAvailable = event["promptsAvailable"]?.bool ?? false
            available = true
        case "added":
            if let request = event["request"].flatMap(MacAuthRequest.init), !requests.contains(where: { $0.id == request.id }) {
                requests.append(request)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        case "removed":
            guard let id = event["id"]?.string else { return }
            requests.removeAll { $0.id == id }
        case "sudo":
            sudoSetup = MacSudoSetup(event["sudo"])
        default:
            break
        }
    }

    func connectionEnded() {
        available = false
        requests = []
    }

    // MARK: Answers

    enum AnswerError: LocalizedError {
        case noPassword(MacSecret.Kind)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noPassword(let kind): String(localized: "Save \(kind.title) in this computer's settings first.")
            case .cancelled: nil
            case .failed(let message): message
            }
        }
    }

    /// Face ID, then the Mac goes ahead: sudo gets the Secure Enclave signature, a prompt gets the
    /// password typed. With `typed`, that password goes instead of a saved one, and once it works the
    /// phone offers to keep it for Face ID. Returns what the Mac said.
    func approve(_ request: MacAuthRequest, with kind: MacSecret.Kind? = nil, typed: String? = nil) async throws -> String {
        guard let environment else { throw AnswerError.failed(String(localized: "Not connected.")) }
        var payload: [String: JSON] = ["id": .string(request.id), "action": "approve"]
        switch request.kind {
        case .sudo:
            guard let sudo = request.sudo else { throw AnswerError.failed("No sudo request.") }
            let reason = String(localized: "Run “\(request.title)” as root on \(environment.label)")
            guard let signature = try await SudoKey.sign(sudo.message, reason: reason) else { throw AnswerError.cancelled }
            payload["signature"] = .string(signature.base64EncodedString())
        case .prompt:
            guard let kind = kind ?? request.secretKinds.first(where: { MacSecret.has($0, environmentId: environment.id) })
                    ?? request.secretKinds.first
            else { throw AnswerError.failed(String(localized: "This prompt doesn't take a password.")) }
            guard let sealingKey = request.sealingKey else { throw AnswerError.failed("The Mac sent no key.") }
            let password: String
            if let typed, !typed.isEmpty {
                password = typed
            } else {
                guard MacSecret.has(kind, environmentId: environment.id) else { throw AnswerError.noPassword(kind) }
                let reason = request.app.isEmpty
                    ? String(localized: "Unlock on \(environment.label)")
                    : String(localized: "Unlock \(request.app) on \(environment.label)")
                guard let saved = try await MacSecret.read(kind, environmentId: environment.id, reason: reason) else {
                    throw AnswerError.cancelled
                }
                password = saved
            }
            let sealed = try MacSealing.seal(password, to: sealingKey, requestId: request.id)
            payload["secret"] = [
                "kind": .string(kind.rawValue), "ephemeralKey": .string(sealed.ephemeralKey), "box": .string(sealed.box),
            ]
            let result = try await environment.helmCommand("auth.respond", .object(payload), timeout: .seconds(35))
            let message = result["message"]?.string ?? ""
            guard result["ok"]?.bool == true else {
                // The saved one no longer works (changed on the Mac): the card asks for the new one.
                if typed == nil, message.contains("Wrong password") { MacSecret.markStale(kind, environmentId: environment.id) }
                throw AnswerError.failed(message)
            }
            if let typed, MacSecret.shouldOffer(kind, environmentId: environment.id) {
                saveOffer = PasswordSaveOffer(kind: kind, environmentId: environment.id, password: typed)
            }
            return message
        }
        let result = try await environment.helmCommand("auth.respond", .object(payload), timeout: .seconds(35))
        let message = result["message"]?.string ?? ""
        guard result["ok"]?.bool == true else { throw AnswerError.failed(message) }
        return message
    }

    /// Sudo: declined. A prompt: Cancel pressed on the Mac.
    func deny(_ request: MacAuthRequest) async throws {
        guard let environment else { return }
        _ = try await environment.helmCommand("auth.respond", ["id": .string(request.id), "action": "deny"], timeout: .seconds(15))
    }

    /// Hands this phone's sudo key to the Mac; `setupCommand` then installs it.
    func registerSudoKey() async throws {
        guard let environment else { return }
        guard let publicKey = try SudoKey.create() else { throw AnswerError.failed(String(localized: "This device has no Secure Enclave.")) }
        let result = try await environment.helmCommand("auth.registerApprover", [
            "publicKey": .string(publicKey), "deviceName": .string(UIDevice.current.name),
        ])
        sudoSetup = MacSudoSetup(result)
    }
}

// MARK: - Passwords

/// Passwords kept in this phone's Keychain behind Face ID, to type into the Mac's prompts.
/// They never leave the phone except sealed to the prompt that asked.
enum MacSecret {
    enum Kind: String, CaseIterable, Identifiable {
        /// The Mac's login password: "Use Password…" on Touch ID sheets and password prompts.
        case mac
        /// 1Password's account password, for its lock screen.
        case onepassword

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mac: String(localized: "Mac password")
            case .onepassword: String(localized: "1Password password")
            }
        }
    }

    private static let service = "com.sketchpiece.helm.mac-secret"

    /// The Mac password differs per computer; one 1Password account serves them all.
    private static func account(_ kind: Kind, environmentId: String) -> String {
        kind == .mac ? "mac:\(environmentId)" : kind.rawValue
    }

    static func has(_ kind: Kind, environmentId: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind, environmentId: environmentId),
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // Without UI the item can't be read, but "would need Face ID" means it's there.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func flagKey(_ flag: String, _ kind: Kind, _ environmentId: String) -> String {
        "macSecret.\(flag).\(account(kind, environmentId: environmentId))"
    }

    /// After a password typed by hand worked: ask to keep it, unless none is saved yet and the
    /// person said never, or the saved one still works.
    static func shouldOffer(_ kind: Kind, environmentId: String) -> Bool {
        if UserDefaults.standard.bool(forKey: flagKey("stale", kind, environmentId)) { return true }
        if has(kind, environmentId: environmentId) { return false }
        return !UserDefaults.standard.bool(forKey: flagKey("never", kind, environmentId))
    }

    /// The saved password was turned down by the Mac.
    static func markStale(_ kind: Kind, environmentId: String) {
        UserDefaults.standard.set(true, forKey: flagKey("stale", kind, environmentId))
    }

    static func isStale(_ kind: Kind, environmentId: String) -> Bool {
        UserDefaults.standard.bool(forKey: flagKey("stale", kind, environmentId))
    }

    /// "Don't ask again" for this password on this computer.
    static func neverOffer(_ kind: Kind, environmentId: String) {
        UserDefaults.standard.set(true, forKey: flagKey("never", kind, environmentId))
    }

    static func save(_ password: String, as kind: Kind, environmentId: String) throws {
        remove(kind, environmentId: environmentId)
        UserDefaults.standard.removeObject(forKey: flagKey("stale", kind, environmentId))
        UserDefaults.standard.removeObject(forKey: flagKey("never", kind, environmentId))
        var error: Unmanaged<CFError>?
        // A new face in Face ID, or none at all, makes the password unreadable.
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error)
        else { throw error!.takeRetainedValue() as Error }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind, environmentId: environmentId),
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(password.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func remove(_ kind: Kind, environmentId: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind, environmentId: environmentId),
        ] as CFDictionary)
    }

    /// Face ID, then the password. Nil when Face ID was cancelled.
    static func read(_ kind: Kind, environmentId: String, reason: String) async throws -> String? {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind, environmentId: environmentId),
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
            kSecUseOperationPrompt as String: reason,
        ]
        return try await Task.detached {
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecUserCanceled || status == errSecAuthFailed { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return String(data: data, encoding: .utf8)
        }.value
    }
}

/// A password that just worked, typed by hand, offered to keep behind Face ID.
struct PasswordSaveOffer: Identifiable, Equatable {
    let kind: MacSecret.Kind
    let environmentId: String
    let password: String

    var id: String { "\(kind.rawValue):\(environmentId)" }

    func keep() throws {
        try MacSecret.save(password, as: kind, environmentId: environmentId)
    }
}

/// Seals a password to the Mac helper's key: ECDH with a one-off key, HKDF-SHA256 (salt
/// "helm-auth-v1", info: the request id), AES-GCM. native/helm-auth/main.swift opens it.
enum MacSealing {
    static func seal(_ secret: String, to sealingKey: String, requestId: String) throws -> (ephemeralKey: String, box: String) {
        guard let keyData = Data(base64Encoded: sealingKey) else { throw MacAuthSync.AnswerError.failed("Bad key from the Mac.") }
        let macKey = try P256.KeyAgreement.PublicKey(x963Representation: keyData)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let key = try ephemeral.sharedSecretFromKeyAgreement(with: macKey).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data("helm-auth-v1".utf8), sharedInfo: Data(requestId.utf8), outputByteCount: 32)
        guard let box = try AES.GCM.seal(Data(secret.utf8), using: key).combined else {
            throw MacAuthSync.AnswerError.failed("Couldn't seal the password.")
        }
        return (ephemeral.publicKey.x963Representation.base64EncodedString(), box.base64EncodedString())
    }
}

// MARK: - sudo key

/// A P-256 key in the Secure Enclave that only signs after Face ID. Its public half goes into the
/// Mac's /etc/helm/sudo-approvers; pam_helm lets sudo through on its signature.
enum SudoKey {
    private static let tag = Data("com.sketchpiece.helm.sudo-key".utf8)

    private static func privateKey(context: LAContext? = nil) -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item else { return nil }
        return (item as! SecKey)
    }

    /// Base64 X9.63, as the Mac lists it; nil before `create()`.
    static var publicKey: String? {
        guard let key = privateKey(), let pub = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(pub, nil) as Data?
        else { return nil }
        return data.base64EncodedString()
    }

    /// The existing key, or a new one. Nil without a Secure Enclave (the simulator).
    static func create() throws -> String? {
        if let existing = publicKey { return existing }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error)
        else { throw error!.takeRetainedValue() as Error }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            let failure = error!.takeRetainedValue()
            if CFErrorGetCode(failure) == Int(errSecUnimplemented) { return nil }
            throw failure as Error
        }
        return publicKey
    }

    /// Face ID, then a DER ECDSA-SHA256 signature. Nil when Face ID was cancelled.
    static func sign(_ message: Data, reason: String) async throws -> Data? {
        let context = LAContext()
        context.localizedReason = reason
        // Ask for Face ID up front, so the reason shows; the key then signs without asking again.
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else { return nil }
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return nil
        }
        guard let key = privateKey(context: context) else {
            throw MacAuthSync.AnswerError.failed(String(localized: "This phone's sudo key is gone. Set it up again in the computer's settings."))
        }
        return try await Task.detached {
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return signature as Data
        }.value
    }
}
