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
    var slashCommands: [String]

    init?(json: JSON) {
        guard let instanceId = json["instanceId"]?.string else { return nil }
        self.instanceId = instanceId
        driver = json["driver"]?.string ?? instanceId
        displayName = json["displayName"]?.string ?? Self.defaultName(driver)
        let enabled = json["enabled"]?.bool ?? true
        let installed = json["installed"]?.bool ?? true
        let available = json["availability"]?.string != "unavailable"
        isUsable = enabled && installed && available && json["status"]?.string != "disabled"
        supportedRuntimeModes = json["supportedRuntimeModes"]?.array?.compactMap(\.string)
            ?? ["approval-required", "auto-accept-edits", "auto", "full-access"]
        showInteractionModeToggle = json["showInteractionModeToggle"]?.bool ?? false
        models = (json["models"]?.array ?? []).compactMap(ProviderModel.init(json:))
        slashCommands = (json["slashCommands"]?.array ?? []).compactMap { $0["name"]?.string }
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
    }

    func capability(_ name: String) -> Bool { capabilities[name]?.bool ?? false }

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
