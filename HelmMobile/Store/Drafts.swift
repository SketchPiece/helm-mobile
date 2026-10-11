import Foundation
import Observation

/// An uploaded attachment a draft holds, in the shape `helm.drafts` carries it.
struct DraftFile: Codable, Hashable {
    var attachmentId: String
    var type: String
    var name: String
    var mimeType: String
    var sizeBytes: Int

    init(_ attachment: ChatAttachment) {
        attachmentId = attachment.id
        type = attachment.type == "image" ? "image" : "file"
        name = attachment.name
        mimeType = attachment.mimeType
        sizeBytes = attachment.sizeBytes
    }

    init?(json: JSON) {
        guard let id = json["attachmentId"]?.string else { return nil }
        attachmentId = id
        type = json["type"]?.string == "image" ? "image" : "file"
        name = json["name"]?.string ?? id
        mimeType = json["mimeType"]?.string ?? "application/octet-stream"
        sizeBytes = json["sizeBytes"]?.int ?? 0
    }

    var json: JSON {
        ["attachmentId": .string(attachmentId), "type": .string(type), "name": .string(name),
         "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))]
    }

    var chatAttachment: ChatAttachment {
        ChatAttachment(id: attachmentId, type: type, name: name, mimeType: mimeType, sizeBytes: sizeBytes)
    }
}

/// Unsent composer content: of a thread, or of a new thread in a project.
struct StoredDraft: Codable, Equatable {
    var text = ""
    var files: [DraftFile] = []
    var environmentId: String?
    /// For a new thread's draft: the project it is written for.
    var projectId: String?
    /// Edited on this phone since the Mac last took it. A draft that isn't was in step with the
    /// Mac, so when the Mac no longer has it, it was sent or thrown away there.
    var dirty = false

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }
    func sameContent(as other: StoredDraft) -> Bool { text == other.text && files == other.files }
}

/// Unsent composer content, kept on this phone and shared with Helm on the Mac (`DraftSync`), so a
/// half-written message survives leaving the thread and carries on on the other screen.
///
/// Keys: a thread's draft is its id; a new thread's is `new:<environment>:<project>`, and
/// `new-thread` while New Thread has no project yet (that one stays on the phone).
@MainActor
@Observable
final class Drafts {
    static let shared = Drafts()

    static let unassignedNewThreadKey = "new-thread"
    static func newThreadKey(environmentId: String, projectId: String) -> String {
        "new:\(environmentId):\(projectId)"
    }
    static func isNewThreadKey(_ key: String) -> Bool { key == unassignedNewThreadKey || key.hasPrefix("new:") }

    /// The text lives here unobserved: a keystroke in one composer shouldn't redraw every row.
    @ObservationIgnored private var drafts: [String: StoredDraft] = [:]
    /// Keys holding something, for the pens on thread rows; changes only when a draft appears or goes.
    private(set) var keys: Set<String> = []
    /// Bumped for a key each time its draft changed on the Mac, for an open composer to take it.
    private(set) var remoteRevisions: [String: Int] = [:]
    /// Bumped when new-thread drafts change other than by typing in New Thread, for Home's list.
    private(set) var newThreadRevision = 0
    /// A key edited on this phone, for the sync to send it.
    @ObservationIgnored var onLocalChange: ((String) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let storageKey = "drafts.v2"
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Reading

    func draft(for key: String) -> StoredDraft? { drafts[key] }
    func text(for key: String) -> String { drafts[key]?.text ?? "" }
    func files(for key: String) -> [DraftFile] { drafts[key]?.files ?? [] }
    func hasDraft(_ key: String) -> Bool { keys.contains(key) }
    func remoteRevision(_ key: String) -> Int { remoteRevisions[key] ?? 0 }

    /// Every draft kept, for the sync.
    var all: [(key: String, draft: StoredDraft)] { drafts.map { ($0.key, $0.value) } }

    /// New threads with something written, newest project first in no particular order beyond the key.
    var newThreadDrafts: [NewThreadDraft] {
        _ = newThreadRevision
        return drafts.compactMap { key, draft in
            guard Self.isNewThreadKey(key), !draft.isEmpty else { return nil }
            return NewThreadDraft(key: key, text: draft.text, hasFiles: !draft.files.isEmpty,
                                  environmentId: draft.environmentId, projectId: draft.projectId)
        }
        .sorted { $0.key < $1.key }
    }

    // MARK: Editing here

    /// What a composer holds now. `environmentId` and `projectId` say where it belongs.
    func save(text: String, files: [DraftFile]? = nil, for key: String, environmentId: String?, projectId: String? = nil) {
        var draft = drafts[key] ?? StoredDraft()
        let before = draft
        draft.text = text
        if let files { draft.files = files }
        if let environmentId { draft.environmentId = environmentId }
        if let projectId { draft.projectId = projectId }
        guard draft != before else { return }
        draft.dirty = true
        store(draft, for: key)
        onLocalChange?(key)
    }

    /// Clears a draft that was sent or thrown away, on the Mac too.
    func clear(_ key: String) {
        guard drafts[key] != nil else { return }
        save(text: "", files: [], for: key, environmentId: nil)
        if Self.isNewThreadKey(key) { newThreadRevision += 1 }
    }

    /// New Thread switched projects: what was written goes along (uploads only within the same Mac),
    /// unless the project it went to already has a draft of its own, which then shows instead and
    /// the other one stays where it was. Returns whether the target's own draft is the one to show.
    func move(from old: String, to new: String, environmentId: String?, projectId: String?) -> Bool {
        guard old != new else { return false }
        if let target = drafts[new], !target.isEmpty { return true }
        guard let moving = drafts[old], !moving.isEmpty else { return true }
        let sameMac = moving.environmentId == nil || moving.environmentId == environmentId
        save(text: moving.text, files: sameMac ? moving.files : [], for: new, environmentId: environmentId,
             projectId: projectId)
        clear(old)
        return false
    }

    /// Lets Home's list catch up after New Thread closes.
    func refreshNewThreadList() { newThreadRevision += 1 }

    // MARK: From the Mac

    /// A draft as the Mac has it now.
    func applyRemote(_ remote: StoredDraft, for key: String) {
        var draft = remote
        draft.dirty = false
        if draft.environmentId == nil { draft.environmentId = drafts[key]?.environmentId }
        if draft.projectId == nil { draft.projectId = drafts[key]?.projectId }
        guard drafts[key] != draft else { return }
        store(draft, for: key)
        remoteRevisions[key, default: 0] += 1
        if Self.isNewThreadKey(key) { newThreadRevision += 1 }
    }

    /// The Mac took `sent`: in step again, unless it was edited meanwhile.
    func markSynced(_ key: String, sent: StoredDraft) {
        guard var draft = drafts[key], draft.dirty, draft.sameContent(as: sent) else { return }
        draft.dirty = false
        store(draft, for: key)
    }

    // MARK: Storage

    private func store(_ draft: StoredDraft, for key: String) {
        // An empty draft edited here stays until the Mac hears it was cleared; the unassigned
        // new thread never goes to the Mac.
        if draft.isEmpty && (!draft.dirty || key == Self.unassignedNewThreadKey) {
            drafts[key] = nil
        } else {
            drafts[key] = draft
        }
        let has = !draft.isEmpty
        if has, !keys.contains(key) { keys.insert(key) }
        if !has, keys.contains(key) { keys.remove(key) }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes right away, e.g. as the app goes to the background.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if let data = try? JSONEncoder().encode(drafts) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: StoredDraft].self, from: data) {
            drafts = saved
        } else {
            migrate()
        }
        keys = Set(drafts.compactMap { $0.value.isEmpty ? nil : $0.key })
    }

    /// Drafts kept before they were shared: text per thread under `draft.<id>`, and one new thread
    /// with its project alongside. They go to the Mac on the next connection.
    private func migrate() {
        let environmentKey = "draft.new-thread.environmentId"
        let projectKey = "draft.new-thread.projectId"
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("draft.") {
            guard key != environmentKey, key != projectKey, let text = value as? String else { continue }
            let id = String(key.dropFirst("draft.".count))
            defaults.removeObject(forKey: key)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if id == Self.unassignedNewThreadKey {
                let environmentId = defaults.string(forKey: environmentKey)
                let projectId = defaults.string(forKey: projectKey)
                let newKey = environmentId.flatMap { env in projectId.map { Self.newThreadKey(environmentId: env, projectId: $0) } }
                drafts[newKey ?? id] = StoredDraft(text: text, environmentId: environmentId, projectId: projectId, dirty: true)
            } else {
                drafts[id] = StoredDraft(text: text, dirty: true)
            }
        }
        defaults.removeObject(forKey: environmentKey)
        defaults.removeObject(forKey: projectKey)
        if !drafts.isEmpty { saveNow() }
    }
}

/// A new thread's draft as Home lists it.
struct NewThreadDraft: Equatable, Identifiable {
    var key: String
    var text: String
    var hasFiles: Bool
    var environmentId: String?
    var projectId: String?

    var id: String { key }
    /// For a list row: the first line as the title, the rest folded onto one line.
    var title: String { lines.first ?? "" }
    var remainder: String { lines.dropFirst().joined(separator: " ") }

    private var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
