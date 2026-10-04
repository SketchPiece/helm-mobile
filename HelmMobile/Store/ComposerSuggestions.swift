import Foundation
import Observation

/// The menu above a composer while a `/command`, `@path`, `$skill` or `#pr` is being typed.
/// Commands and skills come from the server config; paths and pull requests are searched on the
/// Mac, debounced.
@MainActor
@Observable
final class ComposerSuggestions {
    struct Item: Identifiable, Hashable {
        enum Action: Hashable {
            /// Replace the typed token with this text.
            case insert(String)
            /// `/plan`, `/default`: clear the token and switch the interaction mode.
            case interactionMode(String)
            /// `/model`: clear the token and open the model settings.
            case modelSettings
            /// Replace the token with `#42 ` and keep the pull request for the send.
            case pullRequest(PullRequestReference)
        }

        var id: String
        var title: String
        var detail: String
        var symbol: String
        var action: Action
    }

    /// Where the composer is: provider, workspace and what it may do.
    struct Scope {
        var environment: EnvironmentSession
        var providerInstanceId: String?
        var cwd: String?
        var projectId: String?
        var repositoryName: String?
        var hasThread: Bool
        var hasConversation: Bool
        var canChangeInteractionMode: Bool

        var flags: Flags {
            Flags(cwd: cwd, hasThread: hasThread, hasConversation: hasConversation,
                  canChangeInteractionMode: canChangeInteractionMode)
        }
    }

    /// The parts of a scope the `/` menu depends on.
    struct Flags {
        var cwd: String?
        var hasThread: Bool
        var hasConversation: Bool
        var canChangeInteractionMode: Bool
    }

    private(set) var trigger: ComposerTrigger?
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    private(set) var message: String?

    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var searchKey: String?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastScope: Scope?
    @ObservationIgnored private var pullRequestCache: (key: String, at: Date, entries: [JSON])?

    var isVisible: Bool { trigger != nil && (!items.isEmpty || isLoading || message != nil) }

    func clear() {
        search?.cancel()
        searchKey = nil
        trigger = nil
        items = []
        isLoading = false
        message = nil
    }

    func update(text: String, scope: Scope?) {
        lastText = text
        lastScope = scope
        guard let scope, let trigger = ComposerTrigger.detect(in: text) else {
            clear()
            return
        }
        self.trigger = trigger
        let config = scope.environment.config
        let provider = scope.providerInstanceId.flatMap { config?.provider($0) }
        switch trigger.kind {
        case .slashCommand, .slashModel, .skill:
            stopSearch()
            message = nil
            if trigger.kind == .slashModel {
                items = trigger.query.isEmpty ? Self.slashItems(query: "model", atMessageStart: false, provider: nil, scope: scope.flags) : []
            } else if trigger.kind == .slashCommand {
                items = Self.slashItems(query: trigger.query, atMessageStart: trigger.rangeStart == 0, provider: provider, scope: scope.flags)
            } else {
                items = Self.skillItems(query: trigger.query, skills: provider?.skills(cwd: scope.cwd) ?? [])
            }
            refreshWorkspace(provider: provider, scope: scope)
        case .path:
            let query = String(trigger.query.trimmingCharacters(in: .whitespaces).prefix(256))
            guard !query.isEmpty, let cwd = scope.cwd else {
                stopSearch()
                items = []
                message = nil
                return
            }
            runSearch(key: "path|\(cwd)|\(query)", delay: .milliseconds(150)) {
                try await Self.searchPaths(query: query, cwd: cwd, environment: scope.environment)
            }
        case .pullRequest:
            guard config?.capability("pullRequests") == true, let projectId = scope.projectId,
                  let repository = scope.repositoryName
            else {
                stopSearch()
                items = []
                message = String(localized: "Pull requests are unavailable for this project.")
                return
            }
            let query = trigger.query
            runSearch(key: "pr|\(projectId)|\(query)", delay: .milliseconds(180)) { [weak self] in
                try await self?.searchPullRequests(query: query, projectId: projectId, repository: repository,
                                                   environment: scope.environment) ?? []
            }
        }
    }

    // MARK: Searching

    private func stopSearch() {
        search?.cancel()
        searchKey = nil
        isLoading = false
    }

    private func runSearch(key: String, delay: Duration, _ work: @escaping @MainActor () async throws -> [Item]) {
        guard key != searchKey else { return }
        search?.cancel()
        searchKey = key
        isLoading = true
        message = nil
        search = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            do {
                let found = try await work()
                guard !Task.isCancelled, let self else { return }
                items = found
                isLoading = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                items = []
                isLoading = false
                message = error.localizedDescription
            }
        }
    }

    /// Without a snapshot for this cwd the menu shows the provider's global list; ask for the
    /// workspace's own once and redraw when it lands.
    private func refreshWorkspace(provider: Provider?, scope: Scope) {
        guard let provider, let cwd = scope.cwd, !provider.hasSnapshot(cwd: cwd) else { return }
        Task { [weak self] in
            await scope.environment.refreshProviderWorkspace(instanceId: provider.instanceId, cwd: cwd)
            guard let self, scope.environment.config?.provider(provider.instanceId)?.hasSnapshot(cwd: cwd) == true,
                  trigger?.kind == .slashCommand || trigger?.kind == .skill else { return }
            update(text: lastText, scope: lastScope)
        }
    }

    private static func searchPaths(query: String, cwd: String, environment: EnvironmentSession) async throws -> [Item] {
        let result = try await environment.call("projects.searchEntries", [
            "cwd": .string(cwd), "query": .string(query), "limit": 20,
        ])
        return (result["entries"]?.array ?? []).compactMap { entry in
            guard let path = entry["path"]?.string else { return nil }
            let parts = path.split(separator: "/")
            let isDirectory = entry["kind"]?.string == "directory"
            return Item(id: "path:\(path)", title: parts.last.map(String.init) ?? path,
                        detail: parts.dropLast().joined(separator: "/"), symbol: isDirectory ? "folder" : "doc",
                        action: .insert(ComposerTrigger.fileLink(path) + " "))
        }
    }

    /// `pullRequests.list` (newest 200 for a number, the host's own text search otherwise), plus
    /// `pullRequests.detail` when a typed number isn't in the list.
    private func searchPullRequests(query: String, projectId: String, repository: String,
                                    environment: EnvironmentSession) async throws -> [Item] {
        let numeric = query.allSatisfy(\.isASCIIDigit)
        var entries: [JSON]
        let cacheKey = "\(environment.id)|\(projectId)"
        if numeric, let cache = pullRequestCache, cache.key == cacheKey, Date().timeIntervalSince(cache.at) < 15 {
            entries = cache.entries
        } else {
            var payload: [String: JSON] = ["projectId": .string(projectId), "state": "all", "limit": 200]
            if !numeric { payload["query"] = .string(String(query.prefix(200))) }
            let result = try await environment.call("pullRequests.list", .object(payload))
            entries = result["entries"]?.array ?? []
            if numeric { pullRequestCache = (cacheKey, Date(), entries) }
            if entries.isEmpty, let error = result["errors"]?[0]?["message"]?.string { throw RPCError.defect(error) }
        }
        if numeric, let number = Int(query), number > 0,
           !entries.contains(where: { $0["number"]?.int == number && $0["repository"]?.string?.lowercased() == repository.lowercased() }),
           let detail = try? await environment.call("pullRequests.detail", [
               "projectId": .string(projectId), "repository": .string(repository), "number": .number(Double(number)),
           ]) {
            entries.insert(detail, at: 0)
        }
        return Self.pullRequestMatches(entries, query: query, projectId: projectId, repository: repository).map { reference in
            Item(id: "pr:\(reference.number)", title: reference.token,
                 detail: "\(reference.isDraft ? String(localized: "Draft") : Self.stateLabel(reference.state)) · \(reference.title)",
                 symbol: "arrow.triangle.pull", action: .pullRequest(reference))
        }
    }

    private static func stateLabel(_ state: String) -> String {
        switch state {
        case "merged": String(localized: "Merged")
        case "closed": String(localized: "Closed")
        default: String(localized: "Open")
        }
    }

    // MARK: Pure rules (tested)

    /// `/` items: `/model` always, `/plan` and `/default` when the mode can change, then the
    /// provider's commands (only at the very start of the message) and its skills.
    nonisolated static func slashItems(query rawQuery: String, atMessageStart: Bool, provider: Provider?, scope: Flags) -> [Item] {
        let query = rawQuery.lowercased()
        let canSwitchMode = scope.canChangeInteractionMode && (provider?.showInteractionModeToggle ?? false)
        var items: [Item] = []
        if "model".contains(query) || query.isEmpty {
            items.append(Item(id: "cmd:model", title: "/model", detail: String(localized: "Switch model"),
                              symbol: "cpu", action: .modelSettings))
        }
        if canSwitchMode {
            if "plan".contains(query) || query.isEmpty {
                items.append(Item(id: "cmd:plan", title: "/plan", detail: String(localized: "Switch to plan mode"),
                                  symbol: "list.bullet.clipboard", action: .interactionMode("plan")))
            }
            if "default".contains(query) || query.isEmpty {
                items.append(Item(id: "cmd:default", title: "/default", detail: String(localized: "Switch to default mode"),
                                  symbol: "text.bubble", action: .interactionMode("default")))
            }
        }
        guard let provider else { return items }
        let skills = offerable(provider.skills(cwd: scope.cwd))
        if atMessageStart {
            let skillNames = Set(skills.map { $0.name.lowercased() })
            for command in provider.slashCommands(cwd: scope.cwd) {
                let name = command.name
                guard query.isEmpty || name.lowercased().contains(query), !skillNames.contains(name.lowercased()) else { continue }
                if name == "compact" && !scope.hasConversation { continue }
                if name == "usage-limits" { continue }  // T3's own limits panel; this client has none
                if name == "feedback" && provider.driver == "codex" && !scope.hasThread { continue }
                items.append(Item(id: "pcmd:\(name)", title: "/\(name)", detail: command.description ?? "",
                                  symbol: "command", action: .insert("/\(name) ")))
            }
        }
        let skillQuery = query == "skill" ? "" : query.hasPrefix("skill:") ? String(query.dropFirst(6)) : query
        for skill in skills where skillQuery.isEmpty
            || [skill.name, skill.displayName, skill.shortDescription, skill.description]
                .contains(where: { $0?.lowercased().contains(skillQuery) == true }) {
            items.append(Item(id: "skill:\(skill.name)", title: "skill:\(skill.name)", detail: skill.summary,
                              symbol: "sparkles", action: .insert("$\(skill.name) ")))
        }
        return items
    }

    /// `$` items: enabled, user-invocable skills, best match first, at most 20.
    nonisolated static func skillItems(query rawQuery: String, skills: [ProviderSkill]) -> [Item] {
        let query = String(rawQuery.trimmingCharacters(in: .whitespaces).lowercased()
            .drop { $0.unicodeScalars.first?.properties.generalCategory == .currencySymbol })
        let candidates = offerable(skills)
        let picked: [ProviderSkill]
        if query.isEmpty {
            picked = Array(candidates.prefix(20))
        } else {
            let ranked = candidates.compactMap { skill -> (skill: ProviderSkill, score: Int)? in
                let scores = [
                    score(skill.name.lowercased(), query, base: 0, boundaries: "-_/"),
                    score(skill.title.lowercased(), query, base: 1, boundaries: " -_/"),
                    score(skill.shortDescription?.lowercased() ?? "", query, base: 20, boundaries: " "),
                    score(skill.description?.lowercased() ?? "", query, base: 30, boundaries: " "),
                ].compactMap { $0 }
                return scores.min().map { (skill, $0) }
            }
            picked = ranked.sorted {
                $0.score != $1.score ? $0.score < $1.score : ($0.skill.title.lowercased(), $0.skill.name) < ($1.skill.title.lowercased(), $1.skill.name)
            }.prefix(20).map(\.skill)
        }
        return picked.map { skill in
            Item(id: "skill:\(skill.name)", title: skill.title, detail: skill.summary, symbol: "sparkles",
                 action: .insert("$\(skill.name) "))
        }
    }

    /// Exact 0, prefix 2, word start 4, anywhere 6, offset by `base` (searchRanking.ts, minus fuzzy).
    nonisolated private static func score(_ value: String, _ query: String, base: Int, boundaries: String) -> Int? {
        guard !value.isEmpty, let range = value.range(of: query) else { return nil }
        if value == query { return base }
        if range.lowerBound == value.startIndex { return base + 2 }
        var index = value.startIndex
        while let found = value.range(of: query, range: index..<value.endIndex) {
            if found.lowerBound > value.startIndex, boundaries.contains(value[value.index(before: found.lowerBound)]) {
                return base + 4
            }
            index = value.index(after: found.lowerBound)
        }
        return base + 6
    }

    /// Enabled and not agent-only, one per name.
    nonisolated static func offerable(_ skills: [ProviderSkill]) -> [ProviderSkill] {
        var seen = Set<String>()
        return skills.filter { skill in
            skill.enabled && skill.userInvocable && seen.insert(skill.name.trimmingCharacters(in: .whitespaces).lowercased()).inserted
        }
    }

    /// Entries for this project and repository, one per number. A number query keeps numbers
    /// containing it, exact first; a text query keeps entries whose title and branches contain
    /// every word. Newest first, at most 20.
    nonisolated static func pullRequestMatches(_ entries: [JSON], query: String, projectId: String, repository: String) -> [PullRequestReference] {
        let repository = repository.trimmingCharacters(in: .whitespaces).lowercased()
        let numeric = query.allSatisfy(\.isASCIIDigit)
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var seen = Set<Int>()
        let matches = entries.filter { entry in
            guard entry["projectId"]?.string == projectId,
                  entry["repository"]?.string?.trimmingCharacters(in: .whitespaces).lowercased() == repository,
                  let number = entry["number"]?.int else { return false }
            if numeric { return query.isEmpty || String(number).contains(query) }
            let haystack = [entry["title"], entry["headBranch"], entry["baseBranch"]].compactMap { $0?.string }
                .joined(separator: " ").lowercased()
            return words.allSatisfy(haystack.contains)
        }
        .compactMap { PullRequestReference(json: $0) }
        .filter { seen.insert($0.number).inserted }
        return matches.sorted { left, right in
            let leftExact = numeric && String(left.number) == query, rightExact = numeric && String(right.number) == query
            if leftExact != rightExact { return leftExact }
            return left.updatedAt > right.updatedAt
        }
        .prefix(20).map { $0 }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
