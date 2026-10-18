import Foundation

/// Keeps `Drafts` in step with one Mac (`helm.command` "drafts.set" / `helm.subscribe` "drafts"): what is
/// written here goes up shortly after typing pauses, what is written in Helm on the Mac comes
/// down. The last write wins. Servers without the methods just leave drafts on the phone.
@MainActor
final class DraftSync {
    /// This install, so its own writes coming back are told from the Mac's.
    static let clientId: String = {
        let key = "drafts.clientId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "phone-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private weak var environment: EnvironmentSession?
    private let drafts: Drafts
    /// The server knows these methods and the snapshot is in.
    private var ready = false
    private var pending: [String: Task<Void, Never>] = [:]

    init(environment: EnvironmentSession, drafts: Drafts = .shared) {
        self.environment = environment
        self.drafts = drafts
    }

    // MARK: Keys

    private var environmentId: String { environment?.id ?? "" }

    /// The Mac's key for a draft kept here; nil for one that stays on the phone.
    private func serverKey(_ key: String, _ draft: StoredDraft?) -> String? {
        if key == Drafts.unassignedNewThreadKey { return nil }
        if key.hasPrefix("new:") { return draft?.projectId.map { "project:\($0)" } }
        return key
    }

    private func localKey(_ serverKey: String) -> (key: String, projectId: String?) {
        if serverKey.hasPrefix("project:") {
            let projectId = String(serverKey.dropFirst("project:".count))
            return (Drafts.newThreadKey(environmentId: environmentId, projectId: projectId), projectId)
        }
        return (serverKey, nil)
    }

    /// Whether a draft kept here belongs to this Mac. One from before drafts were shared names no
    /// Mac; it belongs to the one with that thread.
    private func belongs(_ key: String, _ draft: StoredDraft) -> Bool {
        if let id = draft.environmentId { return id == environmentId }
        return environment?.thread(key) != nil
    }

    // MARK: From the Mac

    func connectionEnded() {
        ready = false
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    /// One event of the "drafts" topic of `helm.subscribe`.
    func apply(_ event: JSON) {
        switch event["type"]?.string {
        case "snapshot":
            applySnapshot(event["drafts"]?.array ?? [])
        case "changed":
            guard ready, let remote = event["draft"], let key = remote["key"]?.string,
                  remote["clientId"]?.string != Self.clientId else { return }
            let local = localKey(key)
            // Edited here and about to go up: that write is the later one.
            if drafts.draft(for: local.key)?.dirty == true { return }
            drafts.applyRemote(stored(remote, projectId: local.projectId), for: local.key)
        default:
            break
        }
    }

    private func applySnapshot(_ items: [JSON]) {
        ready = true
        var onServer: Set<String> = []
        for remote in items {
            guard let key = remote["key"]?.string else { continue }
            let local = localKey(key)
            onServer.insert(local.key)
            if drafts.draft(for: local.key)?.dirty == true { continue }
            drafts.applyRemote(stored(remote, projectId: local.projectId), for: local.key)
        }
        for (key, draft) in drafts.all where serverKey(key, draft) != nil && belongs(key, draft) {
            if draft.dirty {
                // Written while away from the Mac (or before drafts were shared).
                schedule(key, delay: .zero)
            } else if !onServer.contains(key) {
                // It was in step and the Mac dropped it: sent or thrown away there.
                drafts.applyRemote(StoredDraft(environmentId: draft.environmentId, projectId: draft.projectId), for: key)
            }
        }
    }

    private func stored(_ remote: JSON, projectId: String?) -> StoredDraft {
        StoredDraft(text: remote["text"]?.string ?? "",
                    files: (remote["attachments"]?.array ?? []).compactMap(DraftFile.init(json:)),
                    environmentId: environmentId, projectId: projectId)
    }

    // MARK: To the Mac

    /// Sends the draft once typing pauses (or right away with `delay` zero).
    func schedule(_ key: String, delay: Duration = .milliseconds(400)) {
        pending[key]?.cancel()
        pending[key] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.pending[key] = nil
            await self.push(key)
        }
    }

    private func push(_ key: String) async {
        guard ready, let environment, environment.isLive, let draft = drafts.draft(for: key), draft.dirty,
              let serverKey = serverKey(key, draft) else { return }
        let payload: JSON = [
            "key": .string(serverKey), "text": .string(draft.text),
            "attachments": .array(draft.files.map(\.json)), "clientId": .string(Self.clientId),
        ]
        do {
            _ = try await environment.helmCommand("drafts.set", payload)
            drafts.markSynced(key, sent: draft)
        } catch {
            // Stays edited here; it goes up with the next snapshot after reconnecting.
        }
    }
}
