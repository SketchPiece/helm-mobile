import Foundation

/// Sample threads for screenshots and simulator checks: launch with `-watchDemo`. Actions only
/// pretend; nothing reaches a phone.
enum WatchDemo {
    static var isOn: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-watchDemo")
        #else
        false
        #endif
    }

    /// `-watchDemoOpen t1` opens a sample thread (`new` the new-thread screen) at launch.
    static var initialRoute: WatchRoute? {
        guard isOn, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-watchDemoOpen"),
              index + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        let value = ProcessInfo.processInfo.arguments[index + 1]
        return value == "new" ? .newThread : .thread("\(mac)|\(value)")
    }

    static func snapshotIfRequested() -> WatchSnapshot? { isOn ? snapshot : nil }

    private static let mac = "mac-studio"
    private static let helm = WatchIcon(emoji: "🛞", letters: "HM", color: nil)
    private static let volna = WatchIcon(emoji: nil, letters: "VO", color: "blue")
    private static let site = WatchIcon(emoji: nil, letters: "SI", color: "green")

    private static func thread(_ id: String, _ title: String, _ project: String, _ icon: WatchIcon, _ phase: WatchPhase,
                               _ text: String?, minutes: Double, settled: Bool = false) -> WatchThread {
        WatchThread(environmentId: mac, threadId: id, title: title, projectTitle: project, icon: icon, phase: phase,
                    latestText: text, latestRole: "assistant", lastError: phase == .failed ? "Build failed: 2 errors in RootView.swift" : nil,
                    updatedAt: Date().addingTimeInterval(-minutes * 60), isPinned: false, isSettled: settled, isSnoozed: false)
    }

    static let threads: [WatchThread] = [
        thread("t1", "Apple Watch remote", "helm-mobile", helm, .approval, "Run xcodebuild for the watch target?", minutes: 1),
        thread("t2", "Push relay retries", "Volna", volna, .input, "Which backoff should the relay use?", minutes: 4),
        thread("t3", "Landing page copy", "site", site, .working, "Rewriting the hero section…", minutes: 0.5),
        thread("t4", "Fix iPad sidebar lag", "helm-mobile", helm, .done, "The sidebar no longer rebuilds on every shell update.", minutes: 22),
        thread("t5", "Release notes", "site", site, .failed, nil, minutes: 50),
        thread("t6", "Theme sync", "helm-mobile", helm, .idle, "Merged.", minutes: 300, settled: true),
    ]

    static let snapshot = WatchSnapshot(
        macs: [WatchMac(id: mac, label: "Mac Studio", isLive: true)],
        threads: threads,
        projects: [
            WatchProject(environmentId: mac, projectId: "p1", title: "helm-mobile", icon: helm, macLabel: "Mac Studio"),
            WatchProject(environmentId: mac, projectId: "p2", title: "Volna", icon: volna, macLabel: "Mac Studio"),
            WatchProject(environmentId: mac, projectId: "p3", title: "site", icon: site, macLabel: "Mac Studio"),
        ],
        updatedAt: Date()
    )

    static var details: [String: WatchThreadDetail] {
        var details: [String: WatchThreadDetail] = [:]
        details[threads[0].id] = WatchThreadDetail(
            thread: threads[0],
            messages: [
                WatchMessage(id: "m1", role: .user, text: "Сделай хельм пульт на часы Apple Watch.", date: nil),
                WatchMessage(id: "m2", role: .work, text: "14 steps", date: nil),
                WatchMessage(id: "m3", role: .assistant, text: "The watch app talks to Helm through the iPhone. Next I'll **build it** for the simulator.", date: nil),
            ],
            requests: [WatchRequest(
                id: "r1", kind: .approval, canRespond: true, title: "Run this command?",
                detail: "xcodebuild -scheme HelmWatch -destination 'platform=watchOS Simulator'",
                options: [
                    .init(decision: "accept", label: "Allow once", isWarning: false),
                    .init(decision: "acceptForSession", label: "Allow for session", isWarning: false),
                    .init(decision: "decline", label: "Decline", isWarning: false),
                ],
                questions: [], dismissible: false
            )],
            isWorking: true, queuedCount: 0, isStale: false
        )
        details[threads[1].id] = WatchThreadDetail(
            thread: threads[1],
            messages: [WatchMessage(id: "m4", role: .assistant, text: "I found two places that retry pushes.", date: nil)],
            requests: [WatchRequest(
                id: "r2", kind: .questions, canRespond: true, title: nil, detail: nil, options: [],
                questions: [.init(id: "q1", header: "Backoff", question: "Which backoff should the relay use?", options: [
                    .init(label: "Exponential", detail: "1s, 2s, 4s… up to a minute", answer: "Exponential"),
                    .init(label: "Fixed 5s", detail: nil, answer: "Fixed 5s"),
                ], multiSelect: false, allowCustomAnswer: true)],
                dismissible: false
            )],
            isWorking: true, queuedCount: 1, isStale: false
        )
        details[threads[2].id] = WatchThreadDetail(
            thread: threads[2],
            messages: [
                WatchMessage(id: "m5", role: .user, text: "Rewrite the hero, shorter.", date: nil),
                WatchMessage(id: "m6", role: .work, text: "Working…", date: nil),
            ],
            requests: [], isWorking: true, queuedCount: 0, isStale: false
        )
        return details
    }
}
