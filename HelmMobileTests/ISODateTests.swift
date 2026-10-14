import XCTest
@testable import HelmMobile

/// The hand-written parser reads the server's dates exactly as ISO8601DateFormatter does.
final class ISODateTests: XCTestCase {
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func testMatchesTheFormatter() {
        for string in [
            "2026-10-13T16:58:40.123Z", "2024-02-29T23:59:59.999Z", "1970-01-01T00:00:00.000Z",
            "2000-03-01T12:00:00.5Z", "2031-12-31T00:00:00.000Z", "1999-01-01T01:02:03.004Z",
        ] {
            XCTAssertEqual(ISODate.fastParse(string), formatter.date(from: string), string)
        }
        XCTAssertEqual(ISODate.fastParse("2026-10-13T16:58:40Z"), ISO8601DateFormatter().date(from: "2026-10-13T16:58:40Z"))
    }

    func testLeavesOtherShapesToTheFormatter() {
        XCTAssertNil(ISODate.fastParse("2026-10-13T16:58:40+02:00"))
        XCTAssertNil(ISODate.fastParse("2026-13-13T16:58:40Z"))
        XCTAssertNil(ISODate.fastParse("not a date"))
        XCTAssertEqual(ISODate.parse("2026-10-13T16:58:40+02:00"), ISO8601DateFormatter().date(from: "2026-10-13T16:58:40+02:00"))
    }
}
