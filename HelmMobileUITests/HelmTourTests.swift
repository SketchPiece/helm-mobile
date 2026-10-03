import XCTest

/// Walks the app against a running Helm server and saves screenshots to /tmp/hm-ui.
/// The app must already be paired (launch it once with `-pairURL <link>`).
final class HelmTourTests: XCTestCase {
    private var app: XCUIApplication!
    private let shots = URL(fileURLWithPath: "/tmp/hm-ui")

    override func setUp() {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        if let style = env["HELM_APPEARANCE"] { app.launchArguments += ["-appearance", style] }
        if let language = env["HELM_LANGUAGE"] { app.launchArguments += ["-AppleLanguages", "(\(language))"] }
        app.launch()
    }

    private func shot(_ name: String) {
        let prefix = ProcessInfo.processInfo.environment["HELM_SHOT_PREFIX"] ?? ""
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }

    func testTour() throws {
        let row = app.buttons["threadRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "thread list never loaded")
        sleep(2)
        shot("01-home")

        let snoozed = app.buttons["shelf-Snoozed"]
        if snoozed.exists {
            snoozed.tap()
            sleep(1)
            shot("02-home-snoozed")
        }

        // Open the longest-looking thread: the last row usually has history.
        let rows = app.buttons.matching(identifier: "threadRow")
        rows.element(boundBy: max(0, rows.count - 1)).tap()
        sleep(4)
        shot("03-thread-bottom")
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        sleep(1)
        shot("04-thread-scrolled")

        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        if composer.waitForExistence(timeout: 3) {
            composer.tap()
            sleep(1)
            shot("05-thread-composer-focused")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)

        app.buttons["settings"].tap()
        sleep(1)
        shot("06-settings")
        app.swipeDown(velocity: .fast)
        sleep(1)

        app.buttons["newThread"].tap()
        sleep(2)
        shot("07-new-thread")
    }

    /// Starts a real agent turn. Opt in with HELM_LIVE_TURN=<project title>.
    func testLiveTurn() throws {
        guard let projectTitle = ProcessInfo.processInfo.environment["HELM_LIVE_TURN"] else {
            throw XCTSkip("Set HELM_LIVE_TURN to a project title to run a real agent turn")
        }
        XCTAssertTrue(app.buttons["newThread"].waitForExistence(timeout: 20))
        sleep(2)
        app.buttons["newThread"].tap()
        let picker = app.buttons["projectPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(projectTitle)
        sleep(1)
        app.cells.firstMatch.buttons.firstMatch.tap()
        sleep(1)
        let field = app.textViews["newThreadText"].exists ? app.textViews["newThreadText"] : app.textFields["newThreadText"]
        field.tap()
        field.typeText(ProcessInfo.processInfo.environment["HELM_LIVE_PROMPT"]
            ?? "Run `ls` in the project root, then reply with a short markdown list of what you see. Don't change any files.")
        shot("10-new-thread-filled")
        app.buttons["startThread"].tap()

        // Watch the turn: screenshots while it works, then the finished thread.
        for index in 0..<8 {
            sleep(index < 3 ? 3 : 8)
            shot(String(format: "11-live-%02d", index))
        }
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        shot("12-live-done")
    }
}
