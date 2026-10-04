import Foundation
import Network
import Observation
import UIKit

/// Identifies a thread across environments.
struct ThreadRef: Hashable, Codable, Sendable {
    var environmentId: String
    var threadId: String
}

/// A thread row with what the list needs to draw it.
struct ThreadListEntry: Identifiable, Hashable {
    var ref: ThreadRef
    var thread: ThreadSummary
    var project: Project?
    var environmentLabel: String
    var id: ThreadRef { ref }
}

@MainActor
@Observable
final class AppModel {
    private(set) var environments: [EnvironmentSession] = []
    let tailscale = TailscaleService()
    @ObservationIgnored private let pathMonitor = NWPathMonitor()

    init() {
        environments = SavedEnvironments.load().map(EnvironmentSession.init(saved:))
        tailscale.startIfConfigured()
        tailscale.onRunning = { [weak self] in
            self?.environments.filter { !$0.isLive }.forEach { $0.reconnectNow() }
        }
        environments.forEach { $0.start() }
        // A new network path (Wi-Fi ↔ cellular, Tailscale toggled) is the moment a dropped
        // connection can come back; don't wait for the backoff timer.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                // Live sockets may be bound to the old interface: probe them; wake the rest.
                for environment in self?.environments ?? [] {
                    if environment.isLive {
                        Task { await environment.refreshAfterForeground() }
                    } else {
                        environment.reconnectNow()
                    }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "helm.path"))
    }

    var hasEnvironments: Bool { !environments.isEmpty }

    func environment(_ id: String) -> EnvironmentSession? { environments.first { $0.id == id } }

    static func persistLabel(id: String, label: String) {
        var list = SavedEnvironments.load()
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index].label = label
            SavedEnvironments.save(list)
        }
    }

    // MARK: Pairing

    /// Pairs with a server: checks the descriptor, trades the one-time code for a bearer and
    /// starts the session. Re-pairing an existing environment replaces its token and address.
    @discardableResult
    func pair(_ target: PairingTarget) async throws -> EnvironmentSession {
        let http = HelmHTTP(baseURL: target.baseURL, token: nil)
        let descriptor = try await http.descriptor()
        let token = try await http.exchange(code: target.code)
        Keychain.setToken(token, for: descriptor.environmentId)
        let saved = SavedEnvironment(
            id: descriptor.environmentId, label: descriptor.label, baseURL: target.baseURL, pairedAt: Date()
        )
        var list = SavedEnvironments.load().filter { $0.id != saved.id }
        list.append(saved)
        SavedEnvironments.save(list)
        if let existing = environment(saved.id) {
            existing.stop()
            environments.removeAll { $0.id == saved.id }
        }
        let session = EnvironmentSession(saved: saved)
        environments.append(session)
        session.start()
        return session
    }

    func remove(_ environment: EnvironmentSession) {
        environment.stop()
        environments.removeAll { $0.id == environment.id }
        SavedEnvironments.save(SavedEnvironments.load().filter { $0.id != environment.id })
        Keychain.setToken(nil, for: environment.id)
    }

    func foregrounded() {
        for environment in environments {
            Task { await environment.refreshAfterForeground() }
        }
    }

    // MARK: Thread list

    func allThreads() -> [ThreadListEntry] {
        environments.flatMap { environment in
            environment.shell.threads.values.compactMap { thread -> ThreadListEntry? in
                guard !thread.isSubagent else { return nil }
                return ThreadListEntry(
                    ref: ThreadRef(environmentId: environment.id, threadId: thread.id),
                    thread: thread,
                    project: environment.shell.projects[thread.projectId],
                    environmentLabel: environment.label
                )
            }
        }
    }

    func allProjects() -> [(environment: EnvironmentSession, project: Project)] {
        environments.flatMap { environment in
            environment.shell.projects.values.map { (environment, $0) }
        }
        .sorted { ($0.project.updatedAt ?? .distantPast) > ($1.project.updatedAt ?? .distantPast) }
    }

    // MARK: Thread actions

    enum ThreadAction {
        case settle, unsettle, archive, unarchive, delete, unsnooze, pin, unpin, markUnread, regenerateTitle
        case snooze(Date)
        case rename(String)
    }

    func perform(_ action: ThreadAction, on ref: ThreadRef) async throws {
        guard let environment = environment(ref.environmentId) else { return }
        let id: JSON = .string(ref.threadId)
        switch action {
        case .settle: try await environment.dispatch("thread.settle", ["threadId": id])
        case .unsettle: try await environment.dispatch("thread.unsettle", ["threadId": id, "reason": "user"])
        case .archive: try await environment.dispatch("thread.archive", ["threadId": id])
        case .unarchive: try await environment.dispatch("thread.unarchive", ["threadId": id])
        case .delete: try await environment.dispatch("thread.delete", ["threadId": id])
        case .unsnooze: try await environment.dispatch("thread.unsnooze", ["threadId": id, "reason": "user"])
        case .pin: try await environment.dispatch("thread.pin", ["threadId": id])
        case .unpin: try await environment.dispatch("thread.unpin", ["threadId": id])
        case .markUnread: try await environment.dispatch("thread.mark-unread", ["threadId": id])
        case .regenerateTitle:
            try await environment.dispatch("thread.metadata.update", ["threadId": id, "regenerateTitle": true])
        case .snooze(let date):
            try await environment.dispatch("thread.snooze", ["threadId": id, "snoozedUntil": .string(ISODate.string(date))])
        case .rename(let title):
            try await environment.dispatch("thread.metadata.update", ["threadId": id, "title": .string(title)])
        }
        await UIImpactFeedbackGenerator.light()
    }

    // MARK: New thread

    struct LaunchRequest {
        var environment: EnvironmentSession
        var projectId: String
        var text: String
        var attachments: [ChatAttachment]
        var context: JSON? = nil
        var modelSelection: ModelSelection
        var runtimeMode: String
        var interactionMode: String
        var newWorktree: Bool
        var baseBranch: String?
    }

    /// `orchestration.launchThread`: creates the thread and sends its first message.
    func launch(_ request: LaunchRequest) async throws -> ThreadRef {
        let threadId = UUID().uuidString.lowercased()
        var strategy: JSON = ["type": "root"]
        if request.newWorktree {
            var worktree: [String: JSON] = [
                "type": "worktree",
                "baseRef": .string(request.baseBranch ?? "HEAD"),
                "branch": .string("helm/\(threadId.prefix(8))"),
            ]
            if request.baseBranch != nil { worktree["startFromOrigin"] = false }
            strategy = .object(worktree)
        }
        let title = Self.titleSeed(ContextReference.displayText(request.text))
        var initialMessage: [String: JSON] = [
            "messageId": .string(UUID().uuidString.lowercased()),
            "text": .string(request.text),
            "attachments": .array(request.attachments.map(\.json)),
        ]
        if let context = request.context { initialMessage["context"] = context }
        let payload: JSON = [
            "commandId": .string(UUID().uuidString.lowercased()),
            "creationSource": "mobile",
            "threadId": .string(threadId),
            "projectId": .string(request.projectId),
            "title": .string(title),
            "generateTitle": true,
            "modelSelection": request.modelSelection.json,
            "runtimeMode": .string(request.runtimeMode),
            "interactionMode": .string(request.interactionMode),
            "workspaceStrategy": strategy,
            "initialMessage": .object(initialMessage),
        ]
        let result = try await request.environment.call("orchestration.launchThread", payload, timeout: .seconds(60))
        let id = result["threadId"]?.string ?? threadId
        if let projectionJSON = result["projection"], let projection = ThreadProjection(json: projectionJSON) {
            request.environment.cache(projection)
        }
        return ThreadRef(environmentId: request.environment.id, threadId: id)
    }

    static func titleSeed(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "New thread") }
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}

extension UIImpactFeedbackGenerator {
    static func light() async {
        await MainActor.run { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
}
