import XCTest

/// README screenshots against the demo server (`bun scripts/demo-server.ts --screen …`), saved
/// to /tmp/hm-shots. Opt-in: `TEST_RUNNER_HELM_DEMO_SHOTS=1`. The app pairs with the demo server
/// on launch; `HELM_APPEARANCE=dark` and `HELM_SHOT_PREFIX` work as in the tour.
final class DemoScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private let shots = URL(fileURLWithPath: "/tmp/hm-shots")
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HELM_DEMO_SHOTS"] != nil else { throw XCTSkip("HELM_DEMO_SHOTS not set") }
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments += ["-pairURL", env["HELM_DEMO_URL"] ?? "http://localhost:13999/pair#token=demo"]
        if let style = env["HELM_APPEARANCE"] { app.launchArguments += ["-appearance", style] }
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if deny.waitForExistence(timeout: 4) { deny.tap() }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20), "thread list never loaded")
        sleep(2)
    }

    private func shot(_ name: String) {
        let prefix = ProcessInfo.processInfo.environment["HELM_SHOT_PREFIX"] ?? ""
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(prefix)\(name).png"))
    }

    private func open(_ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'threadRow' AND label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no thread named \(title)")
        row.tap()
        sleep(3)
    }

    /// The iPad keyboard's own dismiss key, when the keyboard is up.
    private func hideKeyboard() {
        let key = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'Hide keyboard' OR label ==[c] 'dismiss keyboard'")).firstMatch
        let tip = app.buttons["Continue"].firstMatch
        if tip.exists { tip.tap(); sleep(1) }
        if isPad, key.exists { key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
    }

    private func back() {
        guard !isPad else { return }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    func testHomeAndThreads() throws {
        if isPad {
            open("Fix the flaky sync test")
            app.buttons["reviewChanges"].firstMatch.tap()
            sleep(3)
            shot("ipad-thread-diff")
            open("Rate-limit the upload endpoint")
            shot("ipad-thread-working")
            return
        }
        shot("home")
        open("Rate-limit the upload endpoint")
        shot("thread-working")
        back()
        open("Snapshot tests")
        shot("thread-approval")
        back()
        open("Tide chart")
        shot("thread-question")
        back()
        open("Fix the flaky sync test")
        let changes = app.descendants(matching: .any).matching(identifier: "changesCard").firstMatch
        if !changes.waitForExistence(timeout: 8) { app.swipeDown(); sleep(1) }
        changes.tap()
        sleep(3)
        shot("diff-files")
        app.staticTexts["SyncQueue.swift"].firstMatch.tap()
        sleep(2)
        shot("diff")
    }

    func testNewThread() throws {
        app.buttons["newThread"].firstMatch.tap()
        sleep(2)
        let option = app.buttons.matching(NSPredicate(format: "identifier == 'projectOption' AND label CONTAINS 'harbor'")).firstMatch
        if option.waitForExistence(timeout: 2) { option.tap(); sleep(1) }
        let tip = app.buttons["Continue"].firstMatch
        if tip.waitForExistence(timeout: 2) { tip.tap(); sleep(1) }
        app.typeText("Add an audit log for API key changes: who changed what and when, stored in Postgres, with an endpoint to page through it.")
        sleep(1)
        if tip.exists { tip.tap(); sleep(1) }
        hideKeyboard()
        shot(isPad ? "ipad-new-thread" : "new-thread")
    }

    /// The Mac's screen (a still frame from the demo server), drawn the way the iPad shows it.
    func testScreenRemote() throws {
        guard isPad else { throw XCTSkip("the iPad shows the screen remote best") }
        app.buttons["Computers"].firstMatch.tap()
        sleep(2)
        let screen = app.buttons["Screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 5), "no Screen button")
        screen.tap()
        sleep(6)
        hideKeyboard()
        sleep(1)
        shot("ipad-screen-remote")
    }
}
