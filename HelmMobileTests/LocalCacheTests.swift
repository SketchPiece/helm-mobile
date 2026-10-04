import XCTest
@testable import HelmMobile

final class ShellCacheTests: XCTestCase {
    private func liveShell() -> ShellState {
        var shell = ShellState()
        shell.apply(["kind": "snapshot", "snapshot": [
            "snapshotSequence": 40, "projects": [Fixtures.project()],
            "threads": [Fixtures.thread(), Fixtures.thread(id: "t2", status: "running")], "archivedThreads": [],
        ]])
        shell.apply(["kind": "thread.updated", "sequence": 41, "location": "active",
                     "thread": Fixtures.thread(extra: ["title": "Fix login (renamed)"])])
        shell.apply(["kind": "thread.updated", "sequence": 42, "location": "archive", "thread": Fixtures.thread(id: "t2")])
        return shell
    }

    func testRoundTripKeepsWhatTheServerSent() throws {
        let shell = liveShell()
        let restored = try XCTUnwrap(ShellState.restored(from: shell.snapshotItem))
        XCTAssertEqual(restored.sequence, 42)
        XCTAssertEqual(restored.threads, shell.threads)
        XCTAssertEqual(restored.projects, shell.projects)
        XCTAssertEqual(restored.threads["t1"]?.title, "Fix login (renamed)")
        XCTAssertNil(restored.threads["t2"])
        XCTAssertTrue(shell.isFromServer)
        XCTAssertFalse(restored.isFromServer)
    }

    /// The server's full snapshot carries `resolvedRepositoryIdentityRoots` too. Over a saved list
    /// it must replace everything, not be mistaken for the projects-only enrichment frame.
    func testServerSnapshotReplacesSavedList() throws {
        var shell = try XCTUnwrap(ShellState.restored(from: liveShell().snapshotItem))
        let replaced = shell.apply(["kind": "snapshot", "resolvedRepositoryIdentityRoots": ["/Users/me/t3code"], "snapshot": [
            "snapshotSequence": 7, "projects": [Fixtures.project()], "threads": [Fixtures.thread(id: "t9")], "archivedThreads": [],
        ]])
        XCTAssertTrue(replaced)
        XCTAssertTrue(shell.isFromServer)
        XCTAssertEqual(Set(shell.threads.keys), ["t9"])
        // A server whose sequence went backwards (reset) is followed, not ignored.
        XCTAssertEqual(shell.sequence, 7)
    }

    func testServerSnapshotWithNoThreadsEmptiesSavedList() throws {
        var shell = try XCTUnwrap(ShellState.restored(from: liveShell().snapshotItem))
        shell.apply(["kind": "snapshot", "resolvedRepositoryIdentityRoots": [], "snapshot": [
            "snapshotSequence": 50, "projects": [Fixtures.project()], "threads": [], "archivedThreads": [],
        ]])
        XCTAssertTrue(shell.threads.isEmpty)
    }

    func testEnrichmentAfterLiveSnapshotStillOnlyTouchesProjects() {
        var shell = liveShell()
        let replaced = shell.apply(["kind": "snapshot", "resolvedRepositoryIdentityRoots": ["/Users/me/t3code"], "snapshot": [
            "snapshotSequence": 42, "projects": [Fixtures.project(title: "t3code (enriched)")], "threads": [], "archivedThreads": [],
        ]])
        XCTAssertFalse(replaced)
        XCTAssertEqual(shell.threads.count, 1)
        XCTAssertEqual(ShellState.restored(from: shell.snapshotItem)?.projects["p1"]?.title, "t3code (enriched)")
    }
}

final class ThreadCacheTests: XCTestCase {
    private func projection(itemCount: Int) throws -> ThreadProjection {
        let items = (0..<itemCount).map { Fixtures.item("i\($0)", type: "assistant_message", ordinal: $0, extra: ["text": .string("m\($0)")]) }
        let run: JSON = ["id": "r1", "ordinal": 1, "status": "running", "requestedAt": "2026-10-01T11:00:00.000Z"]
        let request: JSON = ["id": "q1", "kind": "command", "status": "pending", "responseCapability": ["type": "live"],
                             "createdAt": "2026-10-01T11:00:00.000Z"]
        var projection = try XCTUnwrap(ThreadProjection(snapshot: [
            "kind": "snapshot", "projection": Fixtures.projection(items: items, runs: [run], requests: [request]),
            "historyCursor": "c1", "hasMoreHistory": true, "latestLocalTurnOrdinal": .number(Double(itemCount - 1)),
        ]))
        projection.apply(event: Fixtures.event("checkpoint.captured", [
            "id": "k1", "runId": "r1", "appRunOrdinal": 1, "status": "ready",
            "files": [["path": "a.swift", "kind": "modified", "additions": 3, "deletions": 1]],
        ]))
        return projection
    }

    func testRoundTrip() throws {
        let projection = try projection(itemCount: 5)
        let restored = try XCTUnwrap(ThreadProjection(snapshot: projection.snapshotItem()))
        XCTAssertEqual(restored.rows, projection.rows)
        XCTAssertEqual(restored.items, projection.items)
        XCTAssertEqual(restored.runs, projection.runs)
        XCTAssertEqual(restored.runtimeRequests, projection.runtimeRequests)
        XCTAssertEqual(restored.checkpoints, projection.checkpoints)
        XCTAssertEqual(restored.history, projection.history)
        XCTAssertEqual(restored.thread, projection.thread)
        XCTAssertTrue(restored.isWorking)
        XCTAssertEqual(restored.pendingRequests.map(\.id), ["q1"])
    }

    func testLongTimelineKeepsNewestRowsAndDropsCursor() throws {
        let projection = try projection(itemCount: 10)
        let restored = try XCTUnwrap(ThreadProjection(snapshot: projection.snapshotItem(maxRows: 4)))
        XCTAssertEqual(restored.rows.map(\.item.id), ["i6", "i7", "i8", "i9"])
        XCTAssertEqual(Set(restored.items.keys), ["i6", "i7", "i8", "i9"])
        // The cut part can only come back from the server, never through a stale cursor.
        XCTAssertNil(restored.history.cursor)
        XCTAssertFalse(restored.history.hasMore)
    }
}

final class LocalCacheTests: XCTestCase {
    private var root: URL!
    private var cache: LocalCache!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appending(path: "LocalCacheTests-\(UUID().uuidString)")
        cache = LocalCache(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func shell(threads: [String]) -> ShellState {
        var shell = ShellState()
        shell.apply(["kind": "snapshot", "snapshot": [
            "snapshotSequence": 3, "projects": [Fixtures.project()],
            "threads": .array(threads.map { Fixtures.thread(id: $0) }), "archivedThreads": [],
        ]])
        return shell
    }

    private func projection(_ id: String) throws -> ThreadProjection {
        var json = Fixtures.projection()
        if case .object(var object) = json { object["thread"] = Fixtures.thread(id: id); json = .object(object) }
        return try XCTUnwrap(ThreadProjection(json: json))
    }

    func testShellSavesAndLoadsWithItsTime() async throws {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        cache.saveShell(shell(threads: ["t1", "t2"]), environmentId: "env-1", savedAt: savedAt)
        let found = await cache.shell(environmentId: "env-1")
        let loaded = try XCTUnwrap(found)
        XCTAssertEqual(Set(loaded.shell.threads.keys), ["t1", "t2"])
        XCTAssertFalse(loaded.shell.isFromServer)
        XCTAssertEqual(loaded.savedAt.timeIntervalSince1970, savedAt.timeIntervalSince1970, accuracy: 0.001)
        let other = await cache.shell(environmentId: "env-2")
        XCTAssertNil(other)
    }

    func testLastWriteWins() async throws {
        cache.saveShell(shell(threads: ["t1"]), environmentId: "env", savedAt: Date())
        cache.saveShell(shell(threads: ["t1", "t2", "t3"]), environmentId: "env", savedAt: Date())
        let loaded = await cache.shell(environmentId: "env")
        XCTAssertEqual(loaded?.shell.threads.count, 3)
    }

    func testThreadsAreKeptPerEnvironmentAndPruned() async throws {
        cache.saveThread(try projection("t1"), environmentId: "env", savedAt: Date())
        cache.saveThread(try projection("t2"), environmentId: "env", savedAt: Date())
        let loaded = await cache.thread("t1", environmentId: "env")
        XCTAssertEqual(loaded?.projection.thread.id, "t1")
        let elsewhere = await cache.thread("t1", environmentId: "other")
        XCTAssertNil(elsewhere)

        // The server's list no longer has t2 (deleted or archived).
        cache.keepThreads(["t1"], environmentId: "env")
        let pruned = await cache.thread("t2", environmentId: "env")
        XCTAssertNil(pruned)

        cache.removeThread("t1", environmentId: "env")
        let removed = await cache.thread("t1", environmentId: "env")
        XCTAssertNil(removed)
    }

    func testRemovingAnEnvironmentForgetsEverything() async throws {
        cache.saveShell(shell(threads: ["t1"]), environmentId: "env", savedAt: Date())
        cache.saveThread(try projection("t1"), environmentId: "env", savedAt: Date())
        cache.removeEnvironment("env")
        let shell = await cache.shell(environmentId: "env")
        let thread = await cache.thread("t1", environmentId: "env")
        XCTAssertNil(shell)
        XCTAssertNil(thread)
    }

    func testUnreadableFileIsDropped() async throws {
        cache.saveShell(shell(threads: ["t1"]), environmentId: "env", savedAt: Date())
        await withCheckedContinuation { continuation in cache.flush { continuation.resume() } }
        let file = root.appending(path: "v\(LocalCache.format)/env/shell.json")
        try Data("{\"format\": 999}".utf8).write(to: file)
        let loaded = await cache.shell(environmentId: "env")
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testOddIdsStayInsideTheFolder() {
        XCTAssertEqual(LocalCache.fileName("3f2a-11_x"), "3f2a-11_x")
        XCTAssertFalse(LocalCache.fileName("../../etc").contains("/"))
        XCTAssertFalse(LocalCache.fileName("..").hasPrefix("."))
    }
}
