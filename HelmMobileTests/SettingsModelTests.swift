import XCTest
@testable import HelmMobile

/// Scheduled-task drafts and payloads, usage totals and windows, published themes, and the
/// Usage widget's snapshot.
final class SettingsModelTests: XCTestCase {
    // MARK: Scheduled tasks

    private let taskJSON: JSON = [
        "id": "task-1", "title": "Nightly check", "prompt": "Look for issues", "enabled": true,
        "schedule": ["type": "fixed_time", "timeOfDay": "07:30", "weekdays": [1, 3, 5]],
        "projectId": "p1", "threadId": nil,
        "workspaceStrategy": ["type": "worktree", "baseRef": "develop", "startFromOrigin": false],
        "modelSelection": ["instanceId": "claudeAgent", "model": "claude-sonnet-5-5", "options": [["id": "effort", "value": "high"]]],
        "runtimeMode": "auto", "interactionMode": "plan", "createdBy": "user", "creationSource": "web",
        "createdAt": "2026-10-01T10:00:00.000Z", "updatedAt": "2026-10-01T10:00:00.000Z",
        "nextRunAt": "2026-10-05T05:30:00.000Z", "lastRunAt": nil, "lastRunStatus": "never", "lastRunError": nil, "runCount": 0,
    ]

    func testDecodesATaskAndEditsItWithoutLosingFields() throws {
        let task = try XCTUnwrap(ScheduledTask(json: taskJSON))
        XCTAssertEqual(task.schedule, .fixedTime(timeOfDay: "07:30", weekdays: [1, 3, 5]))
        XCTAssertEqual(task.workspace, .worktree(baseRef: "develop", branch: nil, startFromOrigin: false))
        XCTAssertNotNil(task.nextRunAt)

        let draft = ScheduledTaskDraft(editing: task)
        XCTAssertEqual(draft.weekdays, [1, 3, 5])
        XCTAssertEqual(draft.baseRef, "develop")
        XCTAssertFalse(draft.startFromOrigin)
        let payload = try draft.upsertPayload(knownProjectIds: ["p1"])
        XCTAssertEqual(payload["id"], "task-1")
        XCTAssertEqual(payload["requireExisting"], true)
        XCTAssertEqual(payload["threadId"], .null)
        XCTAssertEqual(payload["creationSource"], "web")
        XCTAssertEqual(payload["interactionMode"], "plan")
        XCTAssertEqual(payload["runtimeMode"], "auto")
        XCTAssertEqual(payload["schedule"], ["type": "fixed_time", "timeOfDay": "07:30", "weekdays": [1, 3, 5]])
        XCTAssertEqual(payload["workspaceStrategy"], ["type": "worktree", "baseRef": "develop", "startFromOrigin": false])
        XCTAssertEqual(payload["modelSelection"]?["options"], [["id": "effort", "value": "high"]])
    }

    func testNewDraftDefaultsAndValidation() throws {
        var draft = ScheduledTaskDraft(projectId: "p1", modelSelection: ModelSelection(instanceId: "codex", model: "gpt-6"))
        XCTAssertThrowsError(try draft.upsertPayload(knownProjectIds: ["p1"])) { XCTAssertEqual($0 as? ScheduledTaskDraft.Problem, .incomplete) }
        draft.title = "  Morning digest "
        draft.prompt = "Summarise yesterday"
        let payload = try draft.upsertPayload(knownProjectIds: ["p1"])
        XCTAssertNil(payload["id"])
        XCTAssertEqual(payload["title"], "Morning digest")
        XCTAssertEqual(payload["creationSource"], "mobile")
        XCTAssertEqual(payload["schedule"], ["type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 2, 3, 4, 5]])
        XCTAssertEqual(payload["workspaceStrategy"], ["type": "worktree", "baseRef": "main", "startFromOrigin": true])
        XCTAssertThrowsError(try draft.upsertPayload(knownProjectIds: ["other"])) {
            XCTAssertEqual($0 as? ScheduledTaskDraft.Problem, .projectUnavailable)
        }

        draft.weekdays = Set(0...6)
        XCTAssertEqual(draft.schedule, .fixedTime(timeOfDay: "09:00", weekdays: nil))
        draft.weekdays = []
        XCTAssertNil(draft.schedule)
        draft.scheduleMode = .interval
        draft.intervalMinutes = "0.5"
        XCTAssertNil(draft.schedule)
        draft.intervalMinutes = "1,5"
        XCTAssertEqual(draft.schedule, .interval(everyMs: 90_000))
        draft.workspace = .existingWorktree
        XCTAssertThrowsError(try draft.upsertPayload(knownProjectIds: ["p1"]))
        draft.checkoutPath = "/tmp/checkout"
        XCTAssertEqual(try draft.upsertPayload(knownProjectIds: ["p1"])["workspaceStrategy"],
                       ["type": "existing_worktree", "worktreePath": "/tmp/checkout"])
    }

    func testIntervalTasksRoundTripAsMinutes() throws {
        var json = taskJSON
        if case .object(var object) = json {
            object["schedule"] = ["type": "interval", "everyMs": 5_400_000]
            json = .object(object)
        }
        let draft = ScheduledTaskDraft(editing: try XCTUnwrap(ScheduledTask(json: json)))
        XCTAssertEqual(draft.scheduleMode, .interval)
        XCTAssertEqual(draft.intervalMinutes, "90")
        XCTAssertEqual(draft.schedule, .interval(everyMs: 5_400_000))
    }

    func testScheduleText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        XCTAssertEqual(ScheduledTaskText.repeatLabel([1, 2, 3, 4, 5], calendar: calendar), "Weekdays")
        XCTAssertEqual(ScheduledTaskText.repeatLabel(Set(0...6), calendar: calendar), "Every day")
        XCTAssertEqual(ScheduledTaskText.repeatLabel([0, 1], calendar: calendar), "Mon, Sun")
        XCTAssertEqual(ScheduledTaskText.interval(3_600_000), "Every hour")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 10))!
        XCTAssertEqual(ScheduledTaskText.nextRun(now.addingTimeInterval(-1), now: now, calendar: calendar), "Next run due")
        XCTAssertEqual(ScheduledTaskText.nextRun(now.addingTimeInterval(30), now: now, calendar: calendar), "Next run in less than a minute")
        XCTAssertEqual(ScheduledTaskText.nextRun(now.addingTimeInterval(25 * 60), now: now, calendar: calendar), "Next run in 25 minutes")
        XCTAssertEqual(ScheduledTaskText.nextRun(now.addingTimeInterval(86_400 - 3600), now: now, calendar: calendar), "Next run tomorrow at 9:00")
    }

    // MARK: Usage

    private func bucket(_ day: String, _ provider: String, _ model: String, cost: Double, input: Int, output: Int,
                        records: Int = 10, unpriced: Int = 0, hour: String? = nil) -> JSON {
        var object: [String: JSON] = [
            "day": .string(day), "provider": .string(provider), "model": .string(model),
            "totals": ["uncachedInputTokens": .number(Double(input)), "cachedInputTokens": 500, "cacheCreationTokens": 100,
                       "outputTokens": .number(Double(output)), "reasoningTokens": 50],
            "costUsd": .number(cost), "cacheSavingsUsd": 0.5,
            "categoryCostUsd": ["input": .number(cost / 2), "cacheRead": 0, "cacheWrite": 0, "output": .number(cost / 4)],
            "costSource": "modelPriced", "records": .number(Double(records)), "unpricedRecords": .number(Double(unpriced)), "sessions": 2,
        ]
        if let hour { object["hourStart"] = .string(hour) }
        return .object(object)
    }

    func testUsageTotals() {
        let summary = Usage.Summary(json: [
            "contractVersion": 6, "readAt": "x", "timeZone": "Europe/Berlin", "sinceDay": "2026-10-01", "untilDay": "2026-10-02",
            "buckets": [
                bucket("2026-10-01", "claude", "claude-opus-5-5", cost: 4, input: 1000, output: 400),
                bucket("2026-10-02", "claude", "claude-opus-5-5", cost: 2, input: 1000, output: 400),
                bucket("2026-10-02", "codex", "gpt-6", cost: 0, input: 400, output: 0, records: 4, unpriced: 4),
                ["day": "bad"],
            ],
            "sources": [
                ["fingerprint": ["hostId": "h", "provider": "claude", "resolvedHomePath": "/c", "volumeId": ""], "status": "ok",
                 "scannedFiles": 1, "skippedFiles": 0, "malformedRecords": 0, "distinctSessions": 3, "message": nil],
                ["fingerprint": ["hostId": "h", "provider": "codex", "resolvedHomePath": "/x", "volumeId": ""], "status": "partial",
                 "scannedFiles": 1, "skippedFiles": 1, "malformedRecords": 0, "distinctSessions": 1, "message": "Some files skipped"],
            ],
            "pricing": ["status": "fresh", "source": "litellm", "fetchedAt": nil, "knownModels": 1], "scanDurationMs": 5,
        ])
        XCTAssertTrue(summary.isCompatible)
        XCTAssertEqual(summary.buckets.count, 3)
        XCTAssertEqual(summary.sourceMessages, ["Some files skipped"])
        let totals = Usage.Totals(summary)
        XCTAssertEqual(totals.costUsd, 6)
        // Input + cached + cache writes + output; reasoning is inside output.
        XCTAssertEqual(totals.tokens, 1000 + 500 + 100 + 400 + 1000 + 500 + 100 + 400 + 400 + 500 + 100)
        XCTAssertEqual(totals.sessions, 4)
        XCTAssertEqual(totals.providers.first?.provider, "claude")
        XCTAssertEqual(totals.providers.first?.costShare, 1)
        XCTAssertEqual(totals.daily.map(\.key), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(totals.cost.input, 3)
        XCTAssertEqual(totals.cost.unsplit, 6 - 3 - 1.5, accuracy: 1e-9)
        XCTAssertEqual(totals.unpricedShare, 4.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(totals.models.count, 2)
        XCTAssertTrue(totals.models.last?.costUnknown ?? false)
    }

    func testUsageWindows() {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 0, minute: 30, second: 20))!
        let month = Usage.window(days: 30, now: now, timeZone: zone)
        XCTAssertEqual(month["sinceDay"], "2026-09-05")
        XCTAssertEqual(month["untilDay"], "2026-10-04")
        XCTAssertEqual(month["timeZone"], "Europe/Berlin")
        XCTAssertEqual(month["resolution"], "day")
        let day = Usage.window(days: 1, now: now, timeZone: zone)
        XCTAssertEqual(day["resolution"], "hour")
        XCTAssertEqual(day["sinceDay"], "2026-10-03")
        XCTAssertEqual(day["untilTime"], "2026-10-03T22:30:00.000Z")
        XCTAssertEqual(day["sinceTime"], "2026-10-02T22:30:00.000Z")
    }

    func testFormatting() {
        XCTAssertEqual(Usage.formatTokens(19_940_000_000), "19.9B")
        XCTAssertEqual(Usage.formatTokens(76_700_000), "76.7M")
        XCTAssertEqual(Usage.formatTokens(804_000), "804K")
        XCTAssertEqual(Usage.formatTokens(1_200), "1.2K")
        XCTAssertEqual(Usage.formatTokens(2_000_000), "2M")
        XCTAssertEqual(Usage.formatPercent(0.0004), "<0.1%")
        XCTAssertEqual(Usage.formatPercent(0.256), "25.6%")
    }

    func testWidgetSnapshotPicksTightestWindowsAndResets() throws {
        let codex = try XCTUnwrap(Provider(json: [
            "instanceId": "codex", "driver": "codex", "displayName": "Codex", "enabled": true, "installed": true, "status": "ready",
            "usageLimits": ["checkedAt": "2026-10-04T10:00:00.000Z", "windows": [
                ["id": "weekly", "kind": "weekly", "label": "Weekly", "usedPercent": 20],
                ["id": "primary", "kind": "session", "label": "5-hour", "usedPercent": 70, "resetsAt": "2026-10-04T12:00:00.000Z"],
            ]],
        ]))
        let unsupported = try XCTUnwrap(Provider(json: [
            "instanceId": "grok", "driver": "grok", "enabled": true, "installed": true,
            "usageLimits": ["checkedAt": "2026-10-04T10:00:00.000Z", "windows": [], "unavailable": ["reason": "unsupported"]],
        ]))
        let now = ISODate.parse("2026-10-04T10:05:00.000Z")!
        let snapshot = UsageWidgetPublisher.snapshot(macs: [("MacBook", [unsupported, codex]), ("Studio", [codex])],
                                                     dayTotals: (12.5, 1000), now: now)
        XCTAssertEqual(snapshot.providers.map(\.driver), ["codex"])
        XCTAssertEqual(snapshot.providers.first?.windows.map(\.remainingPercent), [30, 80])
        XCTAssertNil(snapshot.macLabel)
        XCTAssertEqual(snapshot.costUsd, 12.5)
        XCTAssertEqual(snapshot.timelineDates(from: now), [now, ISODate.parse("2026-10-04T12:00:00.000Z")!])
        let later = snapshot.at(ISODate.parse("2026-10-04T12:00:01.000Z")!)
        XCTAssertEqual(later.providers.first?.windows.first?.remainingPercent, 100)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "helm-tests-\(UUID().uuidString)"))
        snapshot.save(to: defaults)
        XCTAssertEqual(UsageSnapshot.load(from: defaults), snapshot)
    }

    // MARK: Themes

    func testCSSColours() throws {
        XCTAssertEqual(RGBA(css: "#e8a33d"), RGBA(hex: 0xE8A33D))
        XCTAssertEqual(RGBA(css: "#fff"), RGBA(hex: 0xFFFFFF))
        XCTAssertEqual(try XCTUnwrap(RGBA(css: "#00000080")).a, 128.0 / 255, accuracy: 1e-6)
        XCTAssertEqual(RGBA(css: "rgb(255, 0, 0)"), RGBA(r: 1, g: 0, b: 0))
        XCTAssertEqual(try XCTUnwrap(RGBA(css: "rgba(0 0 255 / 50%)")).a, 0.5, accuracy: 1e-9)
        let white = try XCTUnwrap(RGBA(css: "oklch(1 0 0)"))
        XCTAssertEqual(white.r, 1, accuracy: 0.002)
        XCTAssertEqual(white.b, 1, accuracy: 0.002)
        // oklch(62.8% 0.2577 29.23) is CSS red.
        let red = try XCTUnwrap(RGBA(css: "oklch(62.8% 0.2577 29.23)"))
        XCTAssertEqual(red.r, 1, accuracy: 0.01)
        XCTAssertEqual(red.g, 0, accuracy: 0.01)
        XCTAssertEqual(red.b, 0, accuracy: 0.01)
        XCTAssertNil(RGBA(css: "papayawhip"))
        XCTAssertNil(RGBA(css: "#12345"))
    }

    func testPublishedThemes() throws {
        let themes = HelmTheme.published([
            ["id": "graphite", "name": "Graphite", "appearance": "dark",
             "colors": ["canvas": "#262624", "messageSurface": "#141413", "focus": "#d97757", "notARole": "#000", "accent": "nonsense"]],
            ["id": "duo", "name": "Duo", "appearance": "dark", "colors": ["canvas": "#000000"],
             "variants": ["light": ["canvas": "#ffffff"]]],
            ["id": "seeded", "name": "Seeded", "appearance": "light", "canvas": "#ffffff", "accent": "#ff0000"],
            ["id": "dark", "name": "Reserved", "appearance": "dark", "colors": ["canvas": "#000000"]],
        ], source: "MacBook")
        XCTAssertEqual(themes.map(\.id), ["published:graphite", "published:duo"])
        let graphite = themes[0]
        XCTAssertNil(graphite.light)
        XCTAssertEqual(graphite.dark?[.canvas], RGBA(hex: 0x262624))
        XCTAssertEqual(graphite.dark?[.message], RGBA(hex: 0x141413))
        XCTAssertEqual(graphite.dark?[.accentText], RGBA(hex: 0xD97757))
        XCTAssertNil(graphite.dark?[.accent])
        // Roles and appearances a theme leaves out stay Bakelite.
        XCTAssertEqual(graphite.color(.accent, dark: true), HelmTheme.bakeliteDark[.accent])
        XCTAssertEqual(graphite.color(.canvas, dark: false), HelmTheme.bakeliteLight[.canvas])
        XCTAssertEqual(themes[1].light?[.canvas], RGBA(hex: 0xFFFFFF))
        XCTAssertEqual(graphite.source, "MacBook")
    }

    func testThemeStorePersistsAndFollowsRepublishedThemes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "helm-tests-\(UUID().uuidString)"))
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme.id, HelmTheme.bakeliteId)
        var theme = HelmTheme(id: "published:x", name: "X", source: "Mac", light: nil, dark: [.canvas: RGBA(hex: 0x111111)])
        store.apply(theme)
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, theme)
        theme.dark?[.canvas] = RGBA(hex: 0x222222)
        store.update(from: [theme])
        XCTAssertEqual(store.theme.dark?[.canvas], RGBA(hex: 0x222222))
    }
}


@MainActor
final class ScreenUnlockTests: XCTestCase {
    private func makeRemote() -> ScreenRemote {
        ScreenRemote(environment: EnvironmentSession(saved: SavedEnvironment(
            id: "unlock-test", label: "Mac", baseURL: URL(string: "http://mac")!, pairedAt: Date())))
    }

    func testOlderHelperHasNoUnlockCapability() {
        let remote = makeRemote()
        remote.handleText(#"{"t":"info","width":100,"height":100}"#)
        XCTAssertEqual(remote.phase, .live)
        XCTAssertNil(remote.isLocked)
        XCTAssertFalse(remote.unlockEnabled)
    }

    func testSubmissionIsNotProofOfUnlocking() {
        let remote = makeRemote()
        remote.handleText(#"{"t":"lockState","locked":true,"available":true,"unlockEnabled":true}"#)
        remote.handleText(#"{"t":"unlockResult","status":"submitted"}"#)
        XCTAssertEqual(remote.isLocked, true)
        remote.handleText(#"{"t":"lockState","locked":false,"available":true,"unlockEnabled":true}"#)
        XCTAssertEqual(remote.isLocked, false)
        XCTAssertNil(remote.unlockMessage)
    }

    func testLockStateNamesTheUserUntilDisconnect() {
        let remote = makeRemote()
        remote.handleText(#"{"t":"lockState","locked":true,"available":true,"unlockEnabled":true,"user":"Andrew Liubkin"}"#)
        XCTAssertEqual(remote.lockUser, "Andrew Liubkin")
        remote.disconnect()
        XCTAssertNil(remote.lockUser)
    }

    func testRevocationAndDisconnectClearCapability() {
        let remote = makeRemote()
        remote.handleText(#"{"t":"lockState","locked":true,"available":true,"unlockEnabled":true}"#)
        XCTAssertTrue(remote.unlockEnabled)
        remote.handleText(#"{"t":"lockState","locked":true,"available":true,"unlockEnabled":false}"#)
        XCTAssertFalse(remote.unlockEnabled)
        remote.handleText(#"{"t":"unlockResult","status":"disabled"}"#)
        XCTAssertNotNil(remote.unlockMessage)
        remote.disconnect()
        XCTAssertNil(remote.isLocked)
        XCTAssertNil(remote.unlockMessage)
        XCTAssertFalse(remote.unlockEnabled)
    }

    func testFailureKeepsTheMacLockedAndUnknownStateDoesNotEnableUnlock() {
        let remote = makeRemote()
        remote.handleText(#"{"t":"lockState","locked":true,"available":true,"unlockEnabled":true}"#)
        remote.handleText(#"{"t":"unlockResult","status":"stillLocked"}"#)
        XCTAssertEqual(remote.isLocked, true)
        XCTAssertNotNil(remote.unlockMessage)
        remote.handleText(#"{"t":"lockState","locked":true,"available":false,"unlockEnabled":true}"#)
        XCTAssertFalse(remote.lockStateAvailable)
    }

    func testPasswordRequiresLiveConnectionAndValidInput() async {
        let remote = makeRemote()
        remote.handleText(#"{"t":"lockState","locked":true,"available":true,"unlockEnabled":true}"#)
        await remote.unlock(password: "example")
        XCTAssertFalse(remote.unlockInProgress)
        XCTAssertNotNil(remote.unlockMessage)
        await remote.unlock(password: "a\nb")
        XCTAssertFalse(remote.unlockInProgress)
    }
}
