import XCTest
@testable import HelmMobile

@MainActor
final class DraftSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var drafts: Drafts!
    private var environment: EnvironmentSession!
    private var sync: DraftSync!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "DraftSyncTests-\(UUID().uuidString)")
        drafts = Drafts(defaults: defaults)
        environment = EnvironmentSession(saved: SavedEnvironment(id: "mac", label: "Mac", baseURL: URL(string: "http://mac")!, pairedAt: Date()))
        sync = DraftSync(environment: environment, drafts: drafts)
    }

    private func remote(_ key: String, _ text: String, files: [JSON] = [], clientId: String = "desktop") -> JSON {
        ["key": .string(key), "text": .string(text), "attachments": .array(files), "clientId": .string(clientId), "updatedAt": 1]
    }

    private let picture: JSON = ["attachmentId": "pending-1", "type": "image", "name": "shot.png", "mimeType": "image/png", "sizeBytes": 3]

    func testSnapshotBringsTheMacsDraftsIncludingNewThreads() {
        sync.apply(["type": "snapshot", "drafts": [remote("thread-1", "from the Mac", files: [picture]), remote("project:p1", "start this")]])
        XCTAssertEqual(drafts.text(for: "thread-1"), "from the Mac")
        XCTAssertEqual(drafts.files(for: "thread-1").map(\.attachmentId), ["pending-1"])
        XCTAssertTrue(drafts.hasDraft("thread-1"))
        let newThread = drafts.newThreadDrafts.first
        XCTAssertEqual(newThread?.key, Drafts.newThreadKey(environmentId: "mac", projectId: "p1"))
        XCTAssertEqual(newThread?.projectId, "p1")
        XCTAssertEqual(newThread?.environmentId, "mac")
    }

    func testWhatWasInStepAndIsGoneFromTheMacWasSentThere() {
        sync.apply(["type": "snapshot", "drafts": [remote("thread-1", "draft")]])
        sync.connectionEnded()
        sync.apply(["type": "snapshot", "drafts": []])
        XCTAssertNil(drafts.draft(for: "thread-1"))
        XCTAssertFalse(drafts.hasDraft("thread-1"))
    }

    func testWrittenHereWhileAwayWinsOverTheMac() {
        drafts.save(text: "written offline", for: "thread-1", environmentId: "mac")
        sync.apply(["type": "snapshot", "drafts": [remote("thread-1", "older on the Mac")]])
        XCTAssertEqual(drafts.text(for: "thread-1"), "written offline")
        XCTAssertEqual(drafts.draft(for: "thread-1")?.dirty, true)
        // Absent on the Mac too: still kept, to go up.
        drafts.save(text: "another", for: "thread-2", environmentId: "mac")
        sync.apply(["type": "snapshot", "drafts": []])
        XCTAssertEqual(drafts.text(for: "thread-2"), "another")
    }

    func testChangesFromTheMacReachAnOpenComposerButNotItsOwnEcho() {
        sync.apply(["type": "snapshot", "drafts": []])
        sync.apply(["type": "changed", "draft": remote("thread-1", "typed on the Mac")])
        XCTAssertEqual(drafts.text(for: "thread-1"), "typed on the Mac")
        XCTAssertEqual(drafts.remoteRevision("thread-1"), 1)
        sync.apply(["type": "changed", "draft": remote("thread-1", "echo", clientId: DraftSync.clientId)])
        XCTAssertEqual(drafts.text(for: "thread-1"), "typed on the Mac")
        sync.apply(["type": "changed", "draft": remote("thread-1", "")])
        XCTAssertFalse(drafts.hasDraft("thread-1"))
    }

    func testSentDraftClearsAndSettlesOnceTheMacTakesIt() {
        drafts.save(text: "hello", for: "thread-1", environmentId: "mac")
        drafts.markSynced("thread-1", sent: drafts.draft(for: "thread-1")!)
        drafts.clear("thread-1")
        let cleared = drafts.draft(for: "thread-1")
        XCTAssertEqual(cleared?.dirty, true, "kept until the Mac hears it")
        drafts.markSynced("thread-1", sent: cleared!)
        XCTAssertNil(drafts.draft(for: "thread-1"))
    }

    func testMovingANewThreadToAnotherProject() {
        let a = Drafts.newThreadKey(environmentId: "mac", projectId: "a")
        let b = Drafts.newThreadKey(environmentId: "mac", projectId: "b")
        let c = Drafts.newThreadKey(environmentId: "mac", projectId: "c")
        drafts.save(text: "idea", for: a, environmentId: "mac", projectId: "a")
        XCTAssertFalse(drafts.move(from: a, to: b, environmentId: "mac", projectId: "b"))
        XCTAssertEqual(drafts.text(for: b), "idea")
        XCTAssertFalse(drafts.hasDraft(a))
        drafts.save(text: "own", for: c, environmentId: "mac", projectId: "c")
        XCTAssertTrue(drafts.move(from: b, to: c, environmentId: "mac", projectId: "c"), "c's own draft shows")
        XCTAssertEqual(drafts.text(for: b), "idea")
    }

    func testOldDraftsMoveOverAndWaitToGoUp() {
        defaults.set("old text", forKey: "draft.thread-9")
        defaults.set("new idea", forKey: "draft.new-thread")
        defaults.set("mac", forKey: "draft.new-thread.environmentId")
        defaults.set("p", forKey: "draft.new-thread.projectId")
        let migrated = Drafts(defaults: defaults)
        XCTAssertEqual(migrated.draft(for: "thread-9")?.dirty, true)
        XCTAssertEqual(migrated.text(for: Drafts.newThreadKey(environmentId: "mac", projectId: "p")), "new idea")
        XCTAssertNil(defaults.string(forKey: "draft.thread-9"))
    }
}
