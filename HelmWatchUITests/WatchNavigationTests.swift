import XCTest

/// Taps through the watch app on sample data (`-watchDemo`), or against the paired iPhone with
/// `TEST_RUNNER_HELM_WATCH_LIVE=1` (needs a thread waiting on an approval, in a project "watch-scratch").
final class WatchNavigationTests: XCTestCase {
    private var live: Bool { ProcessInfo.processInfo.environment["HELM_WATCH_LIVE"] == "1" }

    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if !live { app.launchArguments = ["-watchDemo"] }
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/hw/ui-\(name).png"))
    }

    func testOpenThreadAndNewThread() throws {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", live ? "Needs approval" : "Apple Watch remote")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "thread row")
        shot(app, "home")
        row.tap()
        let allow = app.buttons["Allow once"]
        XCTAssertTrue(allow.waitForExistence(timeout: 15), "approval card")
        shot(app, "thread")
        if live {
            app.swipeUp()
            allow.tap()
            sleep(4)
            shot(app, "allowed")
        }
        app.navigationBars.buttons.firstMatch.tap()
        let plus = app.buttons["New thread"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "+ button")
        plus.tap()
        XCTAssertTrue(app.staticTexts[live ? "watch-scratch" : "Volna"].waitForExistence(timeout: 5), "project list")
        shot(app, "new")
    }
}

/// Live only: starts a thread from the watch, replies to it and settles it.
final class WatchLiveFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func shot(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/hw/ui-\(name).png"))
    }

    /// Fills the system text input a TextFieldLink opens.
    private func enter(_ text: String, in app: XCUIApplication) {
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        if field.waitForExistence(timeout: 5) { field.tap() }
        app.typeText(text)
        shot(app, "typing")
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() } else { app.typeText("\n") }
    }

    func testStartReplySettle() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HELM_WATCH_LIVE"] == "1")
        let app = XCUIApplication()
        app.launch()
        let plus = app.buttons["New thread"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "watch-scratch")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        enter("Reply with just the word PONG", in: app)
        let pong = app.staticTexts["PONG"]
        XCTAssertTrue(pong.waitForExistence(timeout: 90), "agent reply on the watch")
        shot(app, "pong")
        let reply = app.buttons["Reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        reply.tap()
        enter("Now reply with just PING", in: app)
        XCTAssertTrue(app.staticTexts["PING"].waitForExistence(timeout: 90), "second reply")
        shot(app, "ping")
        let settle = app.buttons["Settle"].firstMatch
        XCTAssertTrue(settle.waitForExistence(timeout: 30))
        settle.tap()
        XCTAssertTrue(app.staticTexts["Settled"].waitForExistence(timeout: 15), "settled section")
        shot(app, "settled")
    }

    func testStop() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HELM_WATCH_LIVE"] == "1")
        let app = XCUIApplication()
        app.launch()
        let plus = app.buttons["New thread"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15))
        plus.tap()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "watch-scratch")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        enter("Run this shell loop and wait for it: for i in $(seq 1 120); do echo $i; sleep 1; done", in: app)
        let stop = app.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "stop while working")
        sleep(8)
        shot(app, "working")
        stop.tap()
        XCTAssertTrue(app.buttons["Settle"].firstMatch.waitForExistence(timeout: 30), "stopped")
        shot(app, "stopped")
    }
}
