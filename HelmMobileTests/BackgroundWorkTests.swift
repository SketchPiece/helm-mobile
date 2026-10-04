import XCTest
@testable import HelmMobile

/// The shell's `pendingBackgroundTasks`, read like client-runtime's `shellRuntime` and
/// `presentPendingBackgroundWork`.
final class BackgroundWorkTests: XCTestCase {
    private func thread(status: String = "completed", tasks: [JSON]) -> ThreadSummary {
        ThreadSummary(json: Fixtures.thread(status: status, extra: [
            "latestRunId": "run-1", "pendingBackgroundTasks": .array(tasks),
        ]))!
    }

    func testSubagentKeepsTheThreadWaiting() {
        let summary = thread(tasks: [
            ["taskId": "a", "kind": "subagent", "description": "Subagent: Review src/math.ts", "childThreadId": "child-1"],
        ])
        XCTAssertEqual(summary.phase, .waiting)
        XCTAssertEqual(summary.backgroundTasks.first?.childThreadId, "child-1")
        XCTAssertEqual(summary.backgroundTasks.title, "Waiting on subagent Review src/math.ts")
    }

    func testCommandAloneDoesNotHoldTheThread() {
        let summary = thread(tasks: [["taskId": "c", "kind": "command", "description": "npm run dev"]])
        XCTAssertEqual(summary.phase, .idle)
        XCTAssertEqual(summary.backgroundTasks.title, "Running: npm run dev")
    }

    func testFailureOutranksBackgroundWork() {
        let summary = thread(status: "failed", tasks: [["taskId": "m", "kind": "monitor"]])
        XCTAssertEqual(summary.phase, .failed)
    }

    func testUnknownKindsHoldAndGroupInOrder() {
        let tasks = thread(tasks: [
            ["taskId": "c", "kind": "command"],
            ["taskId": "x", "kind": "workflow"],
            ["taskId": "a", "kind": "subagent", "description": "/root/review_agent"],
            ["taskId": "b", "kind": "subagent"],
        ]).backgroundTasks
        XCTAssertEqual(tasks.map(\.kind), [.command, .backgroundTask, .subagent, .subagent])
        XCTAssertEqual(tasks[2].name, "Review Agent")
        XCTAssertTrue(tasks.holdsCompletion)
        // The list's "and" follows the device locale.
        XCTAssertEqual(tasks.title?.hasPrefix("Waiting on 2 subagents, 1 command"), true)
        XCTAssertEqual(tasks.title?.hasSuffix("1 background task"), true)
    }

    func testNoTasksNoTitle() {
        XCTAssertNil(thread(tasks: []).backgroundTasks.title)
        XCTAssertEqual(thread(tasks: []).phase, .idle)
    }
}
