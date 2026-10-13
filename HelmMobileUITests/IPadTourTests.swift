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

        // Review changes opens beside the conversation, not over it.
        let review = app.buttons["reviewChanges"]
        if review.exists {
            review.tap()
            sleep(3)
            shot("02b-landscape-changes-inspector")
            review.tap()
            sleep(1)
        }

        // Keyboard: the previous thread in Home's order, then ⌘K into the search field, then ⌘N.
        let title = app.navigationBars.firstMatch.identifier
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        sleep(2)
        shot("02c-next-thread")
        print("IPAD next thread: \(title) → \(app.navigationBars.firstMatch.identifier)")
        app.typeKey("k", modifierFlags: .command)
        sleep(1)
        shot("02d-search")
        XCTAssertTrue(app.searchFields.firstMatch.hasFocus(in: app), "⌘K didn't focus the search field")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        sleep(1)

        app.typeKey("n", modifierFlags: .command)
        sleep(2)
        shot("03-landscape-new-thread")
        XCTAssertTrue(app.textViews["newThreadText"].waitForExistence(timeout: 5), "⌘N didn't open New Thread")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        shot("04-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
    }

    func testThreadInNewWindow() throws {
        let rows = app.buttons.matching(identifier: "threadRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "thread list never loaded")
        rows.element(boundBy: max(0, rows.count - 1)).press(forDuration: 1.2)
        let item = app.buttons["Open in New Window"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no Open in New Window in the row's menu")
        item.tap()
        sleep(4)
        shot("05-thread-window")
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 5) || app.textFields["composer"].exists,
                      "the new window doesn't show the thread")
    }
}

private extension XCUIElement {
    func hasFocus(in app: XCUIApplication) -> Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
