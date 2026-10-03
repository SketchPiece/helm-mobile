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
}
