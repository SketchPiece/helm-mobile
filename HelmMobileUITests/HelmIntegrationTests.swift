import XCTest

/// The ways into Helm from outside it: the home-screen quick action and the share sheet. Needs a
/// paired app (see HelmTourTests); screenshots land in /tmp/hm-ui.
final class HelmIntegrationTests: XCTestCase {
    private var app: XCUIApplication!
    private var springboard: XCUIApplication!
    private let shots = URL(fileURLWithPath: "/tmp/hm-ui")

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        // Leftover system prompts (notifications, "Open in Helm?") would cover everything.
        for label in ["Don’t Allow", "Don't Allow", "Cancel"] where springboard.alerts.buttons[label].exists {
            springboard.alerts.buttons[label].tap()
        }
    }

    /// The notification prompt and the keyboard's first-run tip, if they show up over the app.
    private func dismissPrompts() {
        sleep(2)
        for label in ["Don’t Allow", "Don't Allow"] where springboard.alerts.buttons[label].exists {
            springboard.alerts.buttons[label].tap()
        }
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    }

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "\(name).png"))
    }

    func testQuickActionOpensNewThread() throws {
        app.launch()
        XCTAssertTrue(app.buttons["newThread"].waitForExistence(timeout: 20))
        // From a cold start; with Helm running the scene delegate gets it instead.
        if ProcessInfo.processInfo.environment["HELM_QUICK_ACTION_WARM"] != "1" { app.terminate() }
        XCUIDevice.shared.press(.home)
        sleep(2)
        // The App Library holds a hidden copy of every icon; find the visible one, paging right.
        XCTAssertTrue(springboard.icons["Helm"].waitForExistence(timeout: 10))
        var icon: XCUIElement?
        for _ in 0..<4 {
            icon = springboard.icons.matching(identifier: "Helm").allElementsBoundByIndex.first { $0.isHittable }
            if icon != nil { break }
            springboard.swipeLeft()
            sleep(1)
        }
        let helm = try XCTUnwrap(icon, "Helm isn't on the home screen")
        helm.press(forDuration: 1.5)
        let action = springboard.buttons["New task"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        shot("40-quick-action")
        action.tap()
        XCTAssertTrue(app.buttons["startThread"].waitForExistence(timeout: 20))
        dismissPrompts()
        shot("41-quick-action-new-thread")
    }

    /// What the share extension left in the App Group opens New Thread on launch. Seed it from the
    /// host first (a `Shares/<id>/manifest.json` in the app's group container), then run with
    /// HELM_SHARE_SEEDED=1.
    func testSeededShareOpensNewThread() throws {
        guard ProcessInfo.processInfo.environment["HELM_SHARE_SEEDED"] == "1" else {
            throw XCTSkip("Seed a share in the App Group container and set HELM_SHARE_SEEDED=1")
        }
        app.launch()
        XCTAssertTrue(app.buttons["startThread"].waitForExistence(timeout: 20))
        dismissPrompts()
        sleep(4)
        shot("45-seeded-share")
    }

    /// Shares a photo from Photos into Helm.
    func testShareFromPhotos() throws {
        app.launch()
        XCTAssertTrue(app.buttons["newThread"].waitForExistence(timeout: 20))
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        sleep(2)
        for label in ["Don’t Allow", "Don't Allow"] where springboard.alerts.buttons[label].exists {
            springboard.alerts.buttons[label].tap()
        }
        // The grid's cells aren't exposed reliably; tap the first tile where it sits.
        sleep(2)
        photos.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.22)).tap()
        let share = photos.buttons["Share"]
        if !share.waitForExistence(timeout: 8) {
            try? photos.debugDescription.write(toFile: "/tmp/hm-ui/photos-tree.txt", atomically: true, encoding: .utf8)
            XCTFail("no Share button in Photos")
        }
        share.tap()
        sleep(3)
        shot("42-share-sheet")
        try? photos.debugDescription.write(toFile: "/tmp/hm-ui/share-sheet-tree.txt", atomically: true, encoding: .utf8)
        let target = photos.cells["Helm"].exists ? photos.cells["Helm"] : photos.buttons["Helm"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Helm isn't in the share sheet")
        target.tap()
        sleep(1)
        shot("43-share-extension")
        // Either Helm comes forward by itself, or the extension says it saved the photo.
        if !app.wait(for: .runningForeground, timeout: 8) {
            let done = photos.buttons["shareDone"]
            if done.waitForExistence(timeout: 3) { done.tap() }
            app.activate()
        }
        XCTAssertTrue(app.buttons["startThread"].waitForExistence(timeout: 20))
        dismissPrompts()
        sleep(3)
        shot("44-shared-new-thread")
    }
}
