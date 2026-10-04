import XCTest
@testable import HelmMobile

final class OrderKeysTests: XCTestCase {
    func testKeyBetweenMatchesClientRuntime() {
        XCTAssertEqual(OrderKeys.between(nil, nil), "n")
        XCTAssertEqual(OrderKeys.between(nil, "n"), "h")
        XCTAssertEqual(OrderKeys.between("h", "n"), "k")
        XCTAssertEqual(OrderKeys.between("n", nil), "u")
        XCTAssertEqual(OrderKeys.between(nil, "b"), "an")
        // Adjacent digits extend the lower bound instead.
        XCTAssertEqual(OrderKeys.between("n", "o"), "nn")
        XCTAssertEqual(OrderKeys.between("nb", "n" + "c"), "nbn")
    }

    func testCorruptOrOutOfOrderKeysGiveNil() {
        XCTAssertNil(OrderKeys.between("n", "h"))
        XCTAssertNil(OrderKeys.between("n", "n"))
        XCTAssertNil(OrderKeys.between("ba", nil))  // trailing minimum digit
        XCTAssertNil(OrderKeys.between(nil, "A"))
    }

    func testKeysAlwaysLandStrictlyBetween() {
        var keys = ["n"]
        // Keep inserting at the top and after the first key: keys stay valid and ordered.
        for _ in 0..<60 {
            let top = OrderKeys.between(nil, keys[0])!
            keys.insert(top, at: 0)
            let second = OrderKeys.between(keys[0], keys[1])!
            keys.insert(second, at: 1)
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy(OrderKeys.isValid))
    }

    func testSpreadKeys() {
        XCTAssertEqual(OrderKeys.spread(count: 1), ["nb"])
        XCTAssertEqual(OrderKeys.spread(count: 3), ["gn", "nb", "tn"])
        let wide = OrderKeys.spread(count: 400)
        XCTAssertEqual(Array(wide.prefix(3)), ["abs", "adk", "afb"])
        XCTAssertEqual(wide, wide.sorted())
        XCTAssertTrue(wide.allSatisfy(OrderKeys.isValid))
    }

    func testMoveBetweenKeyedNeighboursIsOneWrite() throws {
        // The 2nd of three keyed threads moves down: it now sits after "u" with nothing below.
        let writes = try XCTUnwrap(OrderKeys.planMove(ordered: ["a", "b", "c"], keys: ["a": "h", "b": "n", "c": "u"], moved: "b", .down))
        XCTAssertEqual(writes.map(\.id), ["b"])
        XCTAssertEqual(writes.map(\.key), ["x"])
        // The 3rd moves up between "h" and "n".
        let third = try XCTUnwrap(OrderKeys.planMove(ordered: ["a", "b", "c"], keys: ["a": "h", "b": "n", "c": "u"], moved: "c", .up))
        XCTAssertEqual(third.map(\.key), ["k"])
        let up = try XCTUnwrap(OrderKeys.planMove(ordered: ["a", "b", "c"], keys: ["a": "h", "b": "n", "c": "u"], moved: "b", .up))
        XCTAssertEqual(up.map(\.key), ["e"])  // between the top and "h"
        XCTAssertNil(OrderKeys.planMove(ordered: ["a", "b"], keys: [:], moved: "a", .up))
        XCTAssertNil(OrderKeys.planMove(ordered: ["a", "b"], keys: [:], moved: "b", .down))
    }

    func testKeylessNeighbourMaterializesTheSection() throws {
        // c moves above b; its new upper neighbour a has no key, so the section gets spread keys.
        let writes = try XCTUnwrap(OrderKeys.planMove(ordered: ["a", "b", "c"], keys: ["b": "tn"], moved: "c", .up))
        XCTAssertEqual(writes.map(\.id), ["a", "c"])  // b already holds its spread key "tn"
        XCTAssertEqual(writes.map(\.key), ["gn", "nb"])
    }

    func testHiddenRowsKeepTheirKeys() throws {
        // A row hidden by a filter holds "k", exactly the midpoint of c's new neighbours.
        let writes = try XCTUnwrap(OrderKeys.planMove(
            ordered: ["a", "b", "c"], keys: ["a": "h", "b": "n", "c": "u", "hidden": "k"], moved: "c", .up
        ))
        XCTAssertEqual(writes.map(\.id), ["c"])
        XCTAssertEqual(writes.first?.key, "m")
    }
}

final class ThreadSortTests: XCTestCase {
    private func entry(_ id: String, _ extra: [String: JSON]) -> ThreadListEntry {
        let thread = ThreadSummary(json: Fixtures.thread(id: id, extra: extra))!
        return ThreadListEntry(ref: ThreadRef(environmentId: "e", threadId: id), thread: thread, project: nil, environmentLabel: "Mac")
    }

    func testPinnedKeyedFirstThenNewestKeyless() {
        let sorted = [
            entry("old", ["createdAt": "2026-09-01T00:00:00.000Z"]),
            entry("z", ["pinOrderKey": "u"]),
            entry("new", ["createdAt": "2026-10-01T00:00:00.000Z"]),
            entry("y", ["pinOrderKey": "h"]),
        ].sortedPinned()
        XCTAssertEqual(sorted.map(\.ref.threadId), ["y", "z", "new", "old"])
    }

    func testActiveKeylessLeadByAnchorThenKeyed() {
        let sorted = [
            entry("arranged2", ["activeOrderKey": "u", "createdAt": "2026-10-03T00:00:00.000Z"]),
            entry("arranged1", ["activeOrderKey": "h"]),
            entry("older", ["createdAt": "2026-09-01T00:00:00.000Z", "updatedAt": "2026-10-03T00:00:00.000Z"]),
            // Reopened yesterday: its anchor is the unsettle time, not creation.
            entry("reopened", ["createdAt": "2026-08-01T00:00:00.000Z", "unsettledAt": "2026-10-02T00:00:00.000Z"]),
            entry("fresh", ["createdAt": "2026-10-01T00:00:00.000Z"]),
        ].sortedActive()
        XCTAssertEqual(sorted.map(\.ref.threadId), ["reopened", "fresh", "older", "arranged1", "arranged2"])
    }

    func testKeylessThreadMovesIntoTheArrangedRunWithOneWrite() throws {
        let writes = try XCTUnwrap(OrderKeys.planMove(
            ordered: ["new", "reopened", "first", "last"], keys: ["first": "f", "last": "t"], moved: "reopened", .down
        ))
        XCTAssertEqual(writes.map(\.id), ["reopened"])
        XCTAssertTrue(writes[0].key > "f" && writes[0].key < "t")
    }

    /// Every move across a mixed keyless and keyed section sorts back into the requested order
    /// (client-runtime's "applies every move" test).
    func testEveryMoveRoundTripsThroughTheSort() {
        let threads = (0..<6).map { index in
            entry(String(index), [
                "createdAt": .string("2026-03-09T0\(6 - index):00:00.000Z"),
                "activeOrderKey": index < 3 ? nil : .string(["f", "m", "t"][index - 3]),
            ])
        }
        let ids = threads.map(\.ref.threadId)
        let keys = Dictionary(uniqueKeysWithValues: threads.compactMap { e in e.thread.activeOrderKey.map { (e.ref.threadId, $0) } })
        XCTAssertEqual(threads.sortedActive().map(\.ref.threadId), ids)
        for moved in ids {
            for target in ids.indices {
                var desired = ids.filter { $0 != moved }
                desired.insert(moved, at: target)
                let writes = Dictionary(uniqueKeysWithValues: OrderKeys.plan(ordered: desired, keys: keys, moved: moved).map { ($0.id, $0.key) })
                let updated = threads.map { e in
                    var e = e
                    if let key = writes[e.ref.threadId] { e.thread.activeOrderKey = key }
                    return e
                }
                XCTAssertEqual(updated.sortedActive().map(\.ref.threadId), desired, "moving \(moved) to \(target)")
            }
        }
    }

    func testEqualKeysBreakTiesById() {
        let sorted = [entry("b", ["activeOrderKey": "n"]), entry("a", ["activeOrderKey": "n"])].sortedActive()
        XCTAssertEqual(sorted.map(\.ref.threadId), ["a", "b"])
    }
}

final class QueueOrderTests: XCTestCase {
    func testBeforeRunIdForMoves() {
        let ids = ["A", "B", "C"]
        XCTAssertEqual(QueueOrder.beforeRunId(ids, moving: "B", .up), .some("A"))
        XCTAssertEqual(QueueOrder.beforeRunId(ids, moving: "A", .down), .some("C"))
        // Moving the second-to-last down puts it at the end: beforeRunId is null.
        XCTAssertEqual(QueueOrder.beforeRunId(ids, moving: "B", .down), .some(nil))
        XCTAssertNil(QueueOrder.beforeRunId(ids, moving: "A", .up))
        XCTAssertNil(QueueOrder.beforeRunId(ids, moving: "C", .down))
        XCTAssertNil(QueueOrder.beforeRunId(ids, moving: "X", .up))
    }
}

final class PendingOrderKeyTests: XCTestCase {
    private func shell(_ extra: [String: JSON]) -> ShellState {
        var shell = ShellState()
        shell.apply(["kind": "snapshot", "snapshot": [
            "snapshotSequence": 1, "projects": [], "threads": [Fixtures.thread(extra: extra)], "archivedThreads": [],
        ]])
        return shell
    }

    func testPendingKeySurvivesUnrelatedUpdatesUntilEchoed() {
        var shell = shell(["activeOrderKey": "h"])
        shell.setPendingOrderKey(threadId: "t1", pinned: false, key: "r")
        XCTAssertEqual(shell.threads["t1"]?.activeOrderKey, "r")
        // An update that predates the write still carries the old key: the row stays put.
        shell.apply(["kind": "thread.updated", "sequence": 2, "location": "active",
                     "thread": Fixtures.thread(extra: ["activeOrderKey": "h", "title": "Renamed"])])
        XCTAssertEqual(shell.threads["t1"]?.activeOrderKey, "r")
        XCTAssertEqual(shell.threads["t1"]?.title, "Renamed")
        // The echo settles it.
        shell.apply(["kind": "thread.updated", "sequence": 3, "location": "active",
                     "thread": Fixtures.thread(extra: ["activeOrderKey": "r"])])
        XCTAssertTrue(shell.pendingOrderKeys.isEmpty)
    }

    func testFailedWriteRestoresTheServerKey() {
        var shell = shell(["pinnedAt": "2026-10-01T00:00:00.000Z"])
        shell.setPendingOrderKey(threadId: "t1", pinned: true, key: "n")
        XCTAssertEqual(shell.threads["t1"]?.pinOrderKey, "n")
        shell.revertPendingOrderKey(threadId: "t1")
        XCTAssertNil(shell.threads["t1"]?.pinOrderKey)
        XCTAssertTrue(shell.pendingOrderKeys.isEmpty)
    }

    func testLeavingTheSectionDropsThePendingKey() {
        var shell = shell(["pinnedAt": "2026-10-01T00:00:00.000Z", "pinOrderKey": "h"])
        shell.setPendingOrderKey(threadId: "t1", pinned: true, key: "u")
        shell.apply(["kind": "thread.updated", "sequence": 2, "location": "active", "thread": Fixtures.thread()])
        XCTAssertNil(shell.threads["t1"]?.pinOrderKey)
        XCTAssertTrue(shell.pendingOrderKeys.isEmpty)
    }
}

final class LimitRecoveryTests: XCTestCase {
    private let limited: [String: JSON] = [
        "lastErrorClass": "usage_limit", "latestRunId": "run-7",
        "latestRunCompletedAt": "2026-10-04T15:00:00.000Z", "usageLimitResetAt": "2026-10-04T19:00:00Z",
    ]

    func testParsesThreadFields() throws {
        let thread = try XCTUnwrap(ThreadSummary(json: Fixtures.thread(status: "failed", extra: limited.merging([
            "limitRecovery": ["requestId": "c1", "runId": "run-7", "resetAt": "2026-10-04T19:00:00Z", "autoResume": true],
            "autoSettleDisabledAt": "2026-10-04T12:00:00.000Z", "unsettledAt": "2026-10-03T12:00:00.000Z",
            "pinOrderKey": "h", "activeOrderKey": nil,
        ]) { $1 })))
        XCTAssertEqual(thread.limitRecovery?.runId, "run-7")
        XCTAssertEqual(thread.limitRecovery?.autoResume, true)
        XCTAssertEqual(thread.limitRecovery?.snooze, false)
        XCTAssertNotNil(thread.autoSettleDisabledAt)
        XCTAssertNotNil(thread.unsettledAt)
        XCTAssertEqual(thread.pinOrderKey, "h")
        XCTAssertNil(thread.activeOrderKey)

        let state = try XCTUnwrap(thread.usageLimitRecovery)
        XCTAssertEqual(state.runId, "run-7")
        // Echoed verbatim, without the formatter's milliseconds.
        XCTAssertEqual(state.resetAt, "2026-10-04T19:00:00Z")
        XCTAssertTrue(state.canSchedule)
        XCTAssertTrue(state.autoResume)
        XCTAssertFalse(state.snoozed)
    }

    func testSnoozedOnlyWhenTheWakeTimeIsTheReset() throws {
        let recovery: JSON = ["runId": "run-7", "resetAt": "2026-10-04T19:00:00Z", "autoResume": false, "snooze": true]
        let snoozed = ThreadSummary(json: Fixtures.thread(status: "failed", extra: limited.merging([
            "limitRecovery": recovery, "snoozedUntil": "2026-10-04T19:00:00.000Z",
        ]) { $1 }))
        XCTAssertEqual(snoozed?.usageLimitRecovery?.snoozed, true)
        XCTAssertEqual(snoozed?.usageLimitRecovery?.autoResume, false)
        let elsewhere = ThreadSummary(json: Fixtures.thread(status: "failed", extra: limited.merging([
            "limitRecovery": recovery, "snoozedUntil": "2026-10-05T09:00:00.000Z",
        ]) { $1 }))
        XCTAssertEqual(elsewhere?.usageLimitRecovery?.snoozed, false)
        // A choice made for an earlier run doesn't count.
        let stale = ThreadSummary(json: Fixtures.thread(status: "failed", extra: limited.merging([
            "limitRecovery": ["runId": "run-6", "resetAt": "2026-10-04T19:00:00Z", "autoResume": true],
        ]) { $1 }))
        XCTAssertEqual(stale?.usageLimitRecovery?.autoResume, false)
    }

    func testNoCardUnlessTheRunFailedOnALimit() {
        XCTAssertNil(ThreadSummary(json: Fixtures.thread(extra: limited))?.usageLimitRecovery)
        XCTAssertNil(ThreadSummary(json: Fixtures.thread(status: "failed", extra: ["lastErrorClass": "provider_error", "latestRunId": "r"]))?.usageLimitRecovery)
        // A reset time that is not after the run ended can't be scheduled.
        let past = ThreadSummary(json: Fixtures.thread(status: "failed", extra: limited.merging([
            "usageLimitResetAt": "2026-10-04T14:00:00Z",
        ]) { $1 }))
        XCTAssertEqual(past?.usageLimitRecovery?.canSchedule, false)
        let unknown = ThreadSummary(json: Fixtures.thread(status: "failed", extra: limited.merging(["usageLimitResetAt": nil]) { $1 }))
        XCTAssertEqual(unknown?.usageLimitRecovery?.canSchedule, false)
        XCTAssertNil(unknown?.usageLimitRecovery?.resetDate)
    }
}
