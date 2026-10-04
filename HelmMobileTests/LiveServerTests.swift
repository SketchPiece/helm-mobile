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

    private func shell(_ connection: RPCConnection) async throws -> ShellState {
        var shell = ShellState()
        for try await item in connection.stream("orchestration.subscribeShell", ["requestCompletionMarker": true]) {
            shell.apply(item)
            if item["kind"]?.string == "synchronized" { break }
        }
        return shell
    }

    /// The scratch project the live tests may run agents in.
    private func sandbox(_ connection: RPCConnection) async throws -> Project {
        let projects = try await shell(connection).projects.values
        guard let project = projects.first(where: { ["/tmp/helm-sandbox", "/private/tmp/helm-sandbox"].contains($0.workspaceRoot) }) else {
            throw XCTSkip("No Sandbox project (/tmp/helm-sandbox) on the dev server")
        }
        return project
    }

    private func uploadFile(_ connection: RPCConnection, _ data: Data, name: String, mimeType: String) async throws -> ChatAttachment {
        let minted = try await connection.call("attachments.createUploadUrl", [
            "type": "file", "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .number(Double(data.count)),
        ])
        let id = try XCTUnwrap(minted["attachmentId"]?.string)
        var request = URLRequest(url: http.url(try XCTUnwrap(minted["relativeUrl"]?.string)))
        request.httpMethod = "POST"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        XCTAssertEqual((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) }, true)
        return ChatAttachment(id: id, type: "file", name: name, mimeType: mimeType, sizeBytes: data.count)
    }

    func testPathSearchForTheAtMenu() async throws {
        let connection = try await connect()
        let project = try await sandbox(connection)
        let result = try await connection.call("projects.searchEntries", [
            "cwd": .string(project.workspaceRoot), "query": "gree", "limit": 20,
        ])
        let paths = (result["entries"]?.array ?? []).compactMap { $0["path"]?.string }
        XCTAssertTrue(paths.contains("greet.ts"), "\(paths)")
        XCTAssertNotNil(result["truncated"]?.bool)
        await connection.close()
    }

    /// The `/` and `$` menus ask for a workspace's own commands and skills once per cwd.
    func testWorkspaceSnapshotRefreshDecodes() async throws {
        let connection = try await connect()
        let project = try await sandbox(connection)
        let result = try await connection.call("server.refreshProviders", [
            "instanceId": "claudeAgent", "cwd": .string(project.workspaceRoot),
        ], timeout: .seconds(60))
        let claude = try XCTUnwrap((result["providers"]?.array ?? []).compactMap(Provider.init(json:))
            .first { $0.instanceId == "claudeAgent" })
        XCTAssertTrue(claude.hasSnapshot(cwd: project.workspaceRoot))
        XCTAssertFalse(claude.slashCommands(cwd: project.workspaceRoot).isEmpty)
        await connection.close()
    }

    /// A new thread whose first message carries a pasted-text file, then a queued follow-up with
    /// a plain file, both as inline `t3-context://` links plus records, exactly as the composer builds them.
    func testFileAttachmentsTravelWithContextRecords() async throws {
        let connection = try await connect()
        let configEvent = try await first(connection.stream("subscribeServerConfig")) { $0["type"]?.string == "snapshot" }
        let config = try XCTUnwrap(configEvent["config"].flatMap(ServerConfig.init(json:)))
        XCTAssertNotNil(config.maxFileBytes, "server should take files")
        XCTAssertTrue(config.inlineMessageContext)
        let project = try await sandbox(connection)

        var pasted = try await uploadFile(connection, Data("Ignore this file.\n".utf8), name: "pasted-text.txt",
                                          mimeType: PastedText.mimeType)
        pasted.source = "pasted-text"
        let opening = ComposerMessage.build(text: "Reply with OK only.", attachments: [("ctx-paste-1", pasted)],
                                            pullRequests: [], inlineContext: true)
        let threadId = UUID().uuidString.lowercased()
        let openingId = UUID().uuidString.lowercased()
        _ = try await connection.call("orchestration.launchThread", [
            "commandId": .string(UUID().uuidString.lowercased()), "creationSource": "mobile", "threadId": .string(threadId),
            "projectId": .string(project.id), "title": "Composer live test",
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-sonnet-5-5"],
            "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": ["type": "root"],
            "initialMessage": [
                "messageId": .string(openingId), "text": .string(opening.text),
                "attachments": .array(opening.attachments.map(\.json)), "context": try XCTUnwrap(opening.context),
            ],
        ], timeout: .seconds(60))

        let log = try await uploadFile(connection, Data("line 1\nline 2\n".utf8), name: "build.log", mimeType: "text/plain")
        let followUp = ComposerMessage.build(text: "Reply with OK only.", attachments: [("ctx-log-1", log)],
                                             pullRequests: [], inlineContext: true)
        let followUpId = UUID().uuidString.lowercased()
        _ = try await connection.call("orchestration.dispatchCommand", [
            "type": "message.dispatch", "commandId": .string(UUID().uuidString.lowercased()), "createdBy": "user",
            "creationSource": "mobile", "threadId": .string(threadId), "messageId": .string(followUpId),
            "text": .string(followUp.text), "attachments": .array(followUp.attachments.map(\.json)),
            "context": try XCTUnwrap(followUp.context), "dispatchMode": ["type": "queue_after_active"],
        ])

        let snapshot = try await first(connection.stream("orchestration.subscribeThread", ["threadId": .string(threadId)])) {
            $0["kind"]?.string == "snapshot"
        }
        let projection = try XCTUnwrap(snapshot["projection"].flatMap(ThreadProjection.init(json:)))
        for (id, message, name) in [(openingId, opening, "pasted-text.txt"), (followUpId, followUp, "build.log")] {
            let stored = try XCTUnwrap(projection.messages[id], "message with \(name) missing")
            XCTAssertEqual(stored["text"]?.string, message.text)
            let attachment = try XCTUnwrap((stored["attachments"]?[0]).flatMap(ChatAttachment.init(json:)))
            XCTAssertEqual(attachment.name, name)
            XCTAssertEqual(attachment.type, "file")
            let record = stored["context"]?["records"]?[0]
            XCTAssertEqual(record?["kind"], "file")
            XCTAssertEqual(record?["attachmentId"]?.string, attachment.id)
        }
        XCTAssertEqual(projection.messages[openingId]?["attachments"]?[0]?["source"]?["_tag"], "pasted-text")

        // Leave the sandbox tidy: the turns are cheap and their result doesn't matter.
        _ = try? await connection.call("orchestration.dispatchCommand", [
            "type": "thread.delete", "commandId": .string(UUID().uuidString.lowercased()), "threadId": .string(threadId),
        ])
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

    // MARK: Projects and branches

    private func serverConfig(_ connection: RPCConnection) async throws -> ServerConfig {
        let event = try await first(connection.stream("subscribeServerConfig")) { $0["type"]?.string == "snapshot" }
        return try XCTUnwrap(event["config"].flatMap(ServerConfig.init(json:)))
    }

    func testBrowseHomeAndTmp() async throws {
        let connection = try await connect()
        let home = FolderListing(json: try await connection.call("filesystem.browse", FolderListing.request(directory: "~")))
        XCTAssertTrue(home.path.hasPrefix("/"), "the listed directory comes back absolute: \(home.path)")
        XCTAssertFalse(home.entries.isEmpty)
        XCTAssertEqual(FolderPath.breadcrumbs(home.path).first?.name, "~")

        let tmp = FolderListing(json: try await connection.call("filesystem.browse", FolderListing.request(directory: "/tmp")))
        XCTAssertTrue(tmp.entries.contains { $0.name == "helm-sandbox" }, "\(tmp.entries.map(\.name))")
        await connection.close()
    }

    func testListRefsWithQueryAndPaging() async throws {
        let connection = try await connect()
        let all = RefPage(json: try await connection.call("vcs.listRefs", RefPage.request(cwd: "/tmp/helm-sandbox")))
        XCTAssertTrue(all.isRepo)
        XCTAssertNotNil(all.defaultBase)
        let matching = RefPage(json: try await connection.call("vcs.listRefs", RefPage.request(cwd: "/tmp/helm-sandbox", query: "mai")))
        XCTAssertTrue(matching.refs.contains { $0.name == "main" }, "\(matching.refs.map(\.name))")
        let none = RefPage(json: try await connection.call("vcs.listRefs", RefPage.request(cwd: "/tmp/helm-sandbox", query: "no-such-branch-zz")))
        XCTAssertTrue(none.refs.filter { !$0.isRemote }.isEmpty)
        XCTAssertNil(none.nextCursor)
        await connection.close()
    }

    func testEnsureScratchProject() async throws {
        let connection = try await connect()
        let config = try await serverConfig(connection)
        guard let root = config.scratchWorkspaceRoot else {
            // Servers whose data dir sits inside a git checkout (dev servers) offer no Scratch;
            // the call then fails with a typed error, which still proves the request decoded.
            do {
                _ = try await connection.call("projects.ensureScratch", [:])
                XCTFail("expected ensureScratch to fail without a scratch root")
            } catch RPCError.failure(let tag, _) {
                XCTAssertEqual(tag, "OrchestrationDispatchCommandError")
            }
            await connection.close()
            return
        }
        let first = try await connection.call("projects.ensureScratch", [:])
        let id = try XCTUnwrap(first["projectId"]?.string)
        // Idempotent: the same scratch project every time.
        let again = try await connection.call("projects.ensureScratch", [:])
        XCTAssertEqual(again["projectId"]?.string, id)

        var shell = ShellState()
        for try await item in connection.stream("orchestration.subscribeShell", ["requestCompletionMarker": true]) {
            shell.apply(item)
            if item["kind"]?.string == "synchronized" || (!config.shellResumeCompletionMarker && shell.sequence > 0) { break }
        }
        let project = try XCTUnwrap(shell.projects[id])
        XCTAssertTrue(config.isScratch(project), "\(project.workspaceRoot) vs \(root)")
        await connection.close()
    }

    func testCreateAndDeleteFolderProject() async throws {
        let connection = try await connect()
        let path = "/tmp/helm-mobile-test-project-\(UUID().uuidString.lowercased().prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let projectId = UUID().uuidString.lowercased()
        let created = try await connection.call("projects.mutate", ProjectCommands.create(projectId: projectId, path: path))
        XCTAssertEqual(created["id"]?.string, projectId)
        XCTAssertEqual(created["title"]?.string, FolderPath.lastSegment(path))
        XCTAssertTrue(created["workspaceRoot"]?.string?.hasSuffix(FolderPath.lastSegment(path)) == true)

        let listing = FolderListing(json: try await connection.call("filesystem.browse", FolderListing.request(directory: "/tmp")))
        XCTAssertTrue(listing.entries.contains { $0.name == FolderPath.lastSegment(path) }, "createWorkspaceRootIfMissing made the folder")

        _ = try await connection.call("projects.mutate", ProjectCommands.delete(projectId: projectId))
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

    /// Launches a thread in the "Sandbox" project and deletes it when the test ends (unless `keep`).
    @MainActor
    private func launchSandboxThread(_ connection: RPCConnection, projectId: String, text: String = "Reply with OK only.",
                                     title: String = "Helm Mobile live test", keep: Bool = false) async throws -> String {
        let threadId = UUID().uuidString.lowercased()
        _ = try await connection.call("orchestration.launchThread", [
            "commandId": .string(UUID().uuidString.lowercased()),
            "creationSource": "mobile",
            "threadId": .string(threadId),
            "projectId": .string(projectId),
            "title": .string(title),
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-sonnet-5-5"],
            "runtimeMode": "full-access",
            "interactionMode": "default",
            "workspaceStrategy": ["type": "root"],
            "initialMessage": [
                "messageId": .string(UUID().uuidString.lowercased()), "text": .string(text), "attachments": [],
            ],
        ], timeout: .seconds(60))
        if keep { return threadId }
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

    // MARK: Bounded snapshots and history pages

    private static func projection(_ connection: RPCConnection, _ threadId: String) async throws -> ThreadProjection {
        let json = try await connection.call("orchestration.getThreadProjection", ["threadId": .string(threadId)])
        return try XCTUnwrap(ThreadProjection(json: json))
    }

    private static func poll(_ what: String, timeout: Double = 120, _ done: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(try await done()) {
            guard Date() < deadline else { throw RPCError.defect("Timed out waiting for \(what)") }
            try await Task.sleep(for: .seconds(1))
        }
    }

    private static func queueMessage(_ connection: RPCConnection, _ threadId: String, _ message: ComposerMessage,
                                     messageId: String = UUID().uuidString.lowercased()) async throws {
        var fields: [String: JSON] = [
            "createdBy": "user", "creationSource": "mobile", "threadId": .string(threadId), "messageId": .string(messageId),
            "text": .string(message.text), "attachments": .array(message.attachments.map(\.json)),
            "dispatchMode": ["type": "queue_after_active"],
        ]
        if let context = message.context { fields["context"] = context }
        try await dispatch(connection, "message.dispatch", fields)
    }

    /// A sandbox thread on the cheap model, deleted when the test ends unless `keep`.
    private func launch(_ connection: RPCConnection, projectId: String, text: String, title: String,
                        keep: Bool = false) async throws -> String {
        let threadId = UUID().uuidString.lowercased()
        _ = try await connection.call("orchestration.launchThread", [
            "commandId": .string(UUID().uuidString.lowercased()), "creationSource": "mobile", "threadId": .string(threadId),
            "projectId": .string(projectId), "title": .string(title),
            "modelSelection": ["instanceId": "claudeAgent", "model": "claude-sonnet-5-5"],
            "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": ["type": "root"],
            "initialMessage": ["messageId": .string(UUID().uuidString.lowercased()), "text": .string(text), "attachments": []],
        ], timeout: .seconds(60))
        guard !keep else { return threadId }
        let http: HelmHTTP = self.http
        addTeardownBlock {
            let cleanup = RPCConnection(url: await http.webSocketURL(ticket: try await http.webSocketTicket()))
            await cleanup.start { _ in }
            _ = try? await cleanup.call("orchestration.dispatchCommand", [
                "type": "thread.delete", "commandId": .string(UUID().uuidString.lowercased()), "threadId": .string(threadId),
            ])
            await cleanup.close()
        }
        return threadId
    }

    /// A thread past the bounded window (more than 10 user turns) arrives as its recent window
    /// with a cursor; history pages walk back to the first message and merge without duplicates.
    /// Uses a sandbox thread with 12 one-word turns (kept with HELM_KEEP_HISTORY_THREAD=1, for UI checks).
    func testBoundedSnapshotAndHistoryPages() async throws {
        let connection = try await connect()
        let project = try await sandbox(connection)
        let keep = ProcessInfo.processInfo.environment["HELM_KEEP_HISTORY_THREAD"] == "1"
        let existing = try await shell(connection).threads.values.first { $0.title == "Helm Mobile history test" }
        let threadId: String
        if let existing {
            threadId = existing.id
        } else {
            threadId = try await launch(connection, projectId: project.id, text: "Turn 1. Reply with OK only.",
                                        title: "Helm Mobile history test", keep: keep)
            for turn in 2...12 {
                try await Self.queueMessage(connection, threadId, ComposerMessage(
                    text: "Turn \(turn). Reply with OK only.", attachments: [], context: nil))
            }
        }
        try await Self.poll("12 finished turns", timeout: 300) {
            let runs = try await Self.projection(connection, threadId).runs.values
            return runs.count >= 12 && runs.allSatisfy { $0.status == "completed" }
        }

        let snapshot = try await first(connection.stream("orchestration.subscribeThread", [
            "threadId": .string(threadId), "acceptBoundedSnapshot": true,
        ])) { $0["kind"]?.string == "snapshot" }
        var projection = try XCTUnwrap(snapshot["projection"].flatMap(ThreadProjection.init(json:)))
        projection.history = ThreadProjection.History(snapshot: snapshot)
        XCTAssertTrue(projection.history.hasMore)
        XCTAssertNotNil(projection.history.cursor)
        let watermark = try XCTUnwrap(projection.history.latestLocalTurnOrdinal)
        XCTAssertEqual(watermark, projection.rows.map(\.item.ordinal).max())
        let windowUsers = projection.rows.filter { $0.item.type == "user_message" }.count
        XCTAssertLessThanOrEqual(windowUsers, 10)

        var pages = 0
        while projection.history.hasMore, let cursor = projection.history.cursor, pages < 10 {
            let page = try await http.threadHistoryPage(threadId: threadId, cursor: cursor)
            XCTAssertNotNil(page["snapshotSequence"]?.int)
            XCTAssertNotNil(page["hasMoreHistory"]?.bool)
            let rows = page["items"]?.array ?? []
            XCTAssertFalse(rows.isEmpty)
            XCTAssertNotNil(rows.first?["sourceItemId"]?.string)
            let oldestBefore = try XCTUnwrap(projection.rows.first?.item.ordinal)
            let before = projection.rows.count
            projection.mergeOlder(page: page)
            XCTAssertGreaterThan(projection.rows.count, before)
            XCTAssertLessThan(try XCTUnwrap(projection.rows.first?.item.ordinal), oldestBefore)
            pages += 1
        }
        XCTAssertGreaterThan(pages, 0)
        XCTAssertFalse(projection.history.hasMore)
        let ordinals = projection.rows.filter { $0.visibility == "local" }.map(\.item.ordinal)
        XCTAssertEqual(ordinals, ordinals.sorted(), "chronological after merging")
        XCTAssertEqual(Set(projection.rows.map(\.key)).count, projection.rows.count, "no duplicates")
        let prompts = projection.rows.filter { $0.item.type == "user_message" }.map { $0.item.text }
        XCTAssertEqual(prompts.first, "Turn 1. Reply with OK only.")
        XCTAssertEqual(prompts.count, 12)
        XCTAssertEqual(projection.history.latestLocalTurnOrdinal, watermark)
        await connection.close()
    }

    /// A queued follow-up with a file is dragged ahead of another and then edited to carry a
    /// different file: the edit replaces the attachment list and the file records and links.
    func testQueuedRunReorderAndEditWithAttachments() async throws {
        let connection = try await connect()
        let project = try await sandbox(connection)
        let configEvent = try await first(connection.stream("subscribeServerConfig")) { $0["type"]?.string == "snapshot" }
        let config = try XCTUnwrap(configEvent["config"].flatMap(ServerConfig.init(json:)))
        let threadId = try await launch(connection, projectId: project.id, text: "Run `sleep 25` in the foreground, then reply OK.",
                                        title: "Helm Mobile queue test")
        try await Self.poll("the turn to run", timeout: 60) { try await Self.projection(connection, threadId).isWorking }

        let old = try await uploadFile(connection, Data("old\n".utf8), name: "old.log", mimeType: "text/plain")
        let firstMessage = ComposerMessage.build(text: "Reply with OK only.", attachments: [("ctx-old", old)],
                                                 pullRequests: [], inlineContext: config.inlineMessageContext)
        let firstId = UUID().uuidString.lowercased()
        try await Self.queueMessage(connection, threadId, firstMessage, messageId: firstId)
        try await Self.queueMessage(connection, threadId, ComposerMessage(text: "Reply with NO only.", attachments: [], context: nil))
        var queued: [QueuedMessage] = []
        try await Self.poll("two queued runs", timeout: 20) {
            queued = try await Self.projection(connection, threadId).queued
            return queued.count == 2
        }
        let queuedFirst = try XCTUnwrap(queued.first)
        // The server claims the upload under a new id (and remaps the record to it).
        XCTAssertEqual(queuedFirst.attachments.map(\.name), ["old.log"])

        // Drag the second row above the first, as the strip computes it.
        let frames = queued.enumerated().map { QueueOrder.RowFrame(id: $1.id, minY: Double($0) * 34, height: 28) }
        let before = try XCTUnwrap(QueueOrder.dropBeforeRunId(frames, moving: queued[1].id, translation: -40))
        XCTAssertEqual(before, queuedFirst.id)
        try await Self.dispatch(connection, "queued-run.reorder", [
            "threadId": .string(threadId), "runId": .string(queued[1].id), "beforeRunId": before.map { .string($0) } ?? .null,
        ])
        try await Self.poll("the new order", timeout: 20) {
            try await Self.projection(connection, threadId).queued.map(\.id) == [queued[1].id, queuedFirst.id]
        }

        // Edit: drop old.log, add new.md.
        let new = try await uploadFile(connection, Data("# new\n".utf8), name: "new.md", mimeType: "text/markdown")
        let split = QueuedEdit.split(queuedFirst.text)
        XCTAssertEqual(split.body, "Reply with OK only.")
        let payload = QueuedEdit.payload(body: "Reply with OK only, please.", trailing: split.trailing, original: queuedFirst,
                                         kept: [], added: [("ctx-new", new)], inlineContext: config.inlineMessageContext)
        var fields: [String: JSON] = [
            "threadId": .string(threadId), "runId": .string(queuedFirst.id), "text": .string(payload.text),
            "attachments": .array((payload.attachments ?? []).map(\.json)),
        ]
        if let context = payload.context { fields["context"] = context }
        try await Self.dispatch(connection, "queued-run.edit", fields)

        var edited: JSON?
        try await Self.poll("the edit", timeout: 20) {
            edited = try await Self.projection(connection, threadId).messages[firstId]
            return edited?["text"]?.string == payload.text
        }
        let stored = try XCTUnwrap(edited)
        let storedAttachments = (stored["attachments"]?.array ?? []).compactMap(ChatAttachment.init(json:))
        XCTAssertEqual(storedAttachments.map(\.name), ["new.md"])
        if config.inlineMessageContext {
            XCTAssertEqual(payload.text, "Reply with OK only, please. [new.md](t3-context://v1/file/ctx-new)")
            let records = stored["context"]?["records"]?.array ?? []
            XCTAssertEqual(records.compactMap { $0["contextId"]?.string }, ["ctx-new"], "old.log's record is gone")
            XCTAssertEqual(records.compactMap { $0["attachmentId"]?.string }, storedAttachments.map(\.id))
        }

        // Leave nothing running: clear the queue, stop the turn (the thread is deleted on teardown).
        for run in try await Self.projection(connection, threadId).queued {
            try await Self.dispatch(connection, "queued-run.cancel", ["threadId": .string(threadId), "runId": .string(run.id)])
        }
        if let active = try await Self.projection(connection, threadId).activeRun {
            try? await Self.dispatch(connection, "run.interrupt", ["threadId": .string(threadId), "runId": .string(active.id)])
        }
        await connection.close()
    }

    /// Leaves a sandbox thread busy for a minute and a half with two queued follow-ups, for the queue
    /// drag UI scenario. Opt in with HELM_PREPARE_QUEUE=1; HELM_CLEANUP=1 deletes it again.
    func testPrepareQueueDragThread() async throws {
        guard ProcessInfo.processInfo.environment["HELM_PREPARE_QUEUE"] == "1" else { throw XCTSkip("HELM_PREPARE_QUEUE not set") }
        let connection = try await connect()
        let project = try await sandbox(connection)
        let threadId = try await launch(connection, projectId: project.id, text: "Run `python3 -c 'import time; time.sleep(90)'` in the foreground and wait for it, then reply OK.",
                                        title: "Helm Mobile queue drag", keep: true)
        try await Self.poll("the turn to run", timeout: 60) { try await Self.projection(connection, threadId).isWorking }
        for text in ["First queued: reply A.", "Second queued: reply B."] {
            try await Self.queueMessage(connection, threadId, ComposerMessage(text: text, attachments: [], context: nil))
        }
        try await Self.poll("two queued runs", timeout: 20) { try await Self.projection(connection, threadId).queued.count == 2 }
        await connection.close()
    }

    /// Deletes the threads the opt-in scenarios keep, only in the sandbox project.
    func testCleanupKeptThreads() async throws {
        guard ProcessInfo.processInfo.environment["HELM_CLEANUP"] == "1" else { throw XCTSkip("HELM_CLEANUP not set") }
        let connection = try await connect()
        let project = try await sandbox(connection)
        let kept = try await shell(connection).threads.values.filter {
            $0.projectId == project.id && ["Helm Mobile history test", "Helm Mobile queue drag"].contains($0.title)
        }
        for thread in kept {
            if let active = try await Self.projection(connection, thread.id).activeRun {
                try? await Self.dispatch(connection, "run.interrupt", ["threadId": .string(thread.id), "runId": .string(active.id)])
            }
            try await Self.dispatch(connection, "thread.delete", ["threadId": .string(thread.id)])
        }
        await connection.close()
    }
}
