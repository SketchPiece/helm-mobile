import GameController
import Observation
import SwiftUI
import UIKit

/// Thread scroll trace: what the thread's scroll view did and why, to chase "I sent a message and it
/// landed somewhere odd". Always on, keeping the last three minutes:
/// - the scroll geometry on every change (offset, content height, how far from the end);
/// - every programmatic jump to the end, with who asked for it;
/// - sends, new content, the keyboard, the composer's height, scroll phases, "↓" coming and going;
/// - flags: shaking the device, or the HUD's flag button (or ⌃⌘F), marks "that was odd";
/// - what the thread itself catches (`caught`): a blank screen, a landing short of the end, a jump.
/// A flag or a catch saves the minute before it (and a few seconds after) as `scroll-<date>.txt`
/// (read it here) and `.json` next to the performance recordings, so `scripts/perf-report.py --pull`
/// brings them to the Mac too. The HUD (Settings → Performance) only shows the counter and Save.
@MainActor
@Observable
final class ScrollTrace {
    static let shared = ScrollTrace()
    static let enabledKey = "scrollTrace"

    static private(set) var isOn = false

    /// The thread's state at the moment, carried by every event.
    struct Snapshot: Codable, Sendable {
        /// Raw content offset, content height, the scroll view's height and its insets.
        var offset = 0.0
        var height = 0.0
        var viewport = 0.0
        var insetTop = 0.0
        var insetBottom = 0.0
        var phase = "idle"
        var bottomVisible = true
        var followsBottom = true
        /// The software keyboard's height over the window, 0 when it's down.
        var keyboard = 0.0
        /// How far short of the end the view is; negative is past the end. The viewport leaves out
        /// both insets, and the raw offset starts at minus the top inset.
        var gap: Double { height - viewport - insetTop - offset }
    }

    struct Event: Codable, Sendable {
        var t: Double
        var kind: String
        var detail: String?
        var state: Snapshot
        var gap: Double
    }

    // What the HUD shows.
    private(set) var eventCount = 0
    private(set) var flags = 0
    private(set) var startedAt = Date()

    @ObservationIgnored private var events: [Event] = []
    @ObservationIgnored private(set) var state = Snapshot()
    @ObservationIgnored private var origin = PerfClock.now()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var thread = ""

    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var lastAutoSave = -Double.infinity

    private static let keepSeconds = 180.0
    private static let maxEvents = 30_000
    /// What a flag or a catch saves: this long before it, and `saveDelay` after it.
    private static let windowSeconds = 60.0
    private static let saveDelay = 3.0
    /// At most one saved catch this often (a flag always saves); the newest `keepFiles` stay.
    private static let catchInterval = 20.0
    nonisolated private static let keepFiles = 40

    /// Starts recording, once, at launch.
    func start() {
        guard !Self.isOn, !AppModel.isUnitTestHost else { return }
        Self.isOn = true
        reset()
        let center = NotificationCenter.default
        for (name, label) in [(UIResponder.keyboardWillShowNotification, "will show"),
                              (UIResponder.keyboardDidShowNotification, "did show"),
                              (UIResponder.keyboardWillHideNotification, "will hide"),
                              (UIResponder.keyboardDidHideNotification, "did hide")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                MainActor.assumeIsolated { ScrollTrace.shared.keyboard(label, frame: frame) }
            })
        }
        record("trace on", Self.environmentSummary)
    }

    private func reset() {
        events = []
        origin = PerfClock.now()
        startedAt = Date()
        eventCount = 0
        flags = 0
    }

    // MARK: Recording

    /// Something happened; it is stored with the state at that moment.
    static func log(_ kind: String, _ detail: @autoclosure () -> String = "") {
        guard isOn else { return }
        shared.record(kind, detail())
    }

    private func record(_ kind: String, _ detail: String = "") {
        let event = Event(t: PerfClock.now() - origin, kind: kind, detail: detail.isEmpty ? nil : detail,
                          state: state, gap: state.gap)
        events.append(event)
        eventCount += 1
        if events.count > Self.maxEvents || events.count % 2000 == 0 {
            let cutoff = event.t - Self.keepSeconds
            events.removeAll { $0.t < cutoff }
            if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        }
    }

    static func geometry(_ geometry: ScrollGeometry) {
        guard isOn else { return }
        var next = shared.state
        next.offset = geometry.contentOffset.y
        next.height = geometry.contentSize.height
        next.viewport = geometry.containerSize.height
        next.insetTop = geometry.contentInsets.top
        next.insetBottom = geometry.contentInsets.bottom
        let old = shared.state
        guard abs(next.offset - old.offset) >= 0.5 || abs(next.height - old.height) >= 0.5
            || abs(next.viewport - old.viewport) >= 0.5 || abs(next.insetTop - old.insetTop) >= 0.5
            || abs(next.insetBottom - old.insetBottom) >= 0.5 else { return }
        shared.state = next
        shared.watchJumps(old, next)
        var changes: [String] = []
        if abs(next.height - old.height) >= 0.5 { changes.append(String(format: "height %+.0f", next.height - old.height)) }
        if abs(next.viewport - old.viewport) >= 0.5 { changes.append(String(format: "viewport %+.0f", next.viewport - old.viewport)) }
        if abs(next.insetTop - old.insetTop) >= 0.5 { changes.append(String(format: "top inset %+.0f", next.insetTop - old.insetTop)) }
        if abs(next.insetBottom - old.insetBottom) >= 0.5 { changes.append(String(format: "inset %+.0f", next.insetBottom - old.insetBottom)) }
        if abs(next.offset - old.offset) >= 0.5 { changes.append(String(format: "offset %+.0f", next.offset - old.offset)) }
        shared.record("geo", changes.joined(separator: " "))
    }

    static func phase(_ old: ScrollPhase, _ new: ScrollPhase) {
        guard isOn else { return }
        shared.state.phase = "\(new)"
        shared.record("phase", "\(old) → \(new)")
    }

    static func bottomVisible(_ visible: Bool) {
        guard isOn, visible != shared.state.bottomVisible else { return }
        shared.state.bottomVisible = visible
        shared.record("end marker", visible ? "visible" : "hidden")
    }

    static func followsBottom(_ follows: Bool) {
        guard isOn, follows != shared.state.followsBottom else { return }
        shared.state.followsBottom = follows
        shared.record("follow", follows ? "on" : "off (↓ shows)")
    }

    static func thread(_ id: String, opened: Bool) {
        guard isOn else { return }
        if opened {
            shared.thread = id
            shared.state = Snapshot()
        }
        shared.record(opened ? "thread open" : "thread close", id)
    }

    private func keyboard(_ label: String, frame: CGRect) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let height = window.map { max(0, $0.bounds.maxY - $0.convert(frame, from: nil).minY) } ?? frame.height
        state.keyboard = label.contains("hide") ? 0 : height
        record("keyboard", String(format: "%@ %.0f pt", label, height))
    }

    func flag() {
        guard Self.isOn else { return }
        flags += 1
        record("FLAG", "#\(flags) " + Self.wallClock(Date()))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ThreadLog.record("flagged #\(flags) (shake or ⚑)")
        saveSoon("flag #\(flags)", always: true)
    }

    /// The thread noticed something wrong with its scrolling: noted, and the minute around it saved.
    static func caught(_ what: @autoclosure () -> String) {
        guard isOn else { return }
        let what = what()
        shared.record("CAUGHT", what)
        shared.saveSoon(what, always: false)
    }

    /// Programmatic movement (not the user's finger) that went one way and straight back.
    @ObservationIgnored private var lastMove: (t: Double, delta: Double)?

    @ObservationIgnored private var lastLayoutChange = -Double.infinity

    private func watchJumps(_ old: Snapshot, _ next: Snapshot) {
        let delta = next.offset - old.offset
        let now = PerfClock.now() - origin
        // Insets and the viewport move the offset too (the keyboard, the composer, the bars), in
        // the same change or in the one right after it.
        if abs(next.height - old.height) >= 0.5 || abs(next.viewport - old.viewport) >= 0.5
            || abs(next.insetTop - old.insetTop) >= 0.5 || abs(next.insetBottom - old.insetBottom) >= 0.5 {
            lastLayoutChange = now
            lastMove = nil
            return
        }
        // Above the top the offset bounces back by itself.
        guard abs(delta) > 40, next.phase != "interacting", next.phase != "decelerating",
              now - lastLayoutChange > 0.15, min(old.offset, next.offset) > -next.insetTop + 1 else { return }
        if let last = lastMove, now - last.t < 1, last.delta.sign != delta.sign {
            Self.caught(String(format: "jumped %+.0f then %+.0f pt", last.delta, delta))
            lastMove = nil
        } else {
            lastMove = (now, delta)
        }
    }

    /// Saves the window around the first flag or catch a few seconds later, so the aftermath is in.
    private func saveSoon(_ reason: String, always: Bool) {
        guard pendingSave == nil else { return }
        let now = PerfClock.now() - origin
        guard always || now - lastAutoSave > Self.catchInterval else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.saveDelay))
            guard let self else { return }
            self.pendingSave = nil
            self.lastAutoSave = PerfClock.now() - self.origin
            self.write(reason: reason, since: now - Self.windowSeconds)
        }
    }

    // MARK: Saving

    /// The HUD's Save: everything kept so far.
    func save() {
        guard !events.isEmpty else { return }
        record("save")
        write(reason: "saved from the HUD", since: -.infinity)
    }

    private func write(reason: String, since: Double) {
        let taken = events.filter { $0.t >= since }
        guard let first = taken.first else { return }
        let stamp = PerfReport.fileStamp(Date())
        let file = File(device: PerfMonitor.deviceSummary, environment: Self.environmentSummary,
                        startedAt: startedAt.addingTimeInterval(first.t), reason: reason, events: taken)
        ThreadLog.record("scroll trace saved: \(reason) → scroll-\(stamp).txt")
        Task.detached(priority: .utility) {
            let directory = PerfMonitor.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = directory.appendingPathComponent("scroll-\(stamp)")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let json = try? encoder.encode(file) { try? json.write(to: base.appendingPathExtension("json")) }
            try? ScrollTraceReport.summary(file).write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            Self.pruneFiles(in: directory)
            await MainActor.run { PerfMonitor.shared.refreshReports() }
        }
    }

    /// Keeps the newest `keepFiles` traces.
    nonisolated private static func pruneFiles(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let traces = files.filter { $0.lastPathComponent.hasPrefix("scroll-") && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in traces.dropFirst(keepFiles) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    struct File: Codable, Sendable {
        var version = 1
        var device: String
        var environment: String
        var startedAt: Date
        /// The flag or catch that saved it.
        var reason: String?
        var events: [Event]
    }

    static var environmentSummary: String {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.keyWindow?.bounds.size ?? .zero
        return String(format: "window %.0f×%.0f", window.width, window.height)
            + " · size class \(scene?.traitCollection.horizontalSizeClass == .regular ? "regular" : "compact")"
            + " · hardware keyboard \(GCKeyboard.coalesced != nil ? "yes" : "no")"
    }

    nonisolated static func wallClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

/// The readable side of a scroll trace: what happened after each send, the moments flagged, and
/// every event, with the user's own dragging folded into one line each.
enum ScrollTraceReport {
    static func summary(_ file: ScrollTrace.File) -> String {
        var out: [String] = []
        let events = file.events
        out.append("Helm thread scroll trace")
        out.append(file.device)
        out.append(file.environment)
        out.append("Started \(file.startedAt.formatted(date: .abbreviated, time: .standard)) (\(ScrollTrace.wallClock(file.startedAt)))")
        if let reason = file.reason { out.append("Saved for: \(reason)") }
        out.append("gap = how far short of the end the view is (negative: past it). fb = follows the bottom, end = end marker visible.")

        let sends = events.indices.filter { events[$0].kind == "send" }
        if !sends.isEmpty {
            out.append("")
            out.append("SENDS (what the view did in the 4 s after each)")
            for index in sends { out.append(contentsOf: sendReport(events, from: index)) }
        }

        let flags = events.indices.filter { events[$0].kind == "FLAG" || events[$0].kind == "CAUGHT" }
        if !flags.isEmpty {
            out.append("")
            out.append("FLAGGED AND CAUGHT MOMENTS (the 6 s before each)")
            for index in flags {
                let flag = events[index]
                out.append("")
                out.append((flag.kind == "FLAG" ? "⚑ " : "✱ caught: ") + "\(flag.detail ?? "") at " + time(flag.t))
                let window = events[..<index].filter { $0.t >= flag.t - 6 }
                out.append(contentsOf: lines(Array(window)).map { "   " + $0 })
            }
        }

        out.append("")
        out.append("ALL EVENTS")
        out.append(contentsOf: lines(events))
        return out.joined(separator: "\n") + "\n"
    }

    private static func time(_ t: Double) -> String { String(format: "+%8.3fs", t) }

    private static func state(_ event: ScrollTrace.Event) -> String {
        let s = event.state
        return String(format: "gap %6.0f  off %6.0f  h %6.0f  view %4.0f  inset %3.0f  kb %3.0f  ", event.gap, s.offset, s.height, s.viewport, s.insetBottom, s.keyboard)
            + "fb \(s.followsBottom ? "✓" : "✗") end \(s.bottomVisible ? "✓" : "✗") \(s.phase)"
    }

    /// Events one per line; geometry while the user drags or flings is folded into a line per stretch.
    private static func lines(_ events: [ScrollTrace.Event]) -> [String] {
        var out: [String] = []
        var folded: (first: ScrollTrace.Event, last: ScrollTrace.Event, count: Int)?
        func flush() {
            guard let run = folded else { return }
            out.append(time(run.first.t) + String(format: "  · user scroll ×%d, offset %.0f → %.0f", run.count, run.first.state.offset, run.last.state.offset)
                + "   | " + state(run.last))
            folded = nil
        }
        for event in events {
            if event.kind == "geo", event.state.phase == "interacting" || event.state.phase == "decelerating" {
                folded = folded.map { ($0.first, event, $0.count + 1) } ?? (event, event, 1)
                continue
            }
            flush()
            let label = event.kind == "geo" ? "  geo" : event.kind == "FLAG" ? "⚑ FLAG" : event.kind == "CAUGHT" ? "✱ CAUGHT" : "▸ " + event.kind
            out.append(time(event.t) + "  " + label + (event.detail.map { " " + $0 } ?? "") + "   | " + state(event))
        }
        flush()
        return out
    }

    /// Where the view was at the send and after it, and whether it ended at the end.
    private static func sendReport(_ events: [ScrollTrace.Event], from index: Int) -> [String] {
        let send = events[index]
        let end = send.t + 4
        let after = events[(index + 1)...].prefix { $0.t <= end && $0.kind != "send" && $0.kind != "thread close" }
        func gap(at t: Double) -> Double? { (after.last { $0.t <= t } ?? send).gap }
        var out = ["", time(send.t) + "  send" + (send.detail.map { " (\($0))" } ?? "")]
        out.append("   at send:  " + state(send))
        let jumps = after.filter { $0.kind == "scrollToBottom" }
        let reasons = Dictionary(grouping: jumps, by: { $0.detail ?? "?" }).map { "\($0.key) ×\($0.value.count)" }.sorted()
        out.append("   jumps to the end: \(jumps.count)" + (reasons.isEmpty ? "" : " — " + reasons.joined(separator: ", ")))
        let checkpoints = [0.25, 0.5, 1, 2, 4].map { offset in
            String(format: "+%.2gs %.0f", offset, gap(at: send.t + offset) ?? 0)
        }
        out.append("   gap over time: " + checkpoints.joined(separator: " · "))
        if let worst = after.max(by: { abs($0.gap) < abs($1.gap) }) {
            out.append(String(format: "   furthest from the end: %.0f pt at +%.2fs", worst.gap, worst.t - send.t))
        }
        // Programmatic movement that went one way and then back: a visible jump.
        let moves = after.filter { $0.kind == "geo" && $0.state.phase != "interacting" && $0.state.phase != "decelerating" }
        var reversals = 0
        var lastDirection = 0.0
        for (a, b) in zip(moves, moves.dropFirst()) {
            let delta = b.state.offset - a.state.offset
            guard abs(delta) > 40 else { continue }
            if lastDirection != 0, delta.sign != lastDirection.sign { reversals += 1 }
            lastDirection = delta
        }
        if reversals > 0 { out.append("   offset reversed direction \(reversals)× (a jump up and back down, or the reverse)") }
        if after.contains(where: { $0.kind == "phase" && ($0.detail?.hasSuffix("interacting") ?? false) }) {
            out.append("   the user touched the conversation in this window")
        }
        let final = after.last ?? send
        let verdict = abs(final.gap) <= 2 && final.state.bottomVisible ? "landed at the end"
            : final.gap > 2 ? String(format: "ended %.0f pt SHORT of the end", final.gap)
            : String(format: "ended %.0f pt PAST the end", -final.gap)
        out.append("   → \(verdict)" + (final.state.followsBottom ? "" : ", not following (↓ showing)"))
        return out
    }
}

/// The trace's own counter over every window: flag an odd moment, save.
struct ScrollTraceHUD: View {
    @State private var trace = ScrollTrace.shared
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var savedFlash = false

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "scroll\n\(trace.eventCount)")
                .font(Typography.mono(9))
                .foregroundStyle(Palette.textMuted)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .padding(.leading, 8)
            Button {
                trace.flag()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.errorText)
                    Text(verbatim: "\(trace.flags)")
                        .font(Typography.mono(9))
                }
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .accessibilityLabel(Text(verbatim: "Flag this moment"))
            Button {
                trace.save()
                savedFlash = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    savedFlash = false
                }
            } label: {
                Image(systemName: savedFlash ? "checkmark" : "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel(Text(verbatim: "Save the scroll trace"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .glassEffect(.regular, in: .capsule)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { offset = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }
                .onEnded { _ in dragStart = offset }
        )
        .padding(.top, 70)
        .padding(.trailing, 12)
    }
}

/// Shaking the device flags the moment in the scroll trace (and saves it), wherever the app is.
extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { MainActor.assumeIsolated { ScrollTrace.shared.flag() } }
        super.motionEnded(motion, with: event)
    }
}
