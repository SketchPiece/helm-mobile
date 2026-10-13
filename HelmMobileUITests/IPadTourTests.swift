import XCTest

/// The iPad layout: Home in the sidebar, the open thread beside it. Run on an iPad simulator against a
/// running Helm server (the app paired once with `-pairURL <link>`); screenshots land in /tmp/hm-ipad.
final class IPadTourTests: XCTestCase {
    private var app: XCUIApplication!
    private let shots = URL(fileURLWithPath: "/tmp/hm-ipad")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        app = XCUIApplication()
        if let style = ProcessInfo.processInfo.environment["HELM_APPEARANCE"] { app.launchArguments += ["-appearance", style] }
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
    }

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
    }

    func testSplitLayout() throws {
        let rows = app.buttons.matching(identifier: "threadRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "thread list never loaded")
        sleep(1)
        shot("01-landscape-empty")

        // The last row usually has the longest history.
        rows.element(boundBy: max(0, rows.count - 1)).tap()
        sleep(4)
        shot("02-landscape-thread")
        // The sidebar stays, and another row replaces what's on the right.
        XCTAssertTrue(rows.firstMatch.isHittable, "the sidebar went away after opening a thread")

        app.buttons["newThread"].firstMatch.tap()
        sleep(2)
        shot("03-landscape-new-thread")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("04-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
    }
}
