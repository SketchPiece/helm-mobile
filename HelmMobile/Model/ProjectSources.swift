import Foundation

// Wire shapes and pure helpers for adding projects (folder, new, clone) and picking a base
// branch. Mirrors client-runtime's `operations/projects.ts`; the request builders are shared
// with the live tests so both send the same payloads.

/// Absolute folder paths on the Mac, as the phone shows and walks them.
enum FolderPath {
    struct Crumb: Hashable {
        var name: String
        var path: String
    }

    /// `/Users/me` or `/home/me` for a path inside a home directory.
    static func home(of path: String) -> String? {
        path.range(of: #"^/(Users|home)/[^/]+"#, options: .regularExpression).map { String(path[$0]) }
    }

    /// `~/Projects/app` for paths under a home directory.
    static func short(_ path: String) -> String {
        guard let home = home(of: path) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The listing query for a directory: `filesystem.browse` lists a path that ends in `/`.
    static func directoryQuery(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// The folder's own name, which is also the project title (`inferProjectTitleFromPath`).
    static func lastSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func join(_ directory: String, _ name: String) -> String {
        directoryQuery(directory) + name
    }

    /// Tappable path segments, with the home directory collapsed to `~`:
    /// `/Users/me/Projects/app` → `~`, `Projects`, `app`.
    static func breadcrumbs(_ path: String) -> [Crumb] {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        var crumbs: [Crumb]
        var current: String
        var rest: Substring
        if let home = home(of: trimmed) {
            crumbs = [Crumb(name: "~", path: home)]
            current = home
            rest = trimmed.dropFirst(home.count)
        } else {
            crumbs = [Crumb(name: "/", path: "/")]
            current = ""
            rest = Substring(trimmed)
        }
        for segment in rest.split(separator: "/") {
            current += "/" + segment
            crumbs.append(Crumb(name: String(segment), path: current))
        }
        return crumbs
    }
}

/// One `filesystem.browse` answer: the listed directory and its subfolders.
struct FolderListing: Sendable {
    struct Entry: Hashable, Sendable, Identifiable {
        var name: String
        var fullPath: String
        var id: String { fullPath }
    }

    var path: String
    var entries: [Entry]

    static func request(directory: String) -> JSON {
        ["partialPath": .string(String(FolderPath.directoryQuery(directory).prefix(512)))]
    }

    init(json: JSON) {
        path = json["parentPath"]?.string ?? ""
        entries = (json["entries"]?.array ?? []).compactMap {
            guard let name = $0["name"]?.string, let fullPath = $0["fullPath"]?.string else { return nil }
            return Entry(name: name, fullPath: fullPath)
        }
    }
}

/// Project mutations for `projects.mutate`.
enum ProjectCommands {
    /// `project.update` fields for an icon: an override clears the image and the other way round.
    static func iconFields(_ choice: Project.IconChoice) -> [String: JSON] {
        switch choice {
        case .automatic: ["faviconPath": nil, "projectIcon": nil]
        case .image(let path): ["faviconPath": .string(path), "projectIcon": nil]
        case .emoji(let emoji): ["faviconPath": nil, "projectIcon": ["kind": "emoji", "emoji": .string(emoji)]]
        case let .letters(text, color):
            ["faviconPath": nil, "projectIcon": ["kind": "monogram", "text": .string(text), "color": .string(color)]]
        }
    }

    /// Adds an existing (or missing, then created) folder as a project.
    static func create(projectId: String, path: String) -> JSON {
        [
            "type": "project.create",
            "commandId": .string(UUID().uuidString.lowercased()),
            "projectId": .string(projectId),
            "title": .string(FolderPath.lastSegment(path)),
            "workspaceRoot": .string(path),
            "createWorkspaceRootIfMissing": true,
            "defaultModelSelection": nil,
        ]
    }

    /// Changes only the given fields; `nil` values clear them (`projectIcon: nil` is the automatic icon).
    static func update(projectId: String, _ fields: [String: JSON]) -> JSON {
        var command: [String: JSON] = [
            "type": "project.update", "commandId": .string(UUID().uuidString.lowercased()), "projectId": .string(projectId),
        ]
        command.merge(fields) { _, new in new }
        return .object(command)
    }

    /// `force` deletes the project's threads too; without it a project with threads is refused.
    static func delete(projectId: String, force: Bool = false) -> JSON {
        ["type": "project.delete", "commandId": .string(UUID().uuidString.lowercased()), "projectId": .string(projectId),
         "force": .bool(force)]
    }
}

/// What the user typed in "Clone a repository": a git URL, or GitHub's `owner/name` shorthand.
struct CloneSource: Equatable {
    var remoteUrl: String
    /// `owner/name` when typed as GitHub shorthand, so it can be looked up first.
    var shorthand: String?
    /// The folder git would create (`getCloneDirectoryName`).
    var directoryName: String

    init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil {
            let name = trimmed.hasSuffix(".git") ? String(trimmed.dropLast(4)) : trimmed
            shorthand = name
            remoteUrl = "https://github.com/\(name).git"
        } else {
            shorthand = nil
            remoteUrl = trimmed
        }
        let name = Self.directoryName(remoteUrl)
        guard !name.isEmpty else { return nil }
        directoryName = name
    }

    /// The last path segment without `.git`, from `https://host/o/r.git`, `git@host:o/r` or `o/r`.
    /// Empty when the URL stops at the host or its port.
    static func directoryName(_ value: String) -> String {
        let withoutQuery = value.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        let trimmed = withoutQuery.trimmingCharacters(in: .whitespaces)
        let scheme = trimmed.range(of: "://")
        let hasHost = scheme != nil || trimmed.range(of: #"^[^/\\:]+@[^/\\:]+:"#, options: .regularExpression) != nil
        let pathPart = scheme.map { String(trimmed[$0.upperBound...]) } ?? trimmed
        let segments = pathPart.split(whereSeparator: { "/\\:".contains($0) }).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if hasHost && segments.count < 2 { return "" }
        let last = segments.last ?? ""
        if hasHost && segments.count == 2 && last.allSatisfy(\.isNumber) { return "" }
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }
}

/// A repository resolved by `sourceControl.lookupRepository`.
struct RepositoryInfo: Equatable, Sendable {
    var provider: String
    var nameWithOwner: String
    var url: String
    var sshUrl: String

    init?(json: JSON) {
        guard let nameWithOwner = json["nameWithOwner"]?.string, let url = json["url"]?.string else { return nil }
        provider = json["provider"]?.string ?? "github"
        self.nameWithOwner = nameWithOwner
        self.url = url
        sshUrl = json["sshUrl"]?.string ?? url
    }

    /// GitHub and Forgejo clone over HTTPS; the others keep SSH (`getDefaultCloneUrl`).
    var cloneUrl: String { provider == "github" || provider == "forgejo" ? url : sshUrl }
}

/// GitHub as `server.discoverSourceControl` reports it, when it can create repositories.
struct GitHubTarget: Equatable, Sendable {
    var account: String?

    /// Nil unless GitHub is installed and signed in.
    init?(discovery: JSON) {
        guard let github = discovery["sourceControlProviders"]?.array?.first(where: { $0["kind"]?.string == "github" }),
              github["status"]?.string == "available",
              github["auth"]?["status"]?.string != "unauthenticated"
        else { return nil }
        let account = github["auth"]?["account"]
        // Effect encodes `Option` as `{"_tag":"Some","value":…}`; accept a bare string too.
        self.account = account?["value"]?.string ?? account?.string
    }

    /// `account/folder`, or just the folder and `gh` picks the signed-in user.
    func repository(for workspaceRoot: String) -> String {
        let folder = FolderPath.lastSegment(workspaceRoot)
        return account.map { "\($0)/\(folder)" } ?? folder
    }
}

/// One clone from `subscribeProjectClones`.
struct CloneProgress: Equatable, Sendable {
    var phase: String
    var stage: String
    var percent: Int?
    var detail: String?
    var error: String?

    /// Each stream item is the full list of tracked clones; nil when `projectId` isn't in it
    /// (a finished clone drops out after a grace period).
    init?(projectId: String, in list: JSON) {
        guard let item = list.array?.first(where: { $0["projectId"]?.string == projectId }) else { return nil }
        phase = item["phase"]?.string ?? "running"
        stage = item["stage"]?.string ?? "connecting"
        percent = item["percent"]?.nonNull?.int
        detail = item["detail"]?.nonNull?.string
        error = item["error"]?.nonNull?.string
    }

    /// `Receiving objects · 45% · 12.3 MiB | 5.0 MiB/s`.
    var summary: String {
        var parts = [stageLabel]
        if let percent { parts.append("\(percent)%") }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private var stageLabel: String {
        switch stage {
        case "counting": String(localized: "Counting objects")
        case "receiving": String(localized: "Receiving objects")
        case "resolving": String(localized: "Resolving deltas")
        case "checkout": String(localized: "Checking out files")
        default: String(localized: "Connecting")
        }
    }
}

/// A branch from `vcs.listRefs`.
struct GitRef: Hashable, Sendable, Identifiable {
    var name: String
    var isRemote: Bool
    var current: Bool
    var isDefault: Bool
    var worktreePath: String?
    var id: String { name }

    init?(json: JSON) {
        guard let name = json["name"]?.string else { return nil }
        self.name = name
        isRemote = json["isRemote"]?.bool ?? false
        current = json["current"]?.bool ?? false
        isDefault = json["isDefault"]?.bool ?? false
        worktreePath = json["worktreePath"]?.nonNull?.string
    }
}

/// One page of `vcs.listRefs`.
struct RefPage: Sendable {
    var refs: [GitRef]
    var nextCursor: Int?
    var isRepo: Bool
    var hasPrimaryRemote: Bool

    static let pageSize = 100

    /// Local branches only. `query` is trimmed and dropped when empty; `cursor` is the previous
    /// page's `nextCursor`.
    static func request(cwd: String, query: String = "", cursor: Int? = nil) -> JSON {
        var payload: [String: JSON] = ["cwd": .string(cwd), "refKind": "local", "limit": .number(Double(pageSize))]
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        if !trimmed.isEmpty { payload["query"] = .string(trimmed) }
        if let cursor { payload["cursor"] = .number(Double(cursor)) }
        return .object(payload)
    }

    init(json: JSON) {
        refs = (json["refs"]?.array ?? []).compactMap(GitRef.init(json:))
        nextCursor = json["nextCursor"]?.nonNull?.int
        isRepo = json["isRepo"]?.bool ?? !refs.isEmpty
        hasPrimaryRemote = json["hasPrimaryRemote"]?.bool ?? false
    }

    /// The branch a new worktree starts from by default: current, then default, then the first.
    var defaultBase: String? {
        let local = refs.filter { !$0.isRemote }
        return (local.first(where: \.current) ?? local.first(where: \.isDefault) ?? local.first)?.name
    }

    /// Appends a later page, keyed by name: a ref seen again keeps its place and takes the new value.
    static func merge(_ existing: [GitRef], _ page: [GitRef]) -> [GitRef] {
        var merged = existing
        var index = Dictionary(merged.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        for ref in page {
            if let position = index[ref.name] {
                merged[position] = ref
            } else {
                index[ref.name] = merged.count
                merged.append(ref)
            }
        }
        return merged
    }
}
