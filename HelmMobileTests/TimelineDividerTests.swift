import XCTest
@testable import HelmMobile

final class TimelineDividerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func items(_ json: [JSON]) -> [TurnItem] { json.compactMap(TurnItem.init(json:)) }

    private func message(_ id: String, at time: String) -> JSON {
        Fixtures.item(id, type: "user_message", ordinal: 0, extra: ["text": "hi", "startedAt": .string(time)])
    }

    func testDayBreaksMarkEachNewDayButNotAnAllTodayThread() {
        let now = ISODate.parse("2026-10-05T15:00:00.000Z")!
        let blocks = Timeline.blocks(from: items([
            message("a", at: "2026-10-03T09:00:00.000Z"),
            message("b", at: "2026-10-03T10:00:00.000Z"),
            message("c", at: "2026-10-04T09:00:00.000Z"),
            message("d", at: "2026-10-05T09:00:00.000Z"),
        ]), liveRunId: nil)
        let breaks = Timeline.dayBreaks(blocks, now: now, calendar: calendar)
        XCTAssertEqual(Set(breaks.keys), ["a", "c", "d"])
        XCTAssertEqual(breaks["c"], "Yesterday")
        XCTAssertEqual(breaks["d"], "Today")

        let today = Timeline.blocks(from: items([message("e", at: "2026-10-05T09:00:00.000Z")]), liveRunId: nil)
        XCTAssertTrue(Timeline.dayBreaks(today, now: now, calendar: calendar).isEmpty)
    }

    func testCompactionAndForkAreDividersNotWork() {
        let blocks = Timeline.blocks(from: items([
            Fixtures.item("u", type: "user_message", ordinal: 0, extra: ["text": "go"]),
            Fixtures.item("c", type: "compaction", ordinal: 1, extra: ["beforeTokenCount": 180_000, "afterTokenCount": 12_000]),
            Fixtures.item("f", type: "fork", ordinal: 2, extra: ["targetThreadId": "t2"]),
            Fixtures.item("x", type: "thread_created", ordinal: 3),
        ]), liveRunId: nil)
        XCTAssertEqual(blocks.map(\.id), ["u", "c", "f"])
        guard case .notice = blocks[1], case .notice = blocks[2] else { return XCTFail("expected notices") }
    }

    func testTokenCounts() {
        XCTAssertEqual(TokenCount.short(850), "850")
        XCTAssertEqual(TokenCount.short(1_000), "1k")
        XCTAssertEqual(TokenCount.short(1_260), "1.3k")
        XCTAssertEqual(TokenCount.short(180_000), "180k")
        XCTAssertEqual(TokenCount.short(1_200_000), "1.2M")
        XCTAssertEqual(TokenCount.short(nil), "?")
    }
}
