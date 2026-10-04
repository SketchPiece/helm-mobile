import Foundation

/// What this phone last saw from each Mac, on disk: the thread list and the threads that were
/// opened, so a cold start or a dead connection still shows them.
///
/// A saved copy is only for looking at: it is shown until the server's snapshot replaces it and
/// never used to resume a stream, so it can be old but not wrong for long. Every file carries
/// when it was last in step with the server. Writes run on one serial queue, so the newest write
/// is the one that stays; each replaces its file atomically.
final class LocalCache: @unchecked Sendable {
    static let shared = LocalCache()

    /// Bump when the saved shape changes; other versions are ignored and deleted.
    static let format = 1
    /// Threads kept per Mac (most recently saved win).
    static let maxThreads = 60
    /// Timeline rows kept per thread.
    static let maxRows = 400

    private let root: URL
    private let queue = DispatchQueue(label: "helm.local-cache", qos: .utility)

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "LocalCache"))
    {
        self.root = root
        queue.async { self.prepareRoot() }
    }

    // MARK: Shell

    func shell(environmentId: String) async -> (shell: ShellState, savedAt: Date)? {
        await read(shellFile(environmentId), environmentId: environmentId) { ShellState.restored(from: $0) }
    }

    func saveShell(_ shell: ShellState, environmentId: String, savedAt: Date) {
        queue.async {
            self.write(shell.snapshotItem, to: self.shellFile(environmentId), environmentId: environmentId, savedAt: savedAt)
        }
    }

    // MARK: Threads

    func thread(_ threadId: String, environmentId: String) async -> (projection: ThreadProjection, savedAt: Date)? {
        await read(threadFile(threadId, environmentId), environmentId: environmentId) { item in
            ThreadProjection(snapshot: item).flatMap { $0.thread.id == threadId ? $0 : nil }
        }
    }

    func saveThread(_ projection: ThreadProjection, environmentId: String, savedAt: Date) {
        queue.async {
            let file = self.threadFile(projection.thread.id, environmentId)
            self.write(projection.snapshotItem(maxRows: Self.maxRows), to: file, environmentId: environmentId, savedAt: savedAt)
            self.trimThreads(environmentId)
        }
    }

    func removeThread(_ threadId: String, environmentId: String) {
        queue.async { try? FileManager.default.removeItem(at: self.threadFile(threadId, environmentId)) }
    }

    /// Drops saved threads the server no longer lists (deleted or archived).
    func keepThreads(_ ids: Set<String>, environmentId: String) {
        queue.async {
            let keep = Set(ids.map(Self.fileName))
            for file in self.threadFiles(environmentId) where !keep.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Forgets a Mac entirely (unpaired).
    func removeEnvironment(_ environmentId: String) {
        queue.async { try? FileManager.default.removeItem(at: self.directory(environmentId)) }
    }

    /// Runs `done` once every write queued so far has landed.
    func flush(_ done: @escaping @Sendable () -> Void) {
        queue.async(execute: done)
    }

    // MARK: Files

    private var versionRoot: URL { root.appending(path: "v\(Self.format)") }

    private func directory(_ environmentId: String) -> URL {
        versionRoot.appending(path: Self.fileName(environmentId))
    }

    private func shellFile(_ environmentId: String) -> URL {
        directory(environmentId).appending(path: "shell.json")
    }

    private func threadFile(_ threadId: String, _ environmentId: String) -> URL {
        directory(environmentId).appending(path: "threads").appending(path: "\(Self.fileName(threadId)).json")
    }

    private func threadFiles(_ environmentId: String) -> [URL] {
        let folder = directory(environmentId).appending(path: "threads")
        let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )
        return (files ?? []).filter { $0.pathExtension == "json" }
    }

    /// Ids are UUID-like; anything else is base64url'd so it can't climb out of the folder.
    static func fileName(_ id: String) -> String {
        let plain = !id.isEmpty && !id.hasPrefix(".") && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
        if plain { return id }
        return "~" + Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    private func prepareRoot() {
        let manager = FileManager.default
        try? manager.createDirectory(at: versionRoot, withIntermediateDirectories: true)
        // A cache: not worth an iCloud backup, and it comes back by itself.
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        for old in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent != versionRoot.lastPathComponent {
            try? manager.removeItem(at: old)
        }
    }

    private func write(_ item: JSON, to file: URL, environmentId: String, savedAt: Date) {
        let envelope: JSON = [
            "format": .number(Double(Self.format)),
            "environmentId": .string(environmentId),
            "savedAt": .string(ISODate.string(savedAt)),
            "item": item,
        ]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try envelope.data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func read<T: Sendable>(_ file: URL, environmentId: String, _ make: @escaping @Sendable (JSON) -> T?) async -> (T, Date)? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readNow(file, environmentId: environmentId, make))
            }
        }
    }

    private func readNow<T>(_ file: URL, environmentId: String, _ make: (JSON) -> T?) -> (T, Date)? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let envelope = try? JSON.parse(data),
              envelope["format"]?.int == Self.format,
              envelope["environmentId"]?.string == environmentId,
              let savedAt = ISODate.parse(envelope["savedAt"]?.string),
              let item = envelope["item"], let value = make(item)
        else {
            // Unreadable or from another version: it would only ever be wrong, so drop it.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return (value, savedAt)
    }

    private func trimThreads(_ environmentId: String) {
        let files = threadFiles(environmentId)
        guard files.count > Self.maxThreads else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxThreads) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
