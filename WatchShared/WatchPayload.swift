import Foundation

// What the phone and the watch say to each other over WatchConnectivity. The phone holds the
// connections to the Macs (Tailscale, tokens); the watch is a remote for it: it shows a snapshot of
// the thread list and asks the phone to act. Every payload travels as JSON under `WatchKey.payload`.

enum WatchKey {
    static let payload = "payload"
    static let kind = "kind"
}

/// The thread list as the watch draws it. Sent as the application context (latest wins), and
/// pushed straight away while the watch app is open.
struct WatchSnapshot: Codable, Hashable, Sendable {
    var macs: [WatchMac]
    var threads: [WatchThread]
    var projects: [WatchProject]
    var updatedAt: Date

    static let empty = WatchSnapshot(macs: [], threads: [], projects: [], updatedAt: .distantPast)

    var needsYou: [WatchThread] { threads.filter { $0.phase == .approval || $0.phase == .input } }
}

struct WatchMac: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var label: String
    var isLive: Bool
}

struct WatchProject: Codable, Hashable, Sendable, Identifiable {
    var environmentId: String
    var projectId: String
    var title: String
    var icon: WatchIcon
    var macLabel: String
    var id: String { "\(environmentId)|\(projectId)" }
}

/// A project's tile: its emoji, or letters on a colour.
struct WatchIcon: Codable, Hashable, Sendable {
    var emoji: String?
    var letters: String
    var color: String?
}

enum WatchPhase: String, Codable, Sendable {
    case approval, input, working, waiting, failed, limited, done, idle
}

struct WatchThread: Codable, Hashable, Sendable, Identifiable {
    var environmentId: String
    var threadId: String
    var title: String
    var projectTitle: String
    var icon: WatchIcon
    var phase: WatchPhase
    /// The latest visible message, trimmed for a glance.
    var latestText: String?
    var latestRole: String?
    var lastError: String?
    var updatedAt: Date?
    var isPinned: Bool
    var isSettled: Bool
    var isSnoozed: Bool
    var id: String { "\(environmentId)|\(threadId)" }
}

/// One open thread: the end of its conversation and what it waits for.
struct WatchThreadDetail: Codable, Hashable, Sendable {
    var thread: WatchThread
    var messages: [WatchMessage]
    var requests: [WatchRequest]
    var isWorking: Bool
    var queuedCount: Int
    /// The phone hasn't got the live thread yet (still connecting, or the Mac is away).
    var isStale: Bool
}

struct WatchMessage: Codable, Hashable, Sendable, Identifiable {
    enum Role: String, Codable, Sendable { case user, assistant, work, error, plan }
    var id: String
    var role: Role
    var text: String
    var date: Date?
}

struct WatchRequest: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case approval, questions }
    var id: String
    var kind: Kind
    var canRespond: Bool
    /// Approval: what the agent asks to do ("Run command"), and the command or files.
    var title: String?
    var detail: String?
    var options: [Option]
    var questions: [Question]
    /// A question card the agent can do without (`thread.user-input.dismiss`).
    var dismissible: Bool

    struct Option: Codable, Hashable, Sendable {
        var decision: String
        var label: String
        var isWarning: Bool
    }

    struct Question: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var header: String?
        var question: String
        var options: [Choice]
        var multiSelect: Bool
        var allowCustomAnswer: Bool
    }

    struct Choice: Codable, Hashable, Sendable {
        var label: String
        var detail: String?
        var answer: String
    }
}

/// What the watch asks the phone for. Each one is answered with a `WatchReply`.
enum WatchRequestMessage: Codable, Sendable {
    case snapshot
    /// Subscribe to a thread; the phone pushes `WatchPush.detail` while the watch looks at it.
    case open(environmentId: String, threadId: String)
    case close(environmentId: String, threadId: String)
    case respond(environmentId: String, threadId: String, requestId: String, decision: String)
    case answer(environmentId: String, threadId: String, requestId: String, answers: [String: [String]])
    case dismiss(environmentId: String, threadId: String, requestId: String)
    case send(environmentId: String, threadId: String, text: String)
    case interrupt(environmentId: String, threadId: String)
    case settle(environmentId: String, threadId: String)
    case snooze(environmentId: String, threadId: String, until: Date)
    case launch(environmentId: String, projectId: String, text: String)
}

struct WatchReply: Codable, Sendable {
    var ok: Bool
    var error: String?
    var snapshot: WatchSnapshot?
    var detail: WatchThreadDetail?
    /// A thread the watch just started, to open next.
    var threadId: String?

    static let success = WatchReply(ok: true)

    static func failure(_ message: String) -> WatchReply { WatchReply(ok: false, error: message) }

    init(ok: Bool, error: String? = nil, snapshot: WatchSnapshot? = nil, detail: WatchThreadDetail? = nil, threadId: String? = nil) {
        self.ok = ok
        self.error = error
        self.snapshot = snapshot
        self.detail = detail
        self.threadId = threadId
    }
}

/// What the phone sends on its own.
enum WatchPush: Codable, Sendable {
    case snapshot(WatchSnapshot)
    case detail(WatchThreadDetail)
}

enum WatchCoding {
    static func encode(_ value: some Encodable) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return [:] }
        return [WatchKey.payload: data]
    }

    static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
        guard let data = dictionary[WatchKey.payload] as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
