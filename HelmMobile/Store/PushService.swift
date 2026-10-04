import ActivityKit
import Foundation
import Observation
import Security
import UIKit
import UserNotifications

/// Notifications and the Live Activity through the Volna core's Helm relay (`<HELM_PUSH_URL>/helm`).
/// The Mac's Helm server publishes agent activity there; the core pushes alerts and Live
/// Activity updates to every registered phone. Spec: Volna `core/src/helm`, t3code `helm/push`.
@MainActor
@Observable
final class PushService: NSObject {
    static let shared = PushService()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var registered = false
    private(set) var lastError: String?
    /// A thread a notification or the Live Activity asked to open.
    var pendingThread: ThreadRef?
    /// The thread on screen; its notifications stay quiet while the app is open.
    @ObservationIgnored var visibleThread: ThreadRef?

    var liveActivitiesEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "push.liveActivities") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "push.liveActivities")
            if !newValue { endAllActivities() }
            Task { await register(force: true) }
        }
    }

    @ObservationIgnored private var pushToken: String?
    @ObservationIgnored private var tokenWatchers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var activityTokenPostedAt: [String: Date] = [:]

    struct Config: Sendable {
        var baseURL: URL
        var token: String
        var apsEnvironment: String
    }

    /// Nil unless this build can receive pushes (push-enabled App ID and relay credentials).
    nonisolated static let config: Config? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard (info["HelmPushEnabled"] as? String)?.uppercased() == "YES",
              let raw = (info["HelmPushURL"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let token = (info["HelmPushToken"] as? String)?.trimmingCharacters(in: .whitespaces), !token.isEmpty,
              let url = URL(string: raw.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression) + "/helm")
        else { return nil }
        return Config(baseURL: url, token: token, apsEnvironment: info["HelmApsEnvironment"] as? String ?? "production")
    }()

    var isAvailable: Bool { Self.config != nil }

    // MARK: Lifecycle

    func start() {
        // Unit tests host the app; a permission prompt there keeps the test runner from attaching.
        guard !AppModel.isUnitTestHost else { return }
        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.bool(forKey: "previewLiveActivity") { previewActivity() }
        guard isAvailable else { return }
        Task {
            await refreshAuthorization()
            if authorization == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refreshAuthorization()
            }
            if authorization == .authorized || authorization == .provisional {
                UIApplication.shared.registerForRemoteNotifications()
            }
            await register()
            await reconcileActivities()
        }
    }

    func foregrounded() {
        guard isAvailable, !AppModel.isUnitTestHost else { return }
        Task {
            await refreshAuthorization()
            await register()
            await reconcileActivities()
        }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard hex != pushToken else { return }
        pushToken = hex
        Task { await register() }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: Device registration

    /// Registers with the core; skipped when nothing changed since the last accepted call.
    func register(force: Bool = false) async {
        guard let config = Self.config else { return }
        let notificationsEnabled = pushToken != nil && (authorization == .authorized || authorization == .provisional)
        var body: [String: JSON] = [
            "deviceId": .string(Self.deviceId),
            "label": .string(UIDevice.current.name),
            "platform": "ios",
            "iosMajorVersion": .number(Double(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)),
            "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"),
            "bundleId": .string(Bundle.main.bundleIdentifier ?? ""),
            "apsEnvironment": .string(config.apsEnvironment),
            "preferences": [
                "liveActivitiesEnabled": .bool(liveActivitiesEnabled),
                "notificationsEnabled": .bool(notificationsEnabled),
                "notifyOnApproval": true, "notifyOnInput": true, "notifyOnCompletion": true, "notifyOnFailure": true,
            ],
        ]
        if let pushToken { body["pushToken"] = .string(pushToken) }
        let payload = JSON.object(body)
        let signature = (try? payload.data()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !force, registered, UserDefaults.standard.string(forKey: "push.signature") == signature { return }
        do {
            _ = try await send("POST", "/v1/mobile/devices", body: payload)
            UserDefaults.standard.set(signature, forKey: "push.signature")
            registered = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func send(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        guard let config = Self.config else { throw RPCError.disconnected }
        var request = URLRequest(url: config.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.data()
        }
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSON.parse(data)) ?? .null
        guard (200..<300).contains(status) else {
            throw HelmHTTPError.status(status, json["error"]?.string ?? "Push relay error")
        }
        return json
    }

    /// Stable per install-and-reinstall: kept in the Keychain.
    private static var deviceId: String {
        let account = "push-device-id"
        if let existing = Keychain.token(for: account) { return existing }
        let id = UUID().uuidString.lowercased()
        Keychain.setToken(id, for: account)
        return id
    }

    // MARK: Live Activity

    /// On launch and foreground: keep one card, start it if agents are busy, (re)post its token.
    func reconcileActivities() async {
        guard isAvailable, liveActivitiesEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await Self.endActivities(keepingFirst: true)
        var activities = Array(Activity<LiveActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .prefix(1))
        if activities.isEmpty,
           let snapshot = try? await send("GET", "/v1/mobile/agent-activity"),
           let aggregateJSON = snapshot["aggregate"], !aggregateJSON.isNull,
           let aggregate = try? aggregateJSON.decode(AgentAggregate.self), aggregate.activeCount > 0,
           Activity<LiveActivityAttributes>.activities.isEmpty
        {
            if let activity = startActivity(aggregate) { activities = [activity] }
        }
        for activity in activities { watchToken(of: activity, repost: true) }
    }

    /// When the user sends work: show a card right away; the core repaints it within seconds.
    func armForLocalWork(projectTitle: String, threadTitle: String) {
        guard isAvailable, liveActivitiesEnabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              Activity<LiveActivityAttributes>.activities.allSatisfy({ $0.activityState == .ended || $0.activityState == .dismissed })
        else { return }
        if let activity = startActivity(.placeholder(projectTitle: projectTitle, threadTitle: threadTitle)) {
            watchToken(of: activity, repost: true)
        }
    }

    /// `-previewLiveActivity YES`: a local card with sample rows, to look at the layout (no push).
    private func previewActivity() {
        let now = ISO8601DateFormatter.helmFractional.string(from: Date().addingTimeInterval(-185))
        func row(_ thread: String, _ project: String, _ phase: String, _ status: String) -> AgentAggregate.Row {
            .init(environmentId: "e", threadId: thread, projectTitle: project, threadTitle: thread, modelTitle: "Opus 5.5",
                  phase: phase, status: status, updatedAt: now, deepLink: "/threads/e/\(thread)")
        }
        let aggregate = AgentAggregate(
            title: "Helm", subtitle: "Agent work in progress", activeCount: 3, updatedAt: now,
            activities: [
                row("Fix the login redirect", "t3code", "running", "Working"),
                row("Set up Gmail API", "Volna", "waiting_for_approval", "Approval"),
                row("Draw room dimensions", "Mono", "running", "Working"),
            ]
        )
        _ = try? Activity.request(attributes: LiveActivityAttributes(url: nil),
                                  content: .init(state: aggregate.contentState, staleDate: nil), pushType: nil)
    }

    private func startActivity(_ aggregate: AgentAggregate) -> Activity<LiveActivityAttributes>? {
        try? Activity.request(
            attributes: LiveActivityAttributes(url: nil),
            content: .init(state: aggregate.contentState, staleDate: Date().addingTimeInterval(600)),
            pushType: .token
        )
    }

    private func watchToken(of activity: Activity<LiveActivityAttributes>, repost: Bool) {
        if let token = activity.pushToken {
            postActivityToken(token, id: activity.id, force: repost)
        }
        guard tokenWatchers[activity.id] == nil else { return }
        tokenWatchers[activity.id] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                self?.postActivityToken(token, id: activity.id, force: true)
            }
        }
    }

    private func postActivityToken(_ token: Data, id: String, force: Bool) {
        if !force, let posted = activityTokenPostedAt[id], Date().timeIntervalSince(posted) < 60 { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        activityTokenPostedAt[id] = Date()
        Task {
            await register()  // the core answers 404 for an unknown device
            do {
                _ = try await send("POST", "/v1/mobile/live-activities", body: [
                    "deviceId": .string(Self.deviceId), "activityPushToken": .string(hex),
                ])
            } catch {
                activityTokenPostedAt[id] = nil
                try? await Task.sleep(for: .seconds(15))
                postActivityToken(token, id: id, force: true)
            }
        }
    }

    private func endAllActivities() {
        Task { await Self.endActivities(keepingFirst: false) }
    }

    /// One card at a time; extras (from races between launch and a local send) are ended.
    nonisolated private static func endActivities(keepingFirst: Bool) async {
        let live = Activity<LiveActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        for activity in live.dropFirst(keepingFirst ? 1 : 0) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: Routing

    /// Notification payloads carry `deepLink: "/threads/<env>/<thread>"`, plus the raw ids.
    nonisolated static func thread(fromNotification userInfo: [AnyHashable: Any]) -> ThreadRef? {
        if let link = userInfo["deepLink"] as? String, let parsed = HelmLink.thread(fromPath: link) {
            return ThreadRef(environmentId: parsed.environmentId, threadId: parsed.threadId)
        }
        if let environment = userInfo["environmentId"] as? String, let thread = userInfo["threadId"] as? String {
            return ThreadRef(environmentId: environment, threadId: thread)
        }
        return nil
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions
    {
        let ref = Self.thread(fromNotification: notification.request.content.userInfo)
        let visible = await MainActor.run { PushService.shared.visibleThread }
        if let ref, ref == visible { return [] }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let ref = Self.thread(fromNotification: response.notification.request.content.userInfo) else { return }
        await MainActor.run { PushService.shared.pendingThread = ref }
    }
}
