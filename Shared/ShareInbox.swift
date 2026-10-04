import Foundation

/// The share extension's hand-off to the app through the App Group container. Each share is a
/// folder under `Shares/` with the copied files and a `manifest.json` written last, so a folder
/// without one is still being written (or its extension died). The app takes every finished share
/// on launch and foreground and opens New Thread with it.
enum ShareInbox {
    static let appGroup = "group.com.sketchpiece.helm"
    static let manifestName = "manifest.json"
    /// Opened by the extension after saving; the app picks the share up when it comes forward.
    static let openURL = URL(string: "helm://share")!

    /// What one share holds besides its files' bytes.
    struct Manifest: Codable, Equatable, Sendable {
        var createdAt: Date
        /// Shared text and links, in the order they came.
        var texts: [String] = []
        var files: [File] = []

        struct File: Codable, Equatable, Sendable {
            /// File name inside the share's folder, also the attachment's name.
            var name: String
            /// The sender offered it as a picture.
            var isImage: Bool
        }

        var isEmpty: Bool { texts.isEmpty && files.isEmpty }
    }

    /// `Shares/` in the App Group container, or nil when the build lacks the entitlement.
    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "Shares", directoryHint: .isDirectory)
    }

    // MARK: Extension side

    /// A fresh folder for one share.
    static func makeFolder(in root: URL) throws -> URL {
        let folder = root.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes the manifest, which marks the share as complete. Called after every file is copied.
    static func finish(_ manifest: Manifest, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appending(path: manifestName), options: .atomic)
    }

    /// `name`, or `name 2.ext`, `name 3.ext`… when a file by that name is already in the share.
    static func uniqueName(_ name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    // MARK: App side

    /// Moves every finished share's files into `destination` (one subfolder per share), deletes the
    /// shares and returns their content merged, oldest first. Unfinished folders older than a day
    /// are deleted; younger ones are left for the extension to finish.
    static func take(from root: URL, to destination: URL, now: Date = Date()) -> SharedContent {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var shares: [(manifest: Manifest, folder: URL)] = []
        for folder in folders {
            let manifestURL = folder.appending(path: manifestName)
            guard let data = try? Data(contentsOf: manifestURL) else {
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if now.timeIntervalSince(created) > 24 * 3600 { try? manager.removeItem(at: folder) }
                continue
            }
            guard let manifest = try? decoder.decode(Manifest.self, from: data) else {
                try? manager.removeItem(at: folder)
                continue
            }
            shares.append((manifest, folder))
        }
        var content = SharedContent()
        for share in shares.sorted(by: { $0.manifest.createdAt < $1.manifest.createdAt }) {
            let target = destination.appending(path: share.folder.lastPathComponent, directoryHint: .isDirectory)
            try? manager.createDirectory(at: target, withIntermediateDirectories: true)
            var files: [SharedFile] = []
            for file in share.manifest.files {
                // Names come from the manifest; keep them inside the share's folder.
                guard !file.name.contains("/"), file.name != "..", file.name != "." else { continue }
                let source = share.folder.appending(path: file.name)
                let moved = target.appending(path: file.name)
                if (try? manager.moveItem(at: source, to: moved)) != nil {
                    files.append(SharedFile(url: moved, isImage: file.isImage))
                }
            }
            content.append(texts: share.manifest.texts, files: files)
            try? manager.removeItem(at: share.folder)
        }
        return content
    }
}

/// A file shared into Helm, already in the app's own storage.
struct SharedFile: Equatable, Sendable {
    var url: URL
    var isImage: Bool
}

/// What New Thread starts with: shared text for the composer and files to attach. Empty for the
/// "New task" quick action.
struct SharedContent: Equatable, Sendable {
    var text = ""
    var files: [SharedFile] = []

    var isEmpty: Bool { text.isEmpty && files.isEmpty }

    /// Adds one share: text and links trimmed, deduplicated and separated by a blank line.
    mutating func append(texts: [String], files: [SharedFile]) {
        var seen = Set(text.components(separatedBy: "\n\n"))
        for value in texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty {
            guard seen.insert(value).inserted else { continue }
            text = text.isEmpty ? value : text + "\n\n" + value
        }
        self.files += files
    }

    mutating func append(_ other: SharedContent) {
        append(texts: other.text.isEmpty ? [] : [other.text], files: other.files)
    }
}
