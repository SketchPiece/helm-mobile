import XCTest
@testable import HelmMobile

/// Talks to a real Helm server. Skipped unless HELM_TEST_URL and HELM_TEST_TOKEN (a bearer) are
/// set, e.g. `TEST_RUNNER_HELM_TEST_URL=http://localhost:13773 TEST_RUNNER_HELM_TEST_TOKEN=… xcodebuild test`.
final class LiveServerTests: XCTestCase {
    private var http: HelmHTTP!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_TEST_URL"].flatMap(URL.init(string:)), let token = env["HELM_TEST_TOKEN"] else {
            throw XCTSkip("No live server configured")
        }
        http = HelmHTTP(baseURL: url, token: token)
    }

    private func connect() async throws -> RPCConnection {
        let ticket = try await http.webSocketTicket()
        let connection = RPCConnection(url: await http.webSocketURL(ticket: ticket))
        await connection.start { _ in }
        return connection
    }

    private func first(_ stream: AsyncThrowingStream<JSON, Error>, where match: (JSON) -> Bool) async throws -> JSON {
        for try await value in stream where match(value) { return value }
        throw RPCError.disconnected
    }

    func testDescriptorAndSession() async throws {
        let descriptor = try await http.descriptor()
        XCTAssertEqual(descriptor.orchestrationProtocolVersion, 2)
        let authenticated = await http.isAuthenticated()
        XCTAssertEqual(authenticated, true)
    }

    func testConfigShellAndThreadSubscriptions() async throws {
        let connection = try await connect()
        let configEvent = try await first(connection.stream("subscribeServerConfig")) { $0["type"]?.string == "snapshot" }
        let config = try XCTUnwrap(configEvent["config"].flatMap(ServerConfig.init(json:)))
        XCTAssertFalse(config.providers.isEmpty)

        var shell = ShellState()
        let shellStream = connection.stream("orchestration.subscribeShell", ["requestCompletionMarker": true])
        for try await item in shellStream {
            shell.apply(item)
            if item["kind"]?.string == "synchronized" || (!config.shellResumeCompletionMarker && shell.sequence > 0) { break }
        }
        XCTAssertGreaterThan(shell.sequence, 0)
        XCTAssertFalse(shell.projects.isEmpty)

        let thread = try XCTUnwrap(shell.threads.values.max { $0.updatedAt ?? .distantPast < $1.updatedAt ?? .distantPast })
        let snapshot = try await first(connection.stream("orchestration.subscribeThread", ["threadId": .string(thread.id)])) {
            $0["kind"]?.string == "snapshot"
        }
        let projection = try XCTUnwrap(snapshot["projection"].flatMap(ThreadProjection.init(json:)))
        XCTAssertEqual(projection.thread.id, thread.id)
        _ = Timeline.blocks(from: projection.rows.map(\.item), liveRunId: projection.activeRun?.id)
        await connection.close()
    }

    func testUnknownMethodFailsCleanlyAndConnectionSurvives() async throws {
        let connection = try await connect()
        do {
            _ = try await connection.call("no.such.method", [:])
            XCTFail("expected a failure")
        } catch let error as RPCError {
            if case .disconnected = error { XCTFail("connection dropped") }
        }
        // Still usable afterwards.
        _ = try await connection.call("server.probe", [:], timeout: .seconds(5))
        await connection.close()
    }

    func testKeepaliveHoldsAnIdleSocket() async throws {
        let connection = try await connect()
        try await Task.sleep(for: .seconds(17))
        let closed = await connection.isClosed
        XCTAssertFalse(closed, "pings should keep the socket open")
        _ = try await connection.call("server.probe", [:], timeout: .seconds(5))
        await connection.close()
    }

    func testUploadAndVoiceTranscribeWireShape() async throws {
        let connection = try await connect()
        let audio = Data(repeating: 0, count: 2048)
        let minted = try await connection.call("attachments.createUploadUrl", [
            "type": "file", "name": "dictation.m4a", "mimeType": "audio/mp4", "sizeBytes": .number(Double(audio.count)),
        ])
        let id = try XCTUnwrap(minted["attachmentId"]?.string)
        var request = URLRequest(url: http.url(try XCTUnwrap(minted["relativeUrl"]?.string)))
        request.httpMethod = "POST"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: audio)
        XCTAssertEqual((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) }, true)

        do {
            let result = try await connection.call("voice.transcribe", ["attachmentId": .string(id), "durationSeconds": 1], timeout: .seconds(60))
            XCTAssertNotNil(result["text"]?.string)
        } catch RPCError.failure(let tag, _) {
            // A server without a transcription key answers with a typed error, which still
            // proves the request decoded.
            XCTAssertEqual(tag, "VoiceTranscribeError")
        }
        await connection.close()
    }

    func testArchivedSnapshotDecodes() async throws {
        let connection = try await connect()
        let snapshot = try await connection.call("orchestration.getArchivedShellSnapshot", [:])
        XCTAssertNotNil(snapshot["threads"]?.array)
        let threads = (snapshot["threads"]?.array ?? []).compactMap(ThreadSummary.init(json:))
        XCTAssertEqual(threads.count, snapshot["threads"]?.array?.count)
        await connection.close()
    }

    // MARK: Arranging, snooze and auto-settle on throwaway Sandbox threads

    /// Keeps a shell subscription applied so tests can wait for the server to reflect a command.
    @MainActor
    private final class ShellWatcher {
        var shell = ShellState()
        private var task: Task<Void, Never>?

        init(_ connection: RPCConnection) {
            let stream = connection.stream("orchestration.subscribeShell", ["requestCompletionMarker": true])
            task = Task { @MainActor [weak self] in
                do { for try await item in stream { self?.shell.apply(item) } } catch {}
            }
        }

        deinit { task?.cancel() }

        func wait(_ what: String, timeout: Double = 30, until done: (ShellState) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(shell) {
                guard Date() < deadline else { throw RPCError.defect("Timed out waiting for \(what)") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func dispatch(_ connection: RPCConnection, _ type: String, _ fields: [String: JSON]) async throws {
        var command = fields
        command["type"] = .string(type)
        command["commandId"] = .string(UUID().uuidString.lowercased())
        _ = try await connection.call("orchestration.dispatchCommand", .object(command))
    }

    /// Launches a thread in the "Sandbox" project and deletes it when the test ends.
    @MainActor
    private func launchSandboxThread(_ connection: RPCConnection, projectId: String) async throws -> String {
        let threadId = UUID().uuidString.lowercased()
        _ = try await connection.call("orchestration.launchThread", [
            "commandId": .string(UUID().uuidString.lowercased()),
            "creationSource": "mobile",
            "threadId": .string(threadId),
            "projectId": .string(projectId),
            "title": "Helm Mobile live test",
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-sonnet-5-5"],
            "runtimeMode": "full-access",
            "interactionMode": "default",
            "workspaceStrategy": ["type": "root"],
            "initialMessage": [
                "messageId": .string(UUID().uuidString.lowercased()), "text": "Reply with OK only.", "attachments": [],
            ],
        ], timeout: .seconds(60))
        addTeardownBlock { [http] in
            guard let http else { return }
            let ticket = try await http.webSocketTicket()
            let cleanup = RPCConnection(url: await http.webSocketURL(ticket: ticket))
            await cleanup.start { _ in }
            _ = try? await cleanup.call("orchestration.dispatchCommand", [
                "type": "thread.delete", "commandId": .string(UUID().uuidString.lowercased()), "threadId": .string(threadId),
            ])
            await cleanup.close()
        }
        return threadId
    }

    @MainActor
    func testArrangingSnoozeAndAutoSettleOnSandboxThreads() async throws {
        let http: HelmHTTP = self.http
        let connection = RPCConnection(url: await http.webSocketURL(ticket: try await http.webSocketTicket()))
        await connection.start { _ in }
        var configJSON: JSON?
        for try await event in connection.stream("subscribeServerConfig") where event["type"]?.string == "snapshot" {
            configJSON = event["config"]
            break
        }
        let config = try XCTUnwrap(configJSON.flatMap(ServerConfig.init(json:)))
        let watcher = ShellWatcher(connection)
        try await watcher.wait("the shell") { $0.isSynchronized }
        guard let sandbox = watcher.shell.projects.values.first(where: { $0.title == "Sandbox" }) else {
            throw XCTSkip("No Sandbox project on this server")
        }

        let first = try await launchSandboxThread(connection, projectId: sandbox.id)
        let second = try await launchSandboxThread(connection, projectId: sandbox.id)
        // Snoozing refuses threads with a queued run; let the one-line turns finish first.
        try await watcher.wait("both turns to finish", timeout: 120) { shell in
            [first, second].allSatisfy { shell.threads[$0].map { !$0.isWorking && $0.latestRunCompletedAt != nil } ?? false }
        }

        // Active arrangement: the second thread goes above the first.
        if config.capability("threadActiveReorder") {
            try await Self.dispatch(connection, "thread.active.reorder", ["threadId": .string(first), "orderKey": "n"])
            let above = try XCTUnwrap(OrderKeys.between(nil, "n"))
            try await Self.dispatch(connection, "thread.active.reorder", ["threadId": .string(second), "orderKey": .string(above)])
            try await watcher.wait("active keys") { shell in
                shell.threads[first]?.activeOrderKey == "n" && shell.threads[second]?.activeOrderKey == above
            }
            let entries = [first, second].compactMap { id in
                watcher.shell.threads[id].map {
                    ThreadListEntry(ref: ThreadRef(environmentId: config.environmentId, threadId: id), thread: $0, project: nil, environmentLabel: "")
                }
            }
            XCTAssertEqual(entries.sortedActive().map(\.ref.threadId), [second, first])
        }

        // Pin at the top of the pinned block, rearrange, unpin.
        if config.capability("threadPinReorder") {
            let top = try XCTUnwrap(OrderKeys.between(nil, watcher.shell.threads.values.compactMap(\.pinOrderKey).min()))
            try await Self.dispatch(connection, "thread.pin", ["threadId": .string(first), "orderKey": .string(top)])
            try await watcher.wait("the pin") { $0.threads[first]?.pinnedAt != nil && $0.threads[first]?.pinOrderKey == top }
            let moved = try XCTUnwrap(OrderKeys.between(top, nil))
            try await Self.dispatch(connection, "thread.pin.reorder", ["threadId": .string(first), "orderKey": .string(moved)])
            try await watcher.wait("the pinned key") { $0.threads[first]?.pinOrderKey == moved }
            // A pinned thread is not part of the active arrangement.
            do {
                try await Self.dispatch(connection, "thread.active.reorder", ["threadId": .string(first), "orderKey": "u"])
                XCTFail("active reorder of a pinned thread should fail")
            } catch RPCError.failure {}
            try await Self.dispatch(connection, "thread.unpin", ["threadId": .string(first)])
            try await watcher.wait("the unpin") { $0.threads[first]?.pinnedAt == nil && $0.threads[first]?.pinOrderKey == nil }
        }

        if config.capability("threadAutoSettleOptOut") {
            try await Self.dispatch(connection, "thread.auto-settle.set", ["threadId": .string(second), "enabled": false])
            try await watcher.wait("auto-settle off") { $0.threads[second]?.autoSettleDisabledAt != nil }
            try await Self.dispatch(connection, "thread.auto-settle.set", ["threadId": .string(second), "enabled": true])
            try await watcher.wait("auto-settle on") { $0.threads[second]?.autoSettleDisabledAt == nil }
        }

        if config.capability("threadSnooze") {
            // A custom wake time, sent the way the date picker's choice is.
            let wake = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 2 * 86_400 + 17 * 60)
            try await Self.dispatch(connection, "thread.snooze", ["threadId": .string(second), "snoozedUntil": .string(ISODate.string(wake))])
            try await watcher.wait("the snooze") { $0.threads[second]?.snoozedUntil == wake }
            XCTAssertTrue(watcher.shell.threads[second]?.isSnoozed() == true)
            do {
                try await Self.dispatch(connection, "thread.snooze", [
                    "threadId": .string(first), "snoozedUntil": .string(ISODate.string(Date().addingTimeInterval(-60))),
                ])
                XCTFail("a wake time in the past should be refused")
            } catch let error as RPCError {
                XCTAssertTrue(error.localizedDescription.contains("not in the future"), error.localizedDescription)
            }
            try await Self.dispatch(connection, "thread.unsnooze", ["threadId": .string(second), "reason": "user"])
            try await watcher.wait("the wake") { $0.threads[second]?.snoozedUntil == nil }
        }

        for id in [first, second] { try await Self.dispatch(connection, "thread.delete", ["threadId": .string(id)]) }
        try await watcher.wait("the cleanup") { $0.threads[first] == nil && $0.threads[second] == nil }
        await connection.close()
    }
}
