import XCTest
@testable import HelmMobile

/// Snooze presets and labels match client-runtime's `threadSettled.ts` and the web sidebar.
final class SnoozeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func testWeekdayMorningOffersEveryPreset() {
        let now = date(2026, 10, 7, 10)  // Wednesday
        let presets = Snooze.presets(now: now, calendar: calendar)
        XCTAssertEqual(presets.map(\.kind), [.hour, .threeHours, .evening, .tomorrow, .nextWeek])
        XCTAssertEqual(presets[0].date, date(2026, 10, 7, 11))
        XCTAssertEqual(presets[1].date, date(2026, 10, 7, 13))
        XCTAssertEqual(presets[2].date, date(2026, 10, 7, 18))
        XCTAssertEqual(presets[3].date, date(2026, 10, 8, 9))
        XCTAssertEqual(presets[4].date, date(2026, 10, 12, 9))
        XCTAssertEqual(presets[3].whenLabel, "9:00")
        XCTAssertEqual(presets[4].whenLabel, "Mon 9:00")
    }

    func testEveningNeedsMoreThanAnHourLeft() {
        let justBefore = Snooze.presets(now: date(2026, 10, 7, 16, 59), calendar: calendar)
        XCTAssertTrue(justBefore.contains { $0.kind == .evening })
        let anHourBefore = Snooze.presets(now: date(2026, 10, 7, 17), calendar: calendar)
        XCTAssertFalse(anHourBefore.contains { $0.kind == .evening })
        let night = Snooze.presets(now: date(2026, 10, 7, 22), calendar: calendar)
        XCTAssertEqual(night.map(\.kind), [.hour, .threeHours, .tomorrow, .nextWeek])
    }

    func testSundayCollapsesNextWeekIntoTomorrow() {
        let presets = Snooze.presets(now: date(2026, 10, 11, 10), calendar: calendar)  // Sunday
        XCTAssertEqual(presets.map(\.kind), [.hour, .threeHours, .evening, .tomorrow])
        XCTAssertEqual(presets.last?.date, date(2026, 10, 12, 9))
    }

    func testMondayNextWeekIsTheFollowingMonday() {
        let presets = Snooze.presets(now: date(2026, 10, 12, 8), calendar: calendar)
        XCTAssertEqual(presets.first { $0.kind == .nextWeek }?.date, date(2026, 10, 19, 9))
    }

    func testTomorrowAcrossDaylightSavingEnd() {
        // 25 October 2026 is 25 hours long in Berlin; tomorrow is still 9:00 local.
        let presets = Snooze.presets(now: date(2026, 10, 24, 23, 30), calendar: calendar)
        XCTAssertEqual(presets.first { $0.kind == .tomorrow }?.date, date(2026, 10, 25, 9))
    }

    func testWakeLabelRoundsUp() {
        let now = date(2026, 10, 7, 10)
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(30), now: now), "1m")
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(3600 - 1), now: now), "60m")
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(3600), now: now), "1h")
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(17 * 3600 + 60), now: now), "18h")
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(2 * 86_400 + 1), now: now), "3d")
        XCTAssertEqual(Snooze.wakeLabel(until: now.addingTimeInterval(-5), now: now), "now")
    }

    func testWakeDescription() {
        let now = date(2026, 10, 7, 10)
        XCTAssertEqual(Snooze.wakeDescription(until: date(2026, 10, 7, 17, 30), now: now, calendar: calendar), "17:30")
        XCTAssertEqual(Snooze.wakeDescription(until: date(2026, 10, 8, 9), now: now, calendar: calendar), "tomorrow 9:00")
        XCTAssertEqual(Snooze.wakeDescription(until: date(2026, 10, 12, 9), now: now, calendar: calendar), "Mon 9:00")
        XCTAssertTrue(Snooze.wakeDescription(until: date(2026, 10, 20, 9), now: now, calendar: calendar).hasSuffix(", 9:00"))
    }

    func testCustomDuration() {
        let now = date(2026, 10, 7, 10)
        XCTAssertEqual(Snooze.resolveCustom(.duration(amount: "2", unit: .hours), now: now, calendar: calendar), now.addingTimeInterval(7200))
        XCTAssertEqual(Snooze.resolveCustom(.duration(amount: "1,5", unit: .minutes), now: now, calendar: calendar), now.addingTimeInterval(90))
        XCTAssertEqual(Snooze.resolveCustom(.duration(amount: "3", unit: .days), now: now, calendar: calendar), now.addingTimeInterval(3 * 86_400))
        XCTAssertNil(Snooze.resolveCustom(.duration(amount: "0", unit: .hours), now: now, calendar: calendar))
        XCTAssertNil(Snooze.resolveCustom(.duration(amount: "-1", unit: .hours), now: now, calendar: calendar))
        XCTAssertNil(Snooze.resolveCustom(.duration(amount: "", unit: .hours), now: now, calendar: calendar))
        XCTAssertNil(Snooze.resolveCustom(.duration(amount: "soon", unit: .hours), now: now, calendar: calendar))
    }

    func testCustomDateMustBeFutureAndExist() {
        let now = date(2026, 10, 7, 10)
        let day = date(2026, 10, 9, 0)
        XCTAssertEqual(Snooze.resolveCustom(.date(day: day, time: date(2000, 1, 1, 14, 30)), now: now, calendar: calendar),
                       date(2026, 10, 9, 14, 30))
        XCTAssertNil(Snooze.resolveCustom(.date(day: date(2026, 10, 7, 0), time: date(2000, 1, 1, 9, 59)), now: now, calendar: calendar))
        // 02:30 does not exist on 28 March 2027 in Berlin (clocks jump from 2:00 to 3:00).
        XCTAssertNil(Snooze.resolveCustom(.date(day: date(2027, 3, 28, 12), time: date(2000, 1, 1, 2, 30)), now: now, calendar: calendar))
    }
}
