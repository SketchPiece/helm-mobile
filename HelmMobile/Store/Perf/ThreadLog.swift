import Foundation

/// Always on, unlike the recordings: a line for every thread opened, saying what the screen showed
/// a moment later, and for every time a thread with history had no row on screen and was put back
/// at its end. Kept in Documents/Performance/threads.txt (the last 400 lines), so it is listed
/// under Settings → Performance → Recordings and `scripts/perf-report.py --pull` brings it over.
@MainActor
enum ThreadLog {
    private static let writer = Writer()
    private static var wroteHeader = false

    static func record(_ line: String) {
        guard !AppModel.isUnitTestHost else { return }
        var lines: [String] = []
        if !wroteHeader {
            wroteHeader = true
            lines.append("")
            lines.append("— app started · \(PerfMonitor.deviceSummary)")
        }
        lines.append(stamp(Date()) + "  " + line)
        Task { await writer.append(lines) }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private actor Writer {
        private var lines: [String]?
        private let keep = 400

        func append(_ new: [String]) {
            let file = PerfMonitor.directory.appendingPathComponent("threads.txt")
            var all = lines ?? ((try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? [])
            all.append(contentsOf: new)
            if all.count > keep { all.removeFirst(all.count - keep) }
            lines = all
            try? FileManager.default.createDirectory(at: PerfMonitor.directory, withIntermediateDirectories: true)
            try? (all.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
