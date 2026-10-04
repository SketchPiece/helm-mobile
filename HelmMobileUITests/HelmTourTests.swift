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

    func testOnboarding() throws {
        app.terminate()
        app.launchArguments += ["-showWelcome", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["connectToHelm"].waitForExistence(timeout: 10))
        shot("30-welcome")
        app.buttons["connectToHelm"].tap()
        sleep(2)
        shot("31-pairing")
        let address = app.textFields.firstMatch
        address.tap()
        address.typeText("100.64.0.9")
        sleep(1)
        shot("32-pairing-address")
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
        let option = app.buttons.matching(identifier: "projectOption").firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
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

    /// Opens the first thread that needs attention and answers it. Opt in with HELM_ANSWER=1.
    func testAnswerPendingRequest() throws {
        guard ProcessInfo.processInfo.environment["HELM_ANSWER"] != nil else {
            throw XCTSkip("Set HELM_ANSWER=1 with a thread waiting for approval or input")
        }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        shot("20-home-needs-you")
        app.buttons["threadRow"].firstMatch.tap()
        sleep(3)
        shot("21-request-card")
        let allow = app.buttons["requestPrimary"]
        XCTAssertTrue(allow.waitForExistence(timeout: 30), "no approval/answer button")
        if app.buttons["questionOption"].firstMatch.exists {
            app.buttons["questionOption"].firstMatch.tap()
            sleep(1)
            shot("22-question-picked")
        }
        allow.tap()
        sleep(12)
        shot("23-after-answer")
        sleep(15)
        shot("24-after-answer-later")
    }

    /// Opens the newest thread, its work group and its changes. Opt in with HELM_REVIEW=1.
    func testReviewNewestThread() throws {
        guard ProcessInfo.processInfo.environment["HELM_REVIEW"] != nil else { throw XCTSkip("HELM_REVIEW not set") }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(1)
        app.buttons["threadRow"].firstMatch.tap()
        sleep(4)
        shot("40-rich-bottom")
        app.swipeDown(velocity: .slow)
        sleep(1)
        shot("41-rich-up")
        let work = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'edit' OR label CONTAINS[c] 'command' OR label CONTAINS[c] 'tool'")).firstMatch
        if work.exists {
            work.tap()
            sleep(1)
            shot("42-work-expanded")
        }
        let changes = app.buttons["changesCard"].firstMatch
        if changes.waitForExistence(timeout: 3) {
            changes.tap()
            sleep(3)
            shot("43-changes")
            let file = app.buttons.matching(identifier: "diffFile").firstMatch
            if file.waitForExistence(timeout: 5) {
                file.tap()
                sleep(2)
                shot("44-diff-file")
            }
        }
    }

    /// Sends a follow-up into the newest (working) thread. Opt in with HELM_QUEUE=1.
    func testQueueWhileWorking() throws {
        guard ProcessInfo.processInfo.environment["HELM_QUEUE"] != nil else { throw XCTSkip("HELM_QUEUE not set") }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(1)
        app.buttons["threadRow"].firstMatch.tap()
        sleep(3)
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("After that, also tell me today's weekday.")
        app.buttons["send"].tap()
        sleep(2)
        shot("50-queued")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()  // dismiss the keyboard
        sleep(1)
        shot("50b-queued-no-keyboard")
        sleep(30)
        shot("51-queued-later")
        sleep(30)
        shot("52-queued-done")
    }

    /// Starts the built-in Tailscale node up to its login link. Opt in with HELM_TAILSCALE=1.
    func testTailscaleLogin() throws {
        guard ProcessInfo.processInfo.environment["HELM_TAILSCALE"] != nil else { throw XCTSkip("HELM_TAILSCALE not set") }
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 15))
        app.buttons["settings"].tap()
        let row = app.buttons["tailscaleSettings"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        sleep(1)
        shot("60-tailscale-off")
        app.buttons["tailscaleLogin"].tap()
        sleep(12)
        app.activate()
        sleep(2)
        shot("61-tailscale-login")
    }

    /// Stage 2 screens on the newest thread and the new-thread flow. Opt in with HELM_STAGE2=1.
    func testStage2Screens() throws {
        guard ProcessInfo.processInfo.environment["HELM_STAGE2"] != nil else { throw XCTSkip("HELM_STAGE2 not set") }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        shot("70-home")
        app.buttons["threadRow"].firstMatch.tap()
        sleep(3)
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("look at @gre")
        sleep(2)
        shot("71-at-suggestions")
        composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        composer.typeText("/")
        sleep(2)
        shot("72-slash-suggestions")
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["Attach"].firstMatch.tap()
        sleep(1)
        shot("73-plus-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.buttons["newThread"].tap()
        sleep(2)
        app.buttons["projectPicker"].tap()
        sleep(2)
        shot("74-project-picker")
        let add = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'add' OR label CONTAINS[c] 'доб'")).firstMatch
        if add.exists {
            add.tap()
            sleep(2)
            shot("75-add-project")
            let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'folder' OR label CONTAINS[c] 'папк'")).firstMatch
            if folder.exists {
                folder.tap()
                sleep(3)
                shot("76-folder-browser")
            }
        }
    }

    /// Opens the thread whose row contains HELM_THREAD and photographs it untouched, then opens
    /// its folded work.
    func testOpenNamedThread() throws {
        guard let title = ProcessInfo.processInfo.environment["HELM_THREAD"] else { throw XCTSkip("HELM_THREAD not set") }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'threadRow' AND label CONTAINS[c] %@", title)).firstMatch
        if !row.exists { app.buttons["shelf-Snoozed"].firstMatch.tap(); sleep(1) }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        sleep(2)
        shot("80-opened-untouched")
        sleep(3)
        shot("81-opened-later")
        let fold = app.buttons["runFold"].firstMatch
        if fold.exists {
            fold.tap()
            sleep(1)
            shot("82-fold-open")
        }
        app.swipeDown(velocity: .fast)
        sleep(1)
        shot("83-scrolled-up")
    }

    /// Pastes a picture from the clipboard straight into the composer. Opt in with HELM_PASTE=1.
    func testPasteImage() throws {
        guard ProcessInfo.processInfo.environment["HELM_PASTE"] != nil else { throw XCTSkip("HELM_PASTE not set") }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["threadRow"].firstMatch.tap()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        sleep(2)
        shot("90-composer")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80))
        UIPasteboard.general.image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        composer.tap()
        sleep(1)
        composer.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "no Paste in the edit menu")
        shot("91-paste-menu")
        paste.tap()
        sleep(3)
        shot("92-pasted")
    }

    /// Scroll-to-bottom button and a long draft in the thread named by HELM_THREAD. Opt in with HELM_SCROLL=1.
    func testScrollButtonAndLongDraft() throws {
        guard ProcessInfo.processInfo.environment["HELM_SCROLL"] != nil,
              let title = ProcessInfo.processInfo.environment["HELM_THREAD"] else { throw XCTSkip("HELM_SCROLL not set") }
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'threadRow' AND label CONTAINS[c] %@", title)).firstMatch
        if !row.exists { app.buttons["shelf-Snoozed"].firstMatch.tap(); sleep(1) }
        row.tap()
        sleep(3)
        let down = app.buttons["scrollToBottom"]
        XCTAssertFalse(down.exists, "button shown right after opening")
        shot("a-opened")
        let composer = app.textViews["composer"]
        composer.tap()
        sleep(2)
        shot("a0-keyboard")
        XCTAssertFalse(down.exists, "button shown just because the keyboard opened")
        composer.typeText(Array(repeating: "Line of a long draft message to see the field grow.", count: 12).joined(separator: "\n"))
        sleep(1)
        shot("a1-long-draft")
        XCTAssertFalse(down.exists, "button shown because the composer grew")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        sleep(1)
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        sleep(1)
        shot("a2-scrolled-up")
        XCTAssertTrue(down.waitForExistence(timeout: 3), "no button after scrolling up")
        down.tap()
        sleep(2)
        shot("a3-after-tap")
        XCTAssertFalse(down.exists, "button still there after going to the bottom")
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        app.swipeUp(velocity: .fast)
        sleep(2)
        shot("a4-dragged-to-end")
    }

    private func openThread(_ title: String) {
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'threadRow' AND label CONTAINS[c] %@", title)).firstMatch
        if !row.exists { app.buttons["shelf-Snoozed"].firstMatch.tap(); sleep(1) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "no thread named \(title)")
        row.tap()
        sleep(3)
    }

    /// Scrolls a long thread (HELM_HISTORY=<title>) to its top: the previous page loads and the
    /// message that was on screen stays where it was.
    func testHistoryPaging() throws {
        guard let title = ProcessInfo.processInfo.environment["HELM_HISTORY"] else { throw XCTSkip("HELM_HISTORY not set") }
        openThread(title)
        shot("h0-opened")
        let loader = app.buttons["loadEarlier"]
        var swipes = 0
        while !loader.isHittable, swipes < 30 {
            app.swipeDown(velocity: .slow)
            swipes += 1
        }
        // The swipe that revealed the loader started the load; find a message still on screen.
        let turns = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Turn '"))
        let window = app.windows.firstMatch.frame
        let visible = turns.allElementsBoundByIndex.filter { $0.exists && window.contains($0.frame) }
        let anchor = try XCTUnwrap(visible.first, "no message on screen")
        let label = anchor.label
        let before = anchor.frame.minY
        shot("h1-at-top")
        sleep(4)
        shot("h2-after-page")
        let after = app.staticTexts[label].frame.minY
        XCTAssertEqual(after, before, accuracy: 4, "\(label) moved from \(before) to \(after)")
        // Had the view jumped to the top of the new page, the first prompt would be on screen.
        let firstPrompt = app.staticTexts["Turn 1. Reply with OK only."]
        XCTAssertFalse(firstPrompt.exists && window.contains(firstPrompt.frame), "jumped to the oldest message")
        app.swipeDown(velocity: .slow)
        sleep(1)
        shot("h3-scrolled-into-older")
    }

    /// Drags the second queued message above the first in a working sandbox thread.
    /// Opt in with HELM_QUEUE_DRAG=<project title>.
    func testQueueDrag() throws {
        guard let projectTitle = ProcessInfo.processInfo.environment["HELM_QUEUE_DRAG"] else {
            throw XCTSkip("HELM_QUEUE_DRAG not set")
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
        app.buttons.matching(identifier: "projectOption").firstMatch.tap()
        sleep(1)
        let field = app.textViews["newThreadText"].exists ? app.textViews["newThreadText"] : app.textFields["newThreadText"]
        field.tap()
        field.typeText("UI drag test: run `sleep 45` in the foreground, then reply OK.")
        app.buttons["startThread"].tap()
        let composer = app.textViews["composer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        sleep(6)
        for text in ["First queued: reply A.", "Second queued: reply B."] {
            composer.tap()
            composer.typeText(text)
            app.buttons["send"].tap()
            sleep(2)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let handles = app.descendants(matching: .any).matching(identifier: "queueDragHandle")
        XCTAssertTrue(handles.element(boundBy: 1).waitForExistence(timeout: 15), "no drag handles")
        shot("q0-queue")
        let first = app.staticTexts["First queued: reply A."], second = app.staticTexts["Second queued: reply B."]
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        let from = handles.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -45)))
        sleep(3)
        shot("q1-dragged")
        XCTAssertLessThan(second.frame.minY, first.frame.minY, "order didn't change")
        // Edit sheet with attachment controls.
        app.buttons.matching(NSPredicate(format: "label == 'More' OR label CONTAINS 'ellipsis'")).firstMatch.tap()
        sleep(1)
        shot("q2-menu")
        app.buttons["Edit"].firstMatch.tap()
        sleep(2)
        shot("q3-edit-sheet")
    }

    /// The "+" menu offers the camera (forced on the camera-less simulator with -uiTestCamera).
    func testCameraMenuEntry() throws {
        guard ProcessInfo.processInfo.environment["HELM_CAMERA"] != nil else { throw XCTSkip("HELM_CAMERA not set") }
        app.terminate()
        app.launchArguments += ["-uiTestCamera"]
        app.launch()
        XCTAssertTrue(app.buttons["threadRow"].firstMatch.waitForExistence(timeout: 20))
        sleep(1)
        app.buttons["threadRow"].firstMatch.tap()
        let attach = app.buttons["attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 10))
        sleep(2)
        attach.tap()
        XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 3), "no Camera in the + menu")
        shot("c0-thread-attach-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        sleep(1)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(1)
        app.buttons["newThread"].tap()
        sleep(2)
        app.buttons["attach"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 3), "no Camera in the new-thread + menu")
        shot("c1-new-thread-attach-menu")
    }
}
