import XCTest
@testable import HelmMobile

/// The "Woke" label follows client-runtime's `threadWokeAt` and the web sidebar's `isWoke`.
final class WokeTests: XCTestCase {
    private let now = ISODate.parse("2026-10-02T12:00:00.000Z")!

    private func thread(status: String = "idle", _ extra: [String: JSON]) -> ThreadSummary {
        ThreadSummary(json: Fixtures.thread(status: status, extra: extra))!
    }

    func testTimerWakeShowsUntilVisited() {
        let woke = thread(["snoozedAt": "2026-10-02T09:00:00.000Z", "snoozedUntil": "2026-10-02T11:00:00.000Z",
                           "lastVisitedAt": "2026-10-02T08:00:00.000Z"])
        XCTAssertEqual(woke.wokeAt(now: now), ISODate.parse("2026-10-02T11:00:00.000Z"))
        XCTAssertTrue(woke.isWoke(now: now))

        let visited = thread(["snoozedAt": "2026-10-02T09:00:00.000Z", "snoozedUntil": "2026-10-02T11:00:00.000Z",
                              "lastVisitedAt": "2026-10-02T11:30:00.000Z"])
        XCTAssertFalse(visited.isWoke(now: now))
    }

    func testStillSnoozedIsNotWoke() {
        let sleeping = thread(["snoozedAt": "2026-10-02T09:00:00.000Z", "snoozedUntil": "2026-10-02T15:00:00.000Z"])
        XCTAssertNil(sleeping.wokeAt(now: now))
        XCTAssertFalse(sleeping.isWoke(now: now))
    }

    func testRunFinishedAfterSnoozeWakesEarly() {
        let early = thread(["snoozedAt": "2026-10-02T09:00:00.000Z", "snoozedUntil": "2026-10-02T15:00:00.000Z",
                            "latestRunCompletedAt": "2026-10-02T10:00:00.000Z",
                            "lastVisitedAt": "2026-10-02T09:30:00.000Z"])
        XCTAssertEqual(early.wokeAt(now: now), ISODate.parse("2026-10-02T10:00:00.000Z"))
        XCTAssertTrue(early.isWoke(now: now))
    }

    func testFailureSeenBeforeSnoozeDoesNotWake() {
        let snoozedWhileFailed = thread(status: "failed", [
            "snoozedAt": "2026-10-02T09:00:00.000Z", "snoozedUntil": "2026-10-02T15:00:00.000Z",
            "latestRunCompletedAt": "2026-10-02T08:00:00.000Z", "updatedAt": "2026-10-02T09:00:00.000Z",
        ])
        XCTAssertNil(snoozedWhileFailed.wokeAt(now: now))
    }

    func testSettledThreadIsNeverWoke() {
        let settled = thread(["snoozedAt": "2026-10-02T09:00:00.000Z", "snoozedUntil": "2026-10-02T11:00:00.000Z",
                              "settledOverride": "settled"])
        XCTAssertFalse(settled.isWoke(now: now))
    }

    func testWorkingAndWaitingRecede() {
        XCTAssertTrue(thread(status: "running", [:]).recedes)
        XCTAssertFalse(thread([:]).recedes)
        XCTAssertFalse(thread(["pendingRuntimeRequest": ["kind": "user_input"]]).recedes)
    }
}
