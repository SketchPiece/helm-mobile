import XCTest
@testable import HelmMobile

/// Scheduled tasks, usage and themes against a real server (same switches as LiveServerTests).
/// The scheduled task this makes is disabled and never run: `scheduledTasks.runNow` is not called.
final class LiveSettingsTests: XCTestCase {
    private var http: HelmHTTP!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_TEST_URL"].flatMap(URL.init(string:)), let token = env["HELM_TEST_TOKEN"] else {
            throw XCTSkip("No live server configured")
        }
        http = HelmHTTP(baseURL: url, token: token)
    }

    private func connect() async throws -> RPCConnection {
        let http: HelmHTTP = self.http
        let connection = RPCConnection(url: await http.webSocketURL(ticket: try await http.webSocketTicket()))
        await connection.start { _ in }
        return connection
    }

    /// The sandbox project, matched by path (titles are not unique).
    private func sandboxProject(_ connection: RPCConnection) async throws -> Project {
        var shell = ShellState()
        for try await item in connection.stream("orchestration.subscribeShell", ["requestCompletionMarker": true]) {
            shell.apply(item)
            if item["kind"]?.string == "synchronized" { break }
        }
        guard let project = shell.projects.values.first(where: { $0.workspaceRoot == "/tmp/helm-sandbox" }) else {
            throw XCTSkip("No /tmp/helm-sandbox project on this server")
        }
        return project
    }

    func testScheduledTaskCreateReadUpdateDelete() async throws {
        let connection = try await connect()
        let project = try await sandboxProject(connection)

        // Disabled, so the scheduler never starts it.
        var draft = ScheduledTaskDraft(projectId: project.id, modelSelection: ModelSelection(instanceId: "claudeAgent", model: "claude-sonnet-5-5"))
        draft.title = "Helm Mobile live test (disabled)"
        draft.prompt = "Reply with OK and change nothing."
        draft.enabled = false
        draft.workspace = .root
        draft.timeOfDay = "03:17"
        draft.weekdays = [0]
        let createdJSON = try await connection.call("scheduledTasks.upsert", try draft.upsertPayload(knownProjectIds: [project.id]))
        let created = try XCTUnwrap(createdJSON["task"].flatMap(ScheduledTask.init(json:)))
        var cleanup: String? = created.id
        defer {
            if let id = cleanup {
                let connection = connection
                Task { _ = try? await connection.call("scheduledTasks.delete", ["id": .string(id)]) }
            }
        }
        XCTAssertFalse(created.enabled)
        XCTAssertEqual(created.schedule, .fixedTime(timeOfDay: "03:17", weekdays: [0]))
        XCTAssertEqual(created.workspace, .root(branch: nil))
        XCTAssertEqual(created.creationSource, "mobile")

        // The live list shows it.
        var listed: ScheduledTask?
        for try await value in connection.stream("scheduledTasks.subscribe", [:]) {
            listed = ScheduledTask.list(value).first { $0.id == created.id }
            break
        }
        XCTAssertEqual(listed?.title, draft.title)
        let all = ScheduledTask.list(try await connection.call("scheduledTasks.list", [:]))
        XCTAssertTrue(all.contains { $0.id == created.id })

        // Edit as the form does: an interval schedule and a new worktree, still disabled.
        var edit = ScheduledTaskDraft(editing: created)
        edit.scheduleMode = .interval
        edit.intervalMinutes = "720"
        edit.workspace = .worktree
        edit.baseRef = "main"
        edit.startFromOrigin = false
        let updatedJSON = try await connection.call("scheduledTasks.upsert", try edit.upsertPayload(knownProjectIds: [project.id]))
        let updated = try XCTUnwrap(updatedJSON["task"].flatMap(ScheduledTask.init(json:)))
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.schedule, .interval(everyMs: 720 * 60_000))
        XCTAssertEqual(updated.workspace, .worktree(baseRef: "main", branch: nil, startFromOrigin: false))
        XCTAssertFalse(updated.enabled)

        // setEnabled is a partial update; flip it back immediately.
        _ = try await connection.call("scheduledTasks.setEnabled", ["id": .string(created.id), "enabled": false])

        _ = try await connection.call("scheduledTasks.delete", ["id": .string(created.id)])
        cleanup = nil
        let after = ScheduledTask.list(try await connection.call("scheduledTasks.list", [:]))
        XCTAssertFalse(after.contains { $0.id == created.id })

        // Saving an edit of a deleted task is refused rather than recreating it.
        do {
            _ = try await connection.call("scheduledTasks.upsert", try edit.upsertPayload(knownProjectIds: [project.id]))
            XCTFail("requireExisting should refuse a deleted task")
        } catch let error as RPCError {
            if case .failure(let tag, _) = error { XCTAssertEqual(tag, "ScheduledTaskError") } else { XCTFail("\(error)") }
        }
        await connection.close()
    }

    func testUsageSummaryAndLimitsDecode() async throws {
        let connection = try await connect()
        for days in [1, 7] {
            let json = try await connection.call("server.getUsageSummary", Usage.window(days: days), timeout: .seconds(90))
            let summary = Usage.Summary(json: json)
            XCTAssertTrue(summary.isCompatible, "contract \(summary.contractVersion)")
            XCTAssertEqual(json["buckets"]?.array?.count, summary.buckets.count, "every bucket should decode")
            let totals = Usage.Totals(summary)
            XCTAssertGreaterThanOrEqual(totals.tokens, 0)
            if days == 1 {
                XCTAssertTrue(summary.buckets.allSatisfy { $0.hourStart != nil }, "hourly window should carry hour starts")
            }
        }
        // Limits ride on the provider list.
        let refreshed = try await connection.call("server.refreshProviders", [:], timeout: .seconds(45))
        let providers = (refreshed["providers"]?.array ?? []).compactMap(Provider.init(json:))
        XCTAssertFalse(providers.isEmpty)
        for provider in providers {
            if let raw = refreshed["providers"]?.array?.first(where: { $0["instanceId"]?.string == provider.instanceId })?["usageLimits"],
               raw.object != nil {
                XCTAssertNotNil(provider.usageLimits, provider.instanceId)
                XCTAssertEqual(provider.usageLimits?.windows.count, raw["windows"]?.array?.count)
            }
        }
        await connection.close()
    }

    func testPublishedThemesArriveWhenOptedIn() async throws {
        let connection = try await connect()
        var themes: [HelmTheme]?
        var sawSnapshot = false
        let stream = connection.stream("subscribeServerConfig", ["environmentThemes": true])
        for try await event in stream {
            if event["type"]?.string == "snapshot" { sawSnapshot = true; continue }
            if event["type"]?.string == "environmentThemesUpdated" {
                themes = HelmTheme.published(event["payload"]?["themes"] ?? [], source: "dev")
                break
            }
        }
        XCTAssertTrue(sawSnapshot)
        let list = try XCTUnwrap(themes)
        XCTAssertTrue(list.allSatisfy { $0.id.hasPrefix("published:") && ($0.light != nil || $0.dark != nil) })
        await connection.close()
    }
}
