import XCTest

/// Settings screens added for the phone, scheduled tasks, usage and themes, plus the snooze
/// menus. Saves screenshots to /tmp/hm-ui-settings; `HELM_APPEARANCE=dark` and
/// `HELM_SHOT_PREFIX` as in HelmTourTests. Changes nothing on the server.
final class SettingsTourTests: XCTestCase {
    private var app: XCUIApplication!
    private let shots = URL(fileURLWithPath: "/tmp/hm-ui-settings")

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

    private func openSettings() {
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 20))
        app.buttons["settings"].tap()
        sleep(1)
    }

    private func back() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
    }

    private func open(_ identifier: String) {
        let link = app.buttons[identifier].firstMatch
        if !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5), identifier)
        link.tap()
        sleep(1)
    }

    func testPhoneSettings() throws {
        openSettings()
        shot("10-settings")
        app.swipeUp()
        shot("11-settings-bottom")
        open("followUpSettings")
        shot("12-follow-ups")
        back()
        open("keyboardSettings")
        shot("13-keyboard")
        back()
        open("codeSettings")
        let custom = app.switches["customCodeSize"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.switches.firstMatch.tap()
        app.switches["codeWordWrap"].switches.firstMatch.tap()
        sleep(1)
        shot("14-code")
        // Back to the defaults.
        custom.switches.firstMatch.tap()
        app.switches["codeWordWrap"].switches.firstMatch.tap()
        back()
    }

    func testAppearanceAndThemes() throws {
        openSettings()
        open("appearanceSettings")
        sleep(2)
        shot("20-appearance")
        let published = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'theme-published:'")).firstMatch
        if published.waitForExistence(timeout: 5) {
            published.tap()
            sleep(1)
            shot("21-appearance-themed")
            back()
            shot("22-settings-themed")
            app.buttons["Close"].firstMatch.tap()
            sleep(1)
            shot("23-home-themed")
            openSettings()
            open("appearanceSettings")
            app.buttons["theme-bakelite"].tap()
            sleep(1)
        }
    }

    func testScheduledTasks() throws {
        openSettings()
        open("scheduledTasks")
        sleep(3)
        shot("30-scheduled-tasks")
        app.buttons["newScheduledTask"].tap()
        sleep(2)
        shot("31-new-task")
        app.swipeUp()
        sleep(1)
        shot("32-new-task-schedule")
        app.buttons["Cancel"].firstMatch.tap()
    }

    func testUsage() throws {
        openSettings()
        open("usage")
        sleep(3)
        shot("40-usage-limits")
        app.segmentedControls["usageTab"].buttons.element(boundBy: 1).tap()
        let headline = app.staticTexts["usageHeadline"]
        _ = headline.waitForExistence(timeout: 60)
        sleep(1)
        shot("41-usage")
        app.swipeUp()
        sleep(1)
        shot("42-usage-more")
        app.swipeUp()
        sleep(1)
        shot("43-usage-models")
    }

    func testSnoozeMenus() throws {
        let row = app.buttons["threadRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.0)
        let snooze = app.buttons["Snooze"].firstMatch
        if snooze.waitForExistence(timeout: 3) {
            snooze.tap()
            sleep(1)
            shot("50-snooze-menu")
            app.buttons["Custom…"].firstMatch.tap()
            sleep(1)
            shot("51-snooze-custom-date")
            app.buttons["Duration"].firstMatch.tap()
            sleep(1)
            shot("52-snooze-custom-duration")
            app.buttons["Close"].firstMatch.tap()
        } else {
            shot("50-row-menu")
        }
    }
}
