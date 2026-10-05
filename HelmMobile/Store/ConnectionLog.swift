import Foundation
import os

/// What happened to the connections, step by step, so a failed connect can be read afterwards:
/// Settings → a computer → Connection log, or Console.app (subsystem = the bundle id, category
/// "connection") while the phone is plugged in. Kept in a file across launches, trimmed to the
/// last few thousand lines.
final class ConnectionLog: @unchecked Sendable {
    static let shared = ConnectionLog()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "helm", category: "connection")
    private let queue = DispatchQueue(label: "helm.connection-log")
    private let url: URL
    private var lines: [String]
    private static let keep = 3000

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("connection-log.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// `scope` says whose line it is: a computer's label, "app", "tailscale", "network".
    func log(_ scope: String, _ message: String) {
        let date = Date()
        logger.log("[\(scope, privacy: .public)] \(message, privacy: .public)")
        guard !AppModel.isUnitTestHost else { return }
        queue.async { [self] in
            lines.append("\(Self.stamp.string(from: date)) [\(scope)] \(message)")
            if lines.count > Self.keep + 500 { lines.removeFirst(lines.count - Self.keep) }
            scheduleWrite()
        }
    }

    private var writePending = false

    /// Batches bursts of lines into one write.
    private func scheduleWrite() {
        guard !writePending else { return }
        writePending = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            writePending = false
            try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var text: String { queue.sync { lines.joined(separator: "\n") } }

    func clear() {
        queue.async { [self] in
            lines.removeAll()
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// An error with what URLSession/POSIX said underneath, e.g. `NSURLErrorDomain -1004`.
    static func describe(_ error: Error) -> String {
        var parts = [error.localizedDescription]
        var current: NSError? = error as NSError
        var depth = 0
        // Our own Swift errors bridge with a "HelmMobile." domain and say it all in the description.
        while let ns = current, depth < 3, !ns.domain.hasPrefix("HelmMobile.") {
            parts.append("\(ns.domain) \(ns.code)")
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.joined(separator: " · ")
    }
}
