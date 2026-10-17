import XCTest
@testable import HelmMobile

final class HtmlRenderTests: XCTestCase {
    private let reference: JSON = [
        "attachmentId": "thread-abc-123-html", "title": "Icons", "height": 1280,
        "heights": [[728, 1280], [375, 2051], [1000, 1064]],
    ]

    private func tool(_ id: String, name: String, output: JSON, status: String = "completed", ordinal: Int = 2) -> JSON {
        Fixtures.item(id, type: "dynamic_tool", ordinal: ordinal,
                      extra: ["toolName": .string(name), "output": output, "status": .string(status)])
    }

    private func text(_ json: JSON) -> String {
        String(decoding: try! JSONEncoder().encode(json), as: UTF8.self)
    }

    func testReadsTheReferenceFromEachProvidersEnvelope() {
        let result: JSON = ["htmlRender": reference, "message": "Shown above your reply."]
        let envelopes: [(String, JSON)] = [
            ("mcp__t3-code__html_render", ["content": .string(text(result))]),
            ("mcp__t3-code__html_render", [["type": "text", "text": .string(text(result))]]),
            ("t3-code.html_render", ["structuredContent": result, "content": []]),
            ("t3-code-thread_1_html_render", .string(text(result))),
            ("html_render", result),
        ]
        for (name, output) in envelopes {
            let item = TurnItem(json: tool("x", name: name, output: output))!
            XCTAssertEqual(HtmlRender(item: item)?.attachmentId, "thread-abc-123-html", name)
        }
    }

    func testIgnoresOtherToolsAndFailedCalls() {
        let result: JSON = ["htmlRender": reference]
        XCTAssertNil(HtmlRender(item: TurnItem(json: tool("a", name: "mcp__t3-code__html_preview", output: result))!))
        XCTAssertNil(HtmlRender(item: TurnItem(json: tool("b", name: "mcp__other__html_render", output: result))!))
        XCTAssertNil(HtmlRender(item: TurnItem(json: tool("c", name: "html_render", output: ["htmlRender": reference, "isError": true]))!))
        XCTAssertNil(HtmlRender(item: TurnItem(json: tool("d", name: "html_render", output: result, status: "failed"))!))
    }

    func testPageIsItsOwnBlockAndStaysOutOfTheFold() {
        let items = [
            Fixtures.item("u", type: "user_message", ordinal: 1, extra: ["text": "icons", "runId": "r1"]),
            Fixtures.item("c", type: "command_execution", ordinal: 2, extra: ["input": "ls", "runId": "r1"]),
            Fixtures.item("p", type: "dynamic_tool", ordinal: 3, extra: [
                "toolName": "mcp__t3-code__html_render", "output": ["htmlRender": reference], "runId": "r1",
            ]),
            Fixtures.item("a", type: "assistant_message", ordinal: 4, extra: ["text": "Pick one.", "runId": "r1"]),
        ].compactMap(TurnItem.init(json:))
        let blocks = Timeline.blocks(from: items, liveRunId: nil)
        XCTAssertEqual(blocks.map(\.id), ["u", "work:c", "p", "a"])
        let folded = Timeline.folded(blocks, runs: [:], activeRunId: nil, isWorking: false, expanded: [])
        XCTAssertEqual(folded.map(\.id), ["u", "fold:r1", "p", "a"])
    }

    func testFrameHeightFollowsTheMeasuredWidths() {
        let render = HtmlRender(reference: reference)!
        XCTAssertEqual(render.frameHeight(width: 375), 2000)
        XCTAssertEqual(render.frameHeight(width: 728), 1280)
        XCTAssertEqual(render.frameHeight(width: 800), 1280)
        XCTAssertEqual(render.frameHeight(width: 600, contentHeight: 900), 900)
        let unmeasured = HtmlRender(reference: ["attachmentId": "x", "title": " ", "height": 40])!
        XCTAssertEqual(unmeasured.title, "HTML")
        XCTAssertEqual(unmeasured.frameHeight(width: 400), 80)
    }
}
