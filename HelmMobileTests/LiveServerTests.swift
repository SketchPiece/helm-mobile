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
}
