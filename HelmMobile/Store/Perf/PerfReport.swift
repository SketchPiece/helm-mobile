import Foundation
import UIKit

/// A saved recording: `perf-<date>.json` with everything (for `scripts/perf-report.py`, which
/// symbolicates the stall stacks against the build's dSYM) and `perf-<date>.txt` to read here.
enum PerfReport {
    struct File: Codable {
        var version = 1
        var device: String
        var appUUID: String?
        var startedAt: Date
        var seconds: Double
        var frames: Int
        var hitches: Int
        var hitchMs: Double
        var scrollSeconds: Double
        var scrollHitchMs: Double
        var events: [PerfEvent]
        var stats: [PerfStat]
        var stalls: [PerfStall]
        var symbols: [String: PerfSymbols.Frame]
        var images: [PerfSymbols.Image]
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Writes both files and returns the summary's URL.
    static func write(_ state: PerfRecorder.State, device: String) -> URL? {
        let addresses = Set(state.stalls.flatMap { $0.samples.joined() })
        let resolved = PerfSymbols.resolve(addresses)
        let file = File(
            device: device, appUUID: PerfSymbols.appUUID, startedAt: state.startedAt, seconds: state.seconds,
            frames: state.frames, hitches: state.hitches, hitchMs: state.hitchMs,
            scrollSeconds: state.scrollSeconds, scrollHitchMs: state.scrollHitchMs,
            events: state.events, stats: state.stats.values.sorted { $0.mainMs > $1.mainMs },
            stalls: state.stalls, symbols: resolved.frames, images: resolved.images
        )
        let directory = PerfMonitor.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("perf-\(fileStamp(Date()))")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let json = try? encoder.encode(file) else { return nil }
        let summaryURL = base.appendingPathExtension("txt")
        do {
            try json.write(to: base.appendingPathExtension("json"))
            try summary(file).write(to: summaryURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return summaryURL
    }

    // MARK: Summary

    static func summary(_ file: File) -> String {
        var out: [String] = []
        func ms(_ value: Double) -> String { String(format: "%.0f ms", value) }
        func ratio(_ hitchMs: Double, _ seconds: Double) -> String {
            seconds > 0 ? String(format: "%.1f ms/s", hitchMs / seconds) : "–"
        }
        out.append("Helm performance report")
        out.append(file.device)
        out.append("Started \(file.startedAt.formatted(date: .abbreviated, time: .standard)), "
            + String(format: "%.0f s on screen, %d frames (%.0f fps)", file.seconds, file.frames,
                     file.seconds > 0 ? Double(file.frames) / file.seconds : 0))
        out.append("App build UUID \(file.appUUID ?? "?")")
        out.append("")
        out.append("FRAMES")
        out.append("Hitches: \(file.hitches), \(ms(file.hitchMs)) late in total; hitch ratio \(ratio(file.hitchMs, file.seconds)) overall")
        out.append(String(format: "While scrolling: %.1f s, ", file.scrollSeconds) + "\(ms(file.scrollHitchMs)) late, ratio \(ratio(file.scrollHitchMs, file.scrollSeconds))")
        out.append("(Hitch ratio: under 5 ms/s is smooth, 5–10 noticeable, over 10 bad.)")

        let hitches = file.events.filter { $0.kind == .hitch }
        if !hitches.isEmpty {
            out.append("")
            out.append("WORST HITCHES (when, how late, where, main-thread work that frame)")
            for hitch in hitches.sorted(by: { ($0.ms ?? 0) > ($1.ms ?? 0) }).prefix(25) {
                let work = (hitch.work ?? []).prefix(4).map { "\($0.name) ×\($0.count) \(ms($0.ms))" }.joined(separator: ", ")
                out.append(String(format: "+%7.2fs %5.0f ms  ", hitch.t, hitch.ms ?? 0) + (hitch.context ?? "")
                    + (work.isEmpty ? "" : "\n                     \(work)"))
            }
        }

        if !file.stalls.isEmpty {
            out.append("")
            out.append("STALLS (main thread busy over 32 ms): \(file.stalls.count), worst \(ms(file.stalls.map(\.ms).max() ?? 0))")
            for stall in file.stalls.sorted(by: { $0.ms > $1.ms }).prefix(10) {
                out.append(String(format: "+%7.2fs %5.0f ms  ", stall.t, stall.ms) + (stall.context ?? ""))
            }
            out.append("")
            out.append("WHERE THE STALLS WERE (share of samples a frame was on the stack; app frames need perf-report.py)")
            out.append(contentsOf: hotFrames(file).prefix(40).map { String(format: "%5.1f%%  ", $0.share * 100) + $0.name })
        }

        let stats = file.stats.filter { $0.mainCount > 0 }
        if !stats.isEmpty {
            out.append("")
            out.append("MAIN-THREAD WORK (count, total, max)")
            for stat in stats.prefix(30) {
                out.append(String(format: "%-34@ %7d %9.1f ms %7.1f ms", stat.name as NSString, stat.mainCount, stat.mainMs, stat.maxMs)
                    + (stat.units > 0 ? "  units \(stat.units)" : ""))
            }
        }
        let background = file.stats.filter { $0.count > $0.mainCount }
        if !background.isEmpty {
            out.append("")
            out.append("OFF THE MAIN THREAD")
            for stat in background.sorted(by: { $0.totalMs > $1.totalMs }).prefix(15) {
                out.append(String(format: "%-34@ %7d %9.1f ms %7.1f ms", stat.name as NSString, stat.count - stat.mainCount,
                                  stat.totalMs - stat.mainMs, stat.maxMs)
                    + (stat.units > 0 ? "  units \(stat.units)" : ""))
            }
        }

        let marks = file.events.filter { $0.kind == .mark || $0.kind == .scroll }
        if !marks.isEmpty {
            out.append("")
            out.append("WHAT HAPPENED (last 120)")
            for mark in marks.suffix(120) {
                out.append(String(format: "+%7.2fs  ", mark.t) + mark.name + (mark.detail.map { " \($0)" } ?? ""))
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Frames by the share of stall samples they appear in (inclusive), named as well as the
    /// phone can: system symbols by dladdr, the app's own frames as offsets.
    private static func hotFrames(_ file: File) -> [(name: String, share: Double)] {
        var counts: [String: Int] = [:]
        var total = 0
        for stall in file.stalls {
            for sample in stall.samples {
                total += 1
                var seen = Set<String>()
                for address in sample {
                    let frame = file.symbols[String(address, radix: 16)]
                    let name = frame.map { "\($0.image)  \($0.symbol ?? String(format: "+0x%llx", UInt64($0.offset)))" } ?? "?"
                    if seen.insert(name).inserted { counts[name, default: 0] += 1 }
                }
            }
        }
        guard total > 0 else { return [] }
        return counts.map { ($0.key, Double($0.value) / Double(total)) }
            .filter { $0.share >= 0.05 }
            .sorted { $0.share > $1.share }
    }
}
