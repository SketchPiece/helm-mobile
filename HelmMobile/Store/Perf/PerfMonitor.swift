import MetricKit
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Turns diagnostics on and off, watches frames, feeds the HUD and saves reports.
@MainActor
@Observable
final class PerfMonitor {
    static let shared = PerfMonitor()
    static let enabledKey = "perfDiagnostics"

    // What the HUD shows, refreshed once a second.
    private(set) var fps = 0
    private(set) var hitches = 0
    private(set) var hitchMs = 0.0
    private(set) var stalls = 0
    private(set) var worstStallMs = 0.0
    /// Seconds since the last save.
    private(set) var recordingSeconds = 0
    private(set) var lastSaved: URL?
    private(set) var reports: [URL] = []

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var lastFrameDuration: CFTimeInterval = 1.0 / 60
    @ObservationIgnored private var framesThisSecond = 0
    @ObservationIgnored private var secondStart: CFTimeInterval = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let metrics = MetricKitReceiver()

    private init() {
        MXMetricManager.shared.add(metrics)
        reports = Self.listReports()
    }

    nonisolated static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Performance", isDirectory: true)
    }

    var isEnabled: Bool { link != nil }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled, !AppModel.isUnitTestHost else { return }
        if on {
            PerfRecorder.shared.reset()
            PerfRecorder.shared.isOn.store(true, ordering: .releasing)
            let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
            // As fast as the screen goes, so a late frame is visible as one.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTimestamp = 0
            StallSampler.shared.start()
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { PerfMonitor.shared.pauseWatching(true) }
                },
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { PerfMonitor.shared.pauseWatching(false) }
                },
            ]
            Perf.mark("diagnostics on", Self.deviceSummary)
            // `-perfSaveAfter <seconds>`: a scripted run (a UI test scrolling a thread) saves on its own.
            let saveAfter = UserDefaults.standard.double(forKey: "perfSaveAfter")
            if saveAfter > 0 {
                Task {
                    try? await Task.sleep(for: .seconds(saveAfter))
                    save(note: "perfSaveAfter")
                }
            }
        } else {
            PerfRecorder.shared.isOn.store(false, ordering: .releasing)
            link?.invalidate()
            link = nil
            StallSampler.shared.pause()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            fps = 0
        }
    }

    private func pauseWatching(_ paused: Bool) {
        link?.isPaused = paused
        lastTimestamp = 0
        if paused {
            StallSampler.shared.pause()
            Perf.mark("app inactive")
        } else {
            StallSampler.shared.start()
            Perf.mark("app active")
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        StallSampler.shared.beat()
        let now = link.timestamp
        defer {
            lastTimestamp = now
            lastFrameDuration = link.targetTimestamp - link.timestamp
        }
        guard lastTimestamp > 0 else {
            secondStart = now
            framesThisSecond = 0
            return
        }
        _ = PerfRecorder.shared.frame(at: now, interval: now - lastTimestamp, expected: lastFrameDuration)
        framesThisSecond += 1
        if now - secondStart >= 1 {
            fps = Int((Double(framesThisSecond) / (now - secondStart)).rounded())
            framesThisSecond = 0
            secondStart = now
            refreshTotals()
        }
    }

    private func refreshTotals() {
        let totals = PerfRecorder.shared.state.withLock { state in
            (state.hitches, state.hitchMs, state.stalls.count, state.stalls.map(\.ms).max() ?? 0, state.startedAt)
        }
        hitches = totals.0
        hitchMs = totals.1
        stalls = totals.2
        worstStallMs = totals.3
        recordingSeconds = Int(Date().timeIntervalSince(totals.4))
    }

    // MARK: Reports

    /// Writes everything since the last save (or the last five minutes) and starts afresh.
    func save(note: String? = nil) {
        if let note { Perf.mark("note", note) }
        let state = PerfRecorder.shared.take()
        let device = Self.deviceSummary
        refreshTotals()
        Task.detached(priority: .utility) {
            let url = PerfReport.write(state, device: device)
            await MainActor.run {
                self.lastSaved = url
                self.reports = Self.listReports()
            }
        }
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: Self.directory)
        reports = []
        lastSaved = nil
    }

    func refreshReports() { reports = Self.listReports() }

    nonisolated private static func listReports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static var deviceSummary: String {
        let device = UIDevice.current
        let hertz = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.max() ?? 0
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(machine) · \(device.systemName) \(device.systemVersion) · \(hertz) Hz"
            + " · Helm \(version) (\(build)) · low power \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")"
            + " · thermal \(ProcessInfo.processInfo.thermalState.rawValue)"
    }

    static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Holds the monitor weakly: a display link retains its target.
private final class DisplayLinkTarget: NSObject {
    weak var monitor: PerfMonitor?
    init(_ monitor: PerfMonitor) { self.monitor = monitor }
    @MainActor @objc func tick(_ link: CADisplayLink) { monitor?.tick(link) }
}

/// MetricKit's daily payloads and, more useful here, its hang diagnostics with call stacks.
/// Kept whether or not diagnostics are on; they arrive at most once a day.
private final class MetricKitReceiver: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "metrics") }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { save(payload.jsonRepresentation(), kind: "diagnostics") }
    }

    private func save(_ data: Data, kind: String) {
        let directory = PerfMonitor.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "metrickit-\(kind)-\(PerfReport.fileStamp(Date())).json"
        try? data.write(to: directory.appendingPathComponent(name))
    }
}

extension Perf {
    /// Scrolling started or stopped; hitches while it moves count towards the scroll hitch ratio.
    @MainActor
    static func scroll(_ name: String, _ phase: ScrollPhase) {
        guard isOn else { return }
        PerfRecorder.shared.scroll(name, phase: "\(phase)", active: phase != .idle)
    }
}
