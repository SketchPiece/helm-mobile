import XCTest
@testable import HelmMobile

/// The server's background policy, read for the Mac remote: which thread Helm on the Mac shows,
/// and whether someone is at that Mac.
final class DesktopPresenceTests: XCTestCase {
    private let now = ISODate.parse("2026-10-08T12:00:00.000Z")!

    private func lease(_ threadId: String?, draftProjectId: String? = nil, composerHasContent: Bool? = nil, kind: String = "desktop-renderer", focused: Bool = true,
                       visible: Bool = true, interacted: Bool = false, updatedAt: String = "2026-10-08T11:59:50.000Z",
                       expiresAt: String = "2026-10-08T12:00:30.000Z") -> JSON {
        var scopes: [JSON] = [["type": "provider-status"]]
        if let threadId {
            var scope: [String: JSON] = ["type": "thread", "threadId": .string(threadId)]
            if let draftProjectId {
                scope["type"] = "draft-thread"
                scope["projectId"] = .string(draftProjectId)
            }
            if let composerHasContent { scope["composerHasContent"] = .bool(composerHasContent) }
            scopes.append(.object(scope))
        }
        return [
            "clientKind": .string(kind), "visible": .bool(visible), "focused": .bool(focused),
            "recentlyInteracted": .bool(interacted), "scopes": .array(scopes),
            "updatedAt": .string(updatedAt), "expiresAt": .string(expiresAt),
        ]
    }

    private func snapshot(_ leases: [JSON], idle: String = "false", locked: String = "false", stale: Bool = false) -> JSON {
        [
            "leases": .array(leases),
            "hostPower": ["idle": .string(idle), "locked": .string(locked), "suspended": false, "stale": .bool(stale)],
        ]
    }

    func testFocusedWindowWins() {
        let presence = DesktopPresence.from(snapshot: snapshot([
            lease("thread-b", focused: false, updatedAt: "2026-10-08T11:59:59.000Z"),
            lease("thread-a", focused: true),
        ]), now: now)
        XCTAssertEqual(presence?.threadId, "thread-a")
        XCTAssertEqual(presence?.macInUse, true)
    }

    func testOnlyVisibleLiveDesktopWindowsWithAThread() {
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease(nil)]), now: now))
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease("t", kind: "web")]), now: now))
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease("t", kind: "mobile")]), now: now))
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease("t", visible: false)]), now: now))
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease("t", expiresAt: "2026-10-08T11:59:00.000Z")]), now: now))
    }

    func testNewThreadNotSentYetCarriesItsProject() {
        let presence = DesktopPresence.from(snapshot: snapshot([lease("thread-new", draftProjectId: "project-1")]), now: now)
        XCTAssertEqual(presence?.threadId, "thread-new")
        XCTAssertEqual(presence?.draftProjectId, "project-1")
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease("t")]), now: now)?.draftProjectId)
    }

    func testComposerContentWhenTheWindowSaysSo() {
        XCTAssertEqual(DesktopPresence.from(snapshot: snapshot([lease("t", composerHasContent: true)]), now: now)?.composerHasContent, true)
        XCTAssertEqual(DesktopPresence.from(snapshot: snapshot([lease("t", draftProjectId: "p", composerHasContent: false)]), now: now)?.composerHasContent, false)
        XCTAssertNil(DesktopPresence.from(snapshot: snapshot([lease("t")]), now: now)?.composerHasContent)
    }

    func testLockedMacIsAway() {
        let presence = DesktopPresence.from(snapshot: snapshot([lease("t")], locked: "true"), now: now)
        XCTAssertEqual(presence?.macAway, true)
        XCTAssertEqual(presence?.macInUse, false)
    }

    func testIdleMacIsNotInUse() {
        XCTAssertEqual(DesktopPresence.from(snapshot: snapshot([lease("t", interacted: true)], idle: "true"), now: now)?.macInUse, false)
    }

    func testWithoutPowerStateTheWindowsInteractionDecides() {
        XCTAssertEqual(DesktopPresence.from(snapshot: snapshot([lease("t", interacted: true)], stale: true), now: now)?.macInUse, true)
        XCTAssertEqual(DesktopPresence.from(snapshot: snapshot([lease("t", interacted: false)], stale: true), now: now)?.macInUse, false)
        XCTAssertEqual(DesktopPresence.from(snapshot: snapshot([lease("t", interacted: true)], idle: "unknown"), now: now)?.macInUse, true)
    }
}
