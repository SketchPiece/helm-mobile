import Foundation
import os
import Synchronization

/// Performance diagnostics (Settings → Performance): what the app was doing when frames were late.
///
/// Off by default, and then every call here is one atomic load. On, it keeps the last few minutes:
/// - hitches: frames that came late (`FrameWatcher`), with what ran on the main thread during them;
/// - stalls: the main thread busy for longer than a few frames, with its stack sampled meanwhile
///   (`StallSampler`), symbolicated later on the Mac with `scripts/perf-report.py`;
/// - spans and counts: timed pieces of work (`measure`) and how often views were rebuilt (`count`);
/// - marks: screens opened, scrolling started and stopped, snapshots arrived.
/// "Save" writes it all to Documents/Performance as JSON plus a readable summary.
/// Spans are signposts too, so an Instruments trace shows them as Points of Interest.
enum Perf {
    static var isOn: Bool { PerfRecorder.shared.isOn.load(ordering: .relaxed) }

    private static let signposter = OSSignposter(subsystem: "com.sketchpiece.helm", category: .pointsOfInterest)

    /// Times `body`. Work over a millisecond on the main thread is kept as an event of its own.
    @discardableResult
    static func measure<T>(_ name: String, units: Int = 0, _ body: () throws -> T) rethrows -> T {
        guard isOn else { return try body() }
        let state = signposter.beginInterval("span", id: signposter.makeSignpostID(), "\(name, privacy: .public)")
        let start = PerfClock.now()
        defer {
            let end = PerfClock.now()
            signposter.endInterval("span", state)
            PerfRecorder.shared.span(name, start: start, end: end, units: units, main: pthread_main_np() != 0)
        }
        return try body()
    }

    /// Counts something that is too small to time, such as a view's body being evaluated.
    static func count(_ name: String, units: Int = 0) {
        guard isOn else { return }
        PerfRecorder.shared.span(name, start: nil, end: PerfClock.now(), units: units, main: pthread_main_np() != 0)
    }

    /// A moment worth seeing next to the hitches: a screen opened, a snapshot arrived.
    static func mark(_ name: String, _ detail: @autoclosure () -> String = "") {
        guard isOn else { return }
        let detail = detail()
        signposter.emitEvent("mark", "\(name, privacy: .public) \(detail, privacy: .public)")
        PerfRecorder.shared.mark(name, detail: detail)
    }
}

/// Seconds on the host clock, the one `CACurrentMediaTime()` and `CADisplayLink` use.
enum PerfClock {
    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    static func now() -> Double { Double(mach_absolute_time()) * timebase }
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * timebase }
}

/// One thing that happened, at `t` seconds since the recording started.
struct PerfEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case mark, span, hitch, stall, scroll }
    var kind: Kind
    var t: Double
    var ms: Double?
    var name: String
    var detail: String?
    /// For hitches and stalls: the screen, the scrolling and the main-thread work around them.
    var context: String?
    /// For hitches: what ran on the main thread while that frame was due, worst first.
    var work: [PerfWork]?
}

struct PerfWork: Codable, Sendable {
    var name: String
    var count: Int
    var ms: Double
}

struct PerfStat: Codable, Sendable {
    var name: String
    var count = 0
    var mainCount = 0
    var totalMs = 0.0
    var maxMs = 0.0
    var mainMs = 0.0
    /// Whatever the caller counts alongside, e.g. bytes parsed.
    var units = 0
}

/// A stretch the main thread didn't answer, with its stacks sampled every few milliseconds.
struct PerfStall: Codable, Sendable {
    var t: Double
    var ms: Double
    var context: String?
    /// Return addresses, innermost first.
    var samples: [[UInt]]
}

/// Collects everything while diagnostics are on. Callable from any thread.
final class PerfRecorder: Sendable {
    static let shared = PerfRecorder()

    let isOn = Atomic<Bool>(false)

    struct State {
        var origin = PerfClock.now()
        var startedAt = Date()
        var events: [PerfEvent] = []
        var stats: [String: PerfStat] = [:]
        var stalls: [PerfStall] = []
        /// Main-thread work since the last frame, handed to a hitch if that frame was late.
        var frameWork: [String: PerfWork] = [:]
        var route = "launch"
        var scrolling: String?
        // Frame totals.
        var frames = 0
        var hitches = 0
        var hitchMs = 0.0
        var seconds = 0.0
        var scrollSeconds = 0.0
        var scrollHitchMs = 0.0
    }

    let state = Mutex(State())
    /// The last few minutes are enough to cover "it just stuttered"; older events go.
    private static let keepSeconds = 300.0
    private static let maxEvents = 40_000

    func reset() {
        state.withLock { $0 = State(route: $0.route, scrolling: $0.scrolling) }
    }

    func span(_ name: String, start: Double?, end: Double, units: Int, main: Bool) {
        let ms = start.map { (end - $0) * 1000 } ?? 0
        state.withLock { state in
            var stat = state.stats[name] ?? PerfStat(name: name)
            stat.count += 1
            stat.totalMs += ms
            stat.maxMs = max(stat.maxMs, ms)
            stat.units += units
            if main {
                stat.mainCount += 1
                stat.mainMs += ms
                var work = state.frameWork[name] ?? PerfWork(name: name, count: 0, ms: 0)
                work.count += 1
                work.ms += ms
                state.frameWork[name] = work
                if ms >= 1, let start {
                    append(PerfEvent(kind: .span, t: start - state.origin, ms: ms, name: name), to: &state)
                }
            }
            state.stats[name] = stat
        }
    }

    func mark(_ name: String, detail: String) {
        state.withLock { state in
            append(PerfEvent(kind: .mark, t: PerfClock.now() - state.origin, name: name,
                             detail: detail.isEmpty ? nil : detail), to: &state)
        }
    }

    func route(_ route: String) {
        state.withLock { state in
            state.route = route
            append(PerfEvent(kind: .mark, t: PerfClock.now() - state.origin, name: "route", detail: route), to: &state)
        }
    }

    func scroll(_ name: String, phase: String, active: Bool) {
        state.withLock { state in
            state.scrolling = active ? name : nil
            append(PerfEvent(kind: .scroll, t: PerfClock.now() - state.origin, name: name, detail: phase), to: &state)
        }
    }

    /// A frame arrived `interval` seconds after the previous one, which was due after `expected`.
    /// Returns whether it was a hitch.
    func frame(at time: Double, interval: Double, expected: Double) -> Bool {
        state.withLock { state in
            defer { state.frameWork.removeAll(keepingCapacity: true) }
            state.frames += 1
            state.seconds += interval
            if state.scrolling != nil { state.scrollSeconds += interval }
            // Late by at least half a frame: one or more frames were skipped.
            guard interval > expected * 1.5 else { return false }
            let ms = (interval - expected) * 1000
            state.hitches += 1
            state.hitchMs += ms
            if state.scrolling != nil { state.scrollHitchMs += ms }
            let work = state.frameWork.values.sorted { $0.ms > $1.ms }.prefix(8)
            append(PerfEvent(kind: .hitch, t: time - interval - state.origin, ms: ms, name: "hitch",
                             context: context(state), work: Array(work)), to: &state)
            return true
        }
    }

    func stall(start: Double, end: Double, samples: [[UInt]]) {
        state.withLock { state in
            let ms = (end - start) * 1000
            let stall = PerfStall(t: start - state.origin, ms: ms, context: context(state), samples: samples)
            if state.stalls.count >= 300 { state.stalls.removeFirst(100) }
            state.stalls.append(stall)
            append(PerfEvent(kind: .stall, t: stall.t, ms: ms, name: "stall", detail: "\(samples.count) samples",
                             context: stall.context), to: &state)
        }
    }

    private func context(_ state: State) -> String {
        var parts = [state.route]
        if let scrolling = state.scrolling { parts.append("scrolling \(scrolling)") }
        return parts.joined(separator: " · ")
    }

    private func append(_ event: PerfEvent, to state: inout State) {
        state.events.append(event)
        guard state.events.count > Self.maxEvents || (state.events.count % 1000 == 0) else { return }
        let cutoff = PerfClock.now() - state.origin - Self.keepSeconds
        state.events.removeAll { $0.t < cutoff }
        state.stalls.removeAll { $0.t < cutoff }
        if state.events.count > Self.maxEvents { state.events.removeFirst(state.events.count - Self.maxEvents) }
    }

    /// Everything so far, and a fresh start.
    func take() -> State {
        state.withLock { state in
            let taken = state
            state = State(route: state.route, scrolling: state.scrolling)
            return taken
        }
    }
}
