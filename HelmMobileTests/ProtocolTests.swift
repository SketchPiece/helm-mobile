import XCTest
@testable import HelmMobile

final class PairingTargetTests: XCTestCase {
    func testDirectPairingLinkWithFragmentToken() {
        let target = PairingTarget.parse(link: "http://100.101.102.103:3783/pair#token=7K3MZQ9XH2PA")
        XCTAssertEqual(target?.baseURL.absoluteString, "http://100.101.102.103:3783/")
        XCTAssertEqual(target?.code, "7K3MZQ9XH2PA")
    }

    func testQueryTokenFallback() {
        let target = PairingTarget.parse(link: "https://mac.example.com/pair?token=ABC")
        XCTAssertEqual(target?.baseURL.absoluteString, "https://mac.example.com/")
        XCTAssertEqual(target?.code, "ABC")
    }

    func testHostedPairingLink() {
        let target = PairingTarget.parse(link: "https://app.t3.codes/pair?host=https%3A%2F%2Fmy-mac.ts.net%3A8443&label=Mac#token=XYZ")
        XCTAssertEqual(target?.baseURL.absoluteString, "https://my-mac.ts.net:8443/")
        XCTAssertEqual(target?.code, "XYZ")
    }

    func testWebSocketSchemesMapToHTTP() {
        XCTAssertEqual(PairingTarget.parse(link: "wss://h.example/#token=A")?.baseURL.scheme, "https")
        XCTAssertEqual(PairingTarget.parse(link: "ws://h.example/#token=A")?.baseURL.scheme, "http")
    }

    func testLinkWithoutTokenIsRejected() {
        XCTAssertNil(PairingTarget.parse(link: "http://100.64.0.1:3783/"))
        XCTAssertNil(PairingTarget.parse(link: "not a url"))
    }

    func testManualAddressDefaults() {
        // Bare tailnet/LAN addresses get http and Helm's port.
        XCTAssertEqual(PairingTarget.normalizeHost("100.64.0.7", defaultScheme: nil)?.absoluteString, "http://100.64.0.7:3783/")
        XCTAssertEqual(PairingTarget.normalizeHost("my-mac.tail1234.ts.net", defaultScheme: nil)?.absoluteString,
                       "http://my-mac.tail1234.ts.net:3783/")
        XCTAssertEqual(PairingTarget.normalizeHost("192.168.1.5:13773", defaultScheme: nil)?.absoluteString,
                       "http://192.168.1.5:13773/")
        // Public names get https and keep their port.
        XCTAssertEqual(PairingTarget.normalizeHost("helm.example.com", defaultScheme: nil)?.absoluteString,
                       "https://helm.example.com/")
        XCTAssertEqual(PairingTarget.normalizeHost("http://localhost:13773/pair", defaultScheme: nil)?.absoluteString,
                       "http://localhost:13773/")
    }
}

final class RPCErrorTests: XCTestCase {
    func testFailCauseCarriesTagAndMessage() {
        let cause: JSON = [["_tag": "Fail", "error": ["_tag": "OrchestrationV2DispatchCommandError", "message": "Thread is archived"]]]
        XCTAssertEqual(RPCError.from(cause: cause), .failure(tag: "OrchestrationV2DispatchCommandError", message: "Thread is archived"))
    }

    func testDieAndInterrupt() {
        XCTAssertEqual(RPCError.from(cause: [["_tag": "Die", "defect": ["name": "Error", "message": "boom"]]]), .defect("boom"))
        XCTAssertEqual(RPCError.from(cause: [["_tag": "Interrupt", "fiberId": 4]]), .interrupted)
    }
}

final class JSONTests: XCTestCase {
    func testRoundTripKeepsIntegersIntegral() throws {
        let value: JSON = ["_tag": "Request", "id": 3, "payload": ["a": [1, 2.5, nil, true]], "headers": []]
        let text = String(decoding: try value.data(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"id\":3"))
        XCTAssertEqual(try JSON.parse(Data(text.utf8)), value)
    }

    func testISODates() {
        XCTAssertNotNil(ISODate.parse("2026-10-03T12:05:00.000Z"))
        XCTAssertNotNil(ISODate.parse("2026-10-03T12:05:00Z"))
        XCTAssertNil(ISODate.parse("yesterday"))
    }
}

enum Fixtures {
    static func thread(id: String = "t1", status: String = "idle", extra: [String: JSON] = [:]) -> JSON {
        var object: [String: JSON] = [
            "id": .string(id), "projectId": "p1", "title": "Fix login", "providerInstanceId": "codex",
            "modelSelection": ["instanceId": "codex", "model": "gpt-5.4"], "runtimeMode": "full-access",
            "interactionMode": "default", "branch": "main", "worktreePath": nil, "status": .string(status),
            "activityRunStatus": nil, "lastError": nil, "pendingRuntimeRequest": nil, "latestVisibleMessage": nil,
            "hasActionableProposedPlan": false, "createdAt": "2026-10-01T10:00:00.000Z",
            "updatedAt": "2026-10-01T11:00:00.000Z", "archivedAt": nil, "settledOverride": nil, "settledAt": nil,
            "lineage": ["parentThreadId": nil, "relationshipToParent": nil, "rootThreadId": .string(id)],
            "deletedAt": nil,
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    static func project(id: String = "p1", title: String = "t3code") -> JSON {
        ["id": .string(id), "title": .string(title), "workspaceRoot": "/Users/me/t3code", "defaultModelSelection": nil,
         "scripts": [], "createdAt": "2026-09-01T00:00:00.000Z", "updatedAt": "2026-10-01T00:00:00.000Z"]
    }

    static func item(_ id: String, type: String, ordinal: Int, runId: String? = "r1", extra: [String: JSON] = [:]) -> JSON {
        var object: [String: JSON] = [
            "id": .string(id), "threadId": "t1", "runId": runId.map { .string($0) } ?? .null, "nodeId": nil,
            "parentItemId": nil, "ordinal": .number(Double(ordinal)), "status": "completed", "title": nil,
            "startedAt": nil, "completedAt": nil, "updatedAt": "2026-10-01T11:00:00.000Z", "type": .string(type),
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    static func projection(items: [JSON] = [], runs: [JSON] = [], requests: [JSON] = []) -> JSON {
        [
            "thread": thread(), "runs": .array(runs), "attempts": [], "nodes": [], "subagents": [],
            "providerSessions": [], "providerThreads": [], "providerTurns": [], "runtimeRequests": .array(requests),
            "messages": [], "plans": [], "turnItems": .array(items), "checkpointScopes": [], "checkpoints": [],
            "contextHandoffs": [], "contextTransfers": [],
            "visibleTurnItems": .array(items.enumerated().map { index, item in
                ["position": .number(Double(index)), "visibility": "local", "sourceThreadId": "t1",
                 "sourceItemId": item["id"]!, "item": item]
            }),
            "updatedAt": "2026-10-01T11:00:00.000Z",
        ]
    }

    static func event(_ type: String, _ payload: JSON) -> JSON {
        ["id": "e", "threadId": "t1", "occurredAt": "2026-10-01T11:00:01.000Z", "type": .string(type), "payload": payload]
    }
}

final class ShellStateTests: XCTestCase {
    func testSnapshotThenDeltas() {
        var shell = ShellState()
        shell.apply(["kind": "snapshot", "snapshot": [
            "schemaVersion": 2, "snapshotSequence": 100, "projects": [Fixtures.project()],
            "threads": [Fixtures.thread()], "archivedThreads": [],
        ]])
        XCTAssertEqual(shell.sequence, 100)
        XCTAssertEqual(shell.threads["t1"]?.title, "Fix login")
        XCTAssertEqual(shell.projects["p1"]?.title, "t3code")

        // Older sequences are ignored.
        shell.apply(["kind": "thread.removed", "sequence": 90, "location": "active", "threadId": "t1"])
        XCTAssertNotNil(shell.threads["t1"])

        shell.apply(["kind": "thread.updated", "sequence": 101, "location": "active",
                     "thread": Fixtures.thread(id: "t2", status: "running")])
        XCTAssertEqual(shell.threads["t2"]?.phase, .working)

        // Archiving moves a thread out of the active list.
        shell.apply(["kind": "thread.updated", "sequence": 102, "location": "archive", "thread": Fixtures.thread()])
        XCTAssertNil(shell.threads["t1"])

        shell.apply(["kind": "project.removed", "sequence": 103, "projectId": "p1"])
        XCTAssertNil(shell.projects["p1"])
        shell.apply(["kind": "synchronized"])
        XCTAssertTrue(shell.isSynchronized)
    }

    func testEnrichmentSnapshotDoesNotReplaceThreads() {
        var shell = ShellState()
        shell.apply(["kind": "snapshot", "snapshot": [
            "snapshotSequence": 5, "projects": [Fixtures.project()], "threads": [Fixtures.thread()], "archivedThreads": [],
        ]])
        shell.apply(["kind": "snapshot", "resolvedRepositoryIdentityRoots": ["/Users/me/t3code"], "snapshot": [
            "snapshotSequence": 5, "projects": [Fixtures.project(title: "t3code (renamed)")], "threads": [], "archivedThreads": [],
        ]])
        XCTAssertEqual(shell.threads.count, 1)
        XCTAssertEqual(shell.projects["p1"]?.title, "t3code (renamed)")
    }
}

final class ThreadSummaryTests: XCTestCase {
    func testPhases() {
        XCTAssertEqual(ThreadSummary(json: Fixtures.thread(extra: ["pendingRuntimeRequest": ["id": "r", "kind": "command", "createdAt": "2026-10-01T10:00:00.000Z"]]))?.phase, .approval)
        XCTAssertEqual(ThreadSummary(json: Fixtures.thread(extra: ["pendingRuntimeRequest": ["id": "r", "kind": "user_input", "createdAt": "2026-10-01T10:00:00.000Z"]]))?.phase, .input)
        XCTAssertEqual(ThreadSummary(json: Fixtures.thread(status: "failed", extra: ["lastErrorClass": "usage_limit"]))?.phase, .limited)
        XCTAssertEqual(ThreadSummary(json: Fixtures.thread(status: "failed"))?.phase, .failed)
        XCTAssertEqual(ThreadSummary(json: Fixtures.thread())?.phase, .idle)
        let unseen = ThreadSummary(json: Fixtures.thread(extra: [
            "latestRunCompletedAt": "2026-10-01T11:00:00.000Z", "lastVisitedAt": "2026-10-01T10:30:00.000Z",
        ]))
        XCTAssertEqual(unseen?.phase, .done)
        // Never visited counts as read.
        XCTAssertEqual(ThreadSummary(json: Fixtures.thread(extra: ["latestRunCompletedAt": "2026-10-01T11:00:00.000Z"]))?.phase, .idle)
    }

    func testSnoozeAndSettle() {
        let now = ISODate.parse("2026-10-02T00:00:00.000Z")!
        let snoozed = ThreadSummary(json: Fixtures.thread(extra: ["snoozedUntil": "2026-10-03T00:00:00.000Z"]))!
        XCTAssertTrue(snoozed.isSnoozed(now: now))
        let woke = ThreadSummary(json: Fixtures.thread(extra: ["snoozedUntil": "2026-10-01T00:00:00.000Z"]))!
        XCTAssertFalse(woke.isSnoozed(now: now))
        // A snoozed thread that raises its hand wakes up.
        let raised = ThreadSummary(json: Fixtures.thread(extra: [
            "snoozedUntil": "2026-10-03T00:00:00.000Z",
            "pendingRuntimeRequest": ["id": "r", "kind": "command", "createdAt": "2026-10-01T10:00:00.000Z"],
        ]))!
        XCTAssertFalse(raised.isSnoozed(now: now))
        XCTAssertTrue(ThreadSummary(json: Fixtures.thread(extra: ["settledOverride": "settled"]))!.isSettled)
        XCTAssertFalse(ThreadSummary(json: Fixtures.thread(status: "running", extra: ["settledOverride": "settled"]))!.isSettled)
    }
}

final class ThreadProjectionTests: XCTestCase {
    func testStreamingUpdateReplacesItemInPlace() throws {
        let user = Fixtures.item("i1", type: "user_message", ordinal: 1, extra: ["text": "hi", "messageId": "m1", "attachments": []])
        var projection = try XCTUnwrap(ThreadProjection(json: Fixtures.projection(items: [user])))
        let partial = Fixtures.item("i2", type: "assistant_message", ordinal: 2, extra: ["text": "Hel", "streaming": true, "status": "running"])
        projection.apply(event: Fixtures.event("turn-item.updated", partial))
        XCTAssertEqual(projection.rows.map(\.item.id), ["i1", "i2"])
        let done = Fixtures.item("i2", type: "assistant_message", ordinal: 2, extra: ["text": "Hello", "streaming": false])
        projection.apply(event: Fixtures.event("turn-item.updated", done))
        XCTAssertEqual(projection.rows.count, 2)
        XCTAssertEqual(projection.rows[1].item.text, "Hello")
    }

    func testOutOfOrderItemsAreInsertedByOrdinal() throws {
        var projection = try XCTUnwrap(ThreadProjection(json: Fixtures.projection(items: [
            Fixtures.item("a", type: "user_message", ordinal: 1, extra: ["text": "x"]),
            Fixtures.item("c", type: "assistant_message", ordinal: 3, extra: ["text": "z"]),
        ])))
        projection.apply(event: Fixtures.event("turn-item.updated", Fixtures.item("b", type: "command_execution", ordinal: 2, extra: ["input": "ls"])))
        XCTAssertEqual(projection.rows.map(\.item.id), ["a", "b", "c"])
    }

    func testRolledBackRunHidesItsItems() throws {
        var projection = try XCTUnwrap(ThreadProjection(json: Fixtures.projection(
            items: [Fixtures.item("a", type: "assistant_message", ordinal: 1, extra: ["text": "x"])],
            runs: [["id": "r1", "ordinal": 1, "status": "completed", "requestedAt": "2026-10-01T10:00:00.000Z"]]
        )))
        XCTAssertEqual(projection.rows.count, 1)
        projection.apply(event: Fixtures.event("run.updated", ["id": "r1", "ordinal": 1, "status": "rolled_back", "requestedAt": "2026-10-01T10:00:00.000Z"]))
        XCTAssertTrue(projection.rows.isEmpty)
    }

    func testEventsForOtherThreadsAreIgnoredAndDeleteEnds() throws {
        var projection = try XCTUnwrap(ThreadProjection(json: Fixtures.projection()))
        var foreign = Fixtures.event("turn-item.updated", Fixtures.item("z", type: "assistant_message", ordinal: 1, extra: ["text": "x"]))
        if case .object(var object) = foreign { object["threadId"] = "other"; foreign = .object(object) }
        projection.apply(event: foreign)
        XCTAssertTrue(projection.rows.isEmpty)
        XCTAssertFalse(projection.apply(event: Fixtures.event("thread.deleted", Fixtures.thread())))
    }

    func testActiveRunAndPendingApproval() throws {
        let approval = Fixtures.item("ap", type: "approval_request", ordinal: 2, extra: [
            "requestId": "req1", "requestKind": "command", "prompt": "rm -rf build",
        ])
        let projection = try XCTUnwrap(ThreadProjection(json: Fixtures.projection(
            items: [approval],
            runs: [["id": "r1", "ordinal": 1, "status": "waiting", "requestedAt": "2026-10-01T10:00:00.000Z"]],
            requests: [["id": "req1", "nodeId": "n", "kind": "command", "status": "pending",
                        "responseCapability": ["type": "live", "providerSessionId": "s"], "createdAt": "2026-10-01T10:00:00.000Z"]]
        )))
        XCTAssertEqual(projection.activeRun?.id, "r1")
        let pending = try XCTUnwrap(projection.pendingRequests.first)
        XCTAssertTrue(pending.canRespond)
        guard case .approval(let kind, let prompt, _, let options) = pending.kind else { return XCTFail("not an approval") }
        XCTAssertEqual(kind, "command")
        XCTAssertEqual(prompt, "rm -rf build")
        XCTAssertEqual(options.map(\.decision), ["accept", "acceptForSession", "decline"])
    }

    func testQueuedRunsInOrder() throws {
        var projection = try XCTUnwrap(ThreadProjection(json: Fixtures.projection(runs: [
            ["id": "q2", "ordinal": 3, "status": "queued", "queuePosition": 1, "userMessageId": "m2", "requestedAt": "2026-10-01T10:00:00.000Z"],
            ["id": "q1", "ordinal": 2, "status": "queued", "queuePosition": 0, "userMessageId": "m1", "requestedAt": "2026-10-01T10:00:00.000Z"],
        ])))
        projection.apply(event: Fixtures.event("message.updated", ["id": "m1", "threadId": "t1", "role": "user", "text": "first"]))
        XCTAssertEqual(projection.queued.map(\.id), ["q1", "q2"])
        XCTAssertEqual(projection.queued.first?.text, "first")
    }
}

final class TimelineTests: XCTestCase {
    private func items(_ json: [JSON]) -> [TurnItem] { json.compactMap(TurnItem.init(json:)) }

    func testWorkBetweenMessagesIsGrouped() {
        let blocks = Timeline.blocks(from: items([
            Fixtures.item("u", type: "user_message", ordinal: 1, extra: ["text": "fix it"]),
            Fixtures.item("r", type: "reasoning", ordinal: 2, extra: ["text": "thinking"]),
            Fixtures.item("c", type: "command_execution", ordinal: 3, extra: ["input": "npm test"]),
            Fixtures.item("f", type: "file_change", ordinal: 4, extra: ["fileName": "a.ts"]),
            Fixtures.item("a", type: "assistant_message", ordinal: 5, extra: ["text": "Done."]),
            Fixtures.item("k", type: "checkpoint", ordinal: 6, extra: ["checkpointId": "cp", "files": [["path": "a.ts", "kind": "modified", "additions": 2, "deletions": 1]]]),
        ]), liveRunId: nil)
        XCTAssertEqual(blocks.map(\.id), ["u", "work:r", "a", "k"])
        if case .work(_, let work, let live) = blocks[1] {
            XCTAssertEqual(work.count, 3)
            XCTAssertFalse(live)
            XCTAssertEqual(Timeline.groupSummary(work), "1 command · 1 edit")
        } else {
            XCTFail("expected work")
        }
    }

    func testLiveWorkAndHiddenRows() {
        let blocks = Timeline.blocks(from: items([
            Fixtures.item("u", type: "user_message", ordinal: 1, extra: ["text": "go"]),
            Fixtures.item("empty", type: "assistant_message", ordinal: 2, extra: ["text": "  "]),
            Fixtures.item("child", type: "command_execution", ordinal: 3, extra: ["input": "ls", "parentItemId": "sub"]),
            Fixtures.item("c", type: "command_execution", ordinal: 4, extra: ["input": "ls", "status": "running"]),
            Fixtures.item("empty-cp", type: "checkpoint", ordinal: 5, extra: ["files": []]),
        ]), liveRunId: "r1")
        XCTAssertEqual(blocks.map(\.id), ["u", "work:c"])
        if case .work(_, _, let live) = blocks[1] { XCTAssertTrue(live) } else { XCTFail("expected work") }
    }

    func testOnlyLatestTodoListIsShown() {
        let blocks = Timeline.blocks(from: items([
            Fixtures.item("t1", type: "todo_list", ordinal: 1, extra: ["steps": []]),
            Fixtures.item("a", type: "assistant_message", ordinal: 2, extra: ["text": "x"]),
            Fixtures.item("t2", type: "todo_list", ordinal: 3, extra: ["steps": []]),
        ]), liveRunId: nil)
        XCTAssertEqual(blocks.map(\.id), ["a", "t2"])
    }
}

final class HomeSectionsTests: XCTestCase {
    func testSectionsAndOrdering() {
        func entry(_ id: String, _ extra: [String: JSON] = [:], status: String = "idle") -> ThreadListEntry {
            let thread = ThreadSummary(json: Fixtures.thread(id: id, status: status, extra: extra))!
            return ThreadListEntry(ref: ThreadRef(environmentId: "e", threadId: id), thread: thread, project: nil, environmentLabel: "Mac")
        }
        let now = ISODate.parse("2026-10-02T00:00:00.000Z")!
        let sections = HomeSections(entries: [
            entry("old", ["updatedAt": "2026-09-01T00:00:00.000Z"]),
            entry("new", ["updatedAt": "2026-10-01T23:00:00.000Z"]),
            entry("pinned", ["pinnedAt": "2026-09-01T00:00:00.000Z", "updatedAt": "2026-08-01T00:00:00.000Z"]),
            entry("ask", ["pendingRuntimeRequest": ["id": "r", "kind": "user_input", "createdAt": "2026-10-01T00:00:00.000Z"]]),
            entry("sleep", ["snoozedUntil": "2026-10-05T00:00:00.000Z"]),
            entry("done", ["settledOverride": "settled"]),
        ], now: now)
        XCTAssertEqual(sections.attention.map(\.ref.threadId), ["ask"])
        XCTAssertEqual(sections.active.map(\.ref.threadId), ["pinned", "new", "old"])
        XCTAssertEqual(sections.snoozed.map(\.ref.threadId), ["sleep"])
        XCTAssertEqual(sections.settled.map(\.ref.threadId), ["done"])
    }
}
