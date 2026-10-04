import Foundation

struct ProviderOptionDescriptor: Hashable, Sendable, Identifiable {
    struct Choice: Hashable, Sendable, Identifiable {
        var id: String
        var label: String
        var isDefault: Bool
    }

    var id: String
    var label: String
    var type: String  // "select" | "boolean"
    var choices: [Choice]
    var currentValue: JSON?

    init?(json: JSON) {
        guard let id = json["id"]?.string, let type = json["type"]?.string, type == "select" || type == "boolean" else { return nil }
        self.id = id
        self.type = type
        label = json["label"]?.string ?? id
        choices = (json["options"]?.array ?? []).compactMap {
            guard let id = $0["id"]?.string else { return nil }
            return Choice(id: id, label: $0["label"]?.string ?? id, isDefault: $0["isDefault"]?.bool ?? false)
        }
        currentValue = json["currentValue"]
    }

    var defaultValue: JSON? {
        if let currentValue { return currentValue }
        if type == "select" { return choices.first(where: \.isDefault).map { .string($0.id) } }
        return nil
    }
}

struct ProviderModel: Hashable, Sendable, Identifiable {
    var id: String { slug }
    var slug: String
    var name: String
    var shortName: String?
    var isDefault: Bool
    var isLegacy: Bool
    var options: [ProviderOptionDescriptor]

    init?(json: JSON) {
        guard let slug = json["slug"]?.string else { return nil }
        self.slug = slug
        name = json["name"]?.string ?? slug
        shortName = json["shortName"]?.string
        isDefault = json["isDefault"]?.bool ?? false
        isLegacy = json["isLegacy"]?.bool ?? false
        options = (json["capabilities"]?["optionDescriptors"]?.array ?? []).compactMap(ProviderOptionDescriptor.init(json:))
    }
}

struct Provider: Hashable, Sendable, Identifiable {
    var id: String { instanceId }
    var instanceId: String
    var driver: String
    var displayName: String
    var isUsable: Bool
    var supportedRuntimeModes: [String]
    var showInteractionModeToggle: Bool
    var models: [ProviderModel]
    var slashCommands: [SlashCommand]
    var skills: [ProviderSkill]
    /// Per-workspace commands and skills (project `.claude/skills` etc.), keyed by cwd.
    var workspaceSnapshots: [WorkspaceSnapshot]
    /// Subscription quota for the signed-in account, when the provider reports one.
    var usageLimits: ProviderUsageLimits?
    var installed: Bool
    var enabled: Bool

    struct SlashCommand: Hashable, Sendable {
        var name: String
        var description: String?

        init?(json: JSON) {
            guard let name = json["name"]?.string, !name.isEmpty else { return nil }
            self.name = name
            description = json["description"]?.string
        }
    }

    struct WorkspaceSnapshot: Hashable, Sendable {
        var cwd: String
        var slashCommands: [SlashCommand]
        var skills: [ProviderSkill]
    }

    init?(json: JSON) {
        guard let instanceId = json["instanceId"]?.string else { return nil }
        self.instanceId = instanceId
        driver = json["driver"]?.string ?? instanceId
        displayName = json["displayName"]?.string ?? Self.defaultName(driver)
        let enabled = json["enabled"]?.bool ?? true
        let installed = json["installed"]?.bool ?? true
        self.enabled = enabled
        self.installed = installed
        usageLimits = ProviderUsageLimits(json: json["usageLimits"])
        let available = json["availability"]?.string != "unavailable"
        isUsable = enabled && installed && available && json["status"]?.string != "disabled"
        supportedRuntimeModes = json["supportedRuntimeModes"]?.array?.compactMap(\.string)
            ?? ["approval-required", "auto-accept-edits", "auto", "full-access"]
        showInteractionModeToggle = json["showInteractionModeToggle"]?.bool ?? false
        models = (json["models"]?.array ?? []).compactMap(ProviderModel.init(json:))
        slashCommands = (json["slashCommands"]?.array ?? []).compactMap(SlashCommand.init(json:))
        skills = (json["skills"]?.array ?? []).compactMap(ProviderSkill.init(json:))
        workspaceSnapshots = (json["workspaceSnapshots"]?.array ?? []).compactMap { snapshot in
            guard let cwd = snapshot["cwd"]?.string else { return nil }
            return WorkspaceSnapshot(
                cwd: cwd,
                slashCommands: (snapshot["slashCommands"]?.array ?? []).compactMap(SlashCommand.init(json:)),
                skills: (snapshot["skills"]?.array ?? []).compactMap(ProviderSkill.init(json:))
            )
        }
    }

    func hasSnapshot(cwd: String?) -> Bool { cwd.map { cwd in workspaceSnapshots.contains { $0.cwd == cwd } } ?? false }

    /// The workspace's own commands when the provider has scanned that cwd, else the global ones.
    func slashCommands(cwd: String?) -> [SlashCommand] {
        workspaceSnapshots.first { $0.cwd == cwd }?.slashCommands ?? slashCommands
    }

    func skills(cwd: String?) -> [ProviderSkill] {
        workspaceSnapshots.first { $0.cwd == cwd }?.skills ?? skills
    }

    static func defaultName(_ driver: String) -> String {
        switch driver {
        case "claudeAgent": "Claude"
        case "codex": "Codex"
        case "cursor": "Cursor"
        case "grok": "Grok"
        case "opencode": "OpenCode"
        case "antigravity": "Antigravity"
        default: driver.capitalized
        }
    }
}

/// A skill the provider can run (`ServerProviderSkill`). The composer offers it as `$name`.
struct ProviderSkill: Hashable, Sendable {
    var name: String
    var displayName: String?
    var shortDescription: String?
    var description: String?
    var enabled: Bool
    /// `false` means only the agent may start it.
    var userInvocable: Bool

    init?(json: JSON) {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        displayName = json["displayName"]?.string
        shortDescription = json["shortDescription"]?.string
        description = json["description"]?.string
        enabled = json["enabled"]?.bool ?? true
        userInvocable = json["userInvocable"]?.bool ?? true
    }

    init(name: String, displayName: String? = nil, shortDescription: String? = nil, description: String? = nil) {
        self.name = name
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.description = description
        enabled = true
        userInvocable = true
    }

    var title: String { displayName ?? name }
    var summary: String { shortDescription ?? description ?? "" }
}

/// The parts of `ServerConfig` this client uses.
struct ServerConfig: Sendable {
    var environmentId: String
    var label: String
    var serverVersion: String?
    var capabilities: JSON
    var providers: [Provider]
    var defaultModelSelection: ModelSelection?
    var defaultRuntimeMode: String
    var shellResumeCompletionMarker: Bool
    var threadResumeCompletionMarker: Bool
    /// Where "no project" threads run; absent on servers without scratch support.
    var scratchWorkspaceRoot: String?
    /// Where `projects.createNew` puts new projects; absent when unsupported.
    var newProjectsRoot: String?
    /// Settings: where the folder browser starts, and the default for "Start from origin".
    var addProjectBaseDirectory: String?
    var newWorktreesStartFromOrigin: Bool

    init?(json: JSON) {
        guard let environment = json["environment"], let id = environment["environmentId"]?.string else { return nil }
        environmentId = id
        label = environment["label"]?.string ?? "Helm"
        serverVersion = environment["serverVersion"]?.string
        capabilities = environment["capabilities"] ?? [:]
        providers = (json["providers"]?.array ?? []).compactMap(Provider.init(json:))
        defaultModelSelection = ModelSelection(json: json["settings"]?["defaultModelSelection"]?.nonNull)
        defaultRuntimeMode = json["settings"]?["defaultRuntimeMode"]?.string ?? "full-access"
        shellResumeCompletionMarker = json["shellResumeCompletionMarker"]?.bool ?? false
        threadResumeCompletionMarker = json["threadResumeCompletionMarker"]?.bool ?? false
        scratchWorkspaceRoot = json["scratchWorkspaceRoot"]?.nonNull?.string
        newProjectsRoot = json["newProjectsRoot"]?.nonNull?.string
        addProjectBaseDirectory = nil
        newWorktreesStartFromOrigin = true
        applySettings(json["settings"])
    }

    /// The settings this client reads, from the snapshot or a `settingsUpdated` event.
    mutating func applySettings(_ settings: JSON?) {
        guard let settings else { return }
        let base = settings["addProjectBaseDirectory"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        addProjectBaseDirectory = base.isEmpty ? nil : base
        newWorktreesStartFromOrigin = settings["newWorktreesStartFromOrigin"]?.bool ?? true
    }

    /// The environment's scratch project backs "No project" threads; it always runs in place.
    func isScratch(_ project: Project) -> Bool {
        guard let scratchWorkspaceRoot else { return false }
        return project.workspaceRoot == scratchWorkspaceRoot
    }

    func capability(_ name: String) -> Bool { capabilities[name]?.bool ?? false }

    /// The largest file the server takes, or nil when it only takes images
    /// (needs both `attachmentUploads` and `fileAttachments`).
    var maxFileBytes: Int? {
        guard capability("attachmentUploads"), let files = capabilities["fileAttachments"]?.object else { return nil }
        return min(files["maxUploadBytes"]?.int ?? AttachmentLimits.maxFileBytes, AttachmentLimits.maxFileBytes)
    }

    /// Context records and `t3-context://` links travel as-is (else files go as a bare list).
    var inlineMessageContext: Bool { capability("inlineMessageContext") }

    var usableProviders: [Provider] { providers.filter(\.isUsable) }

    func provider(_ instanceId: String) -> Provider? { providers.first { $0.instanceId == instanceId } }

    func model(for selection: ModelSelection) -> ProviderModel? {
        provider(selection.instanceId)?.models.first { $0.slug == selection.model }
    }

    /// A short label for the composer chip: "Opus 5.5", "GPT-6.1".
    func modelLabel(for selection: ModelSelection?) -> String {
        guard let selection else { return String(localized: "Model") }
        if let model = model(for: selection) { return model.shortName ?? model.name }
        return selection.model
    }

    /// The selection a new thread starts with: project default, server default, then the first usable model.
    func initialSelection(project: Project?) -> ModelSelection? {
        if let selection = project?.defaultModelSelection, provider(selection.instanceId)?.isUsable == true { return selection }
        if let selection = defaultModelSelection, provider(selection.instanceId)?.isUsable == true { return selection }
        guard let provider = usableProviders.first,
              let model = provider.models.first(where: \.isDefault) ?? provider.models.first
        else { return nil }
        return ModelSelection(instanceId: provider.instanceId, model: model.slug)
    }
}

enum RuntimeMode: String, CaseIterable, Identifiable, Sendable {
    case approvalRequired = "approval-required"
    case autoAcceptEdits = "auto-accept-edits"
    case auto = "auto"
    case fullAccess = "full-access"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approvalRequired: String(localized: "Supervised")
        case .autoAcceptEdits: String(localized: "Auto-accept edits")
        case .auto: String(localized: "Auto")
        case .fullAccess: String(localized: "Full access")
        }
    }

    var detail: String {
        switch self {
        case .approvalRequired: String(localized: "Asks before commands and edits")
        case .autoAcceptEdits: String(localized: "Edits freely, asks before commands")
        case .auto: String(localized: "The agent decides what needs approval")
        case .fullAccess: String(localized: "Never asks")
        }
    }

    var symbol: String {
        switch self {
        case .approvalRequired: "hand.raised"
        case .autoAcceptEdits: "pencil.and.outline"
        case .auto: "wand.and.stars"
        case .fullAccess: "lock.open"
        }
    }
}
