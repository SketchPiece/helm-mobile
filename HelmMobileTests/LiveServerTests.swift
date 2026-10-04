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
}
