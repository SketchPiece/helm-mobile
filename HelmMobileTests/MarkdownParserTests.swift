import XCTest
@testable import HelmMobile

final class MarkdownParserTests: XCTestCase {
    private typealias Item = MarkdownBlock.ListItem

    private func item(_ text: String, checked: Bool? = nil, _ nested: MarkdownBlock...) -> Item {
        Item(checked: checked, blocks: [.paragraph(text)] + nested)
    }

    // MARK: Basics

    func testEmptyAndBlankInput() {
        XCTAssertEqual(MarkdownParser.parse(""), [])
        XCTAssertEqual(MarkdownParser.parse("\n\n   \n"), [])
    }

    func testHeadings() {
        XCTAssertEqual(
            MarkdownParser.parse("# One\n## Two ##\n###### Six\n####### Seven\n#hashtag"),
            [
                .heading(level: 1, text: "One"),
                .heading(level: 2, text: "Two"),
                .heading(level: 6, text: "Six"),
                .paragraph("####### Seven\n#hashtag"),
            ]
        )
    }

    func testParagraphsJoinSoftBreaksAndSplitOnBlankLines() {
        XCTAssertEqual(
            MarkdownParser.parse("First line\n  second **bold**  \n\n\nNew paragraph"),
            [.paragraph("First line\nsecond **bold**"), .paragraph("New paragraph")]
        )
    }

    func testCRLFLineEndings() {
        XCTAssertEqual(MarkdownParser.parse("# Title\r\nText\r\n"), [.heading(level: 1, text: "Title"), .paragraph("Text")])
    }

    func testThematicBreaks() {
        XCTAssertEqual(
            MarkdownParser.parse("Above\n---\n* * *\n___\nBelow"),
            [.paragraph("Above"), .thematicBreak, .thematicBreak, .thematicBreak, .paragraph("Below")]
        )
    }

    // MARK: Code

    func testFencedCodeWithLanguage() {
        XCTAssertEqual(
            MarkdownParser.parse("Run:\n```swift\nlet x = 1\n\n  print(x)\n```\nDone"),
            [.paragraph("Run:"), .codeBlock(language: "swift", code: "let x = 1\n\n  print(x)"), .paragraph("Done")]
        )
    }

    func testTildeFenceWithoutLanguageKeepsMarkdownLiteral() {
        XCTAssertEqual(
            MarkdownParser.parse("~~~\n# not a heading\n```\n~~~"),
            [.codeBlock(language: nil, code: "# not a heading\n```")]
        )
    }

    func testLongerFenceNeedsLongerClose() {
        XCTAssertEqual(
            MarkdownParser.parse("````md\n```js\nx\n```\n````"),
            [.codeBlock(language: "md", code: "```js\nx\n```")]
        )
    }

    func testIndentedFenceStripsItsIndent() {
        XCTAssertEqual(MarkdownParser.parse("  ```\n  a\n    b\n  ```"), [.codeBlock(language: nil, code: "a\n  b")])
    }

    // MARK: Lists

    func testBulletListWithContinuationLines() {
        XCTAssertEqual(
            MarkdownParser.parse("- one\n  continued\n- two\nlazy line\n* three"),
            [.bulletList([item("one\ncontinued"), item("two\nlazy line"), item("three")])]
        )
    }

    func testOrderedListKeepsStartNumber() {
        XCTAssertEqual(
            MarkdownParser.parse("3. three\n4) four\n\n10. ten"),
            [.orderedList(start: 3, [item("three"), item("four"), item("ten")])]
        )
    }

    func testListInterruptsParagraphAndEndsAtUnindentedText() {
        XCTAssertEqual(
            MarkdownParser.parse("Steps:\n1. a\n2. b\n\nAfter"),
            [.paragraph("Steps:"), .orderedList(start: 1, [item("a"), item("b")]), .paragraph("After")]
        )
    }

    func testNestedLists() {
        let expected: [MarkdownBlock] = [
            .bulletList([
                item("a", .bulletList([item("a1", .orderedList(start: 1, [item("deep")])), item("a2")])),
                item("b"),
            ]),
        ]
        XCTAssertEqual(MarkdownParser.parse("- a\n  - a1\n    1. deep\n  - a2\n- b"), expected)
        // Four-space nesting, as many agents write it.
        XCTAssertEqual(MarkdownParser.parse("- a\n    - a1\n        1. deep\n    - a2\n- b"), expected)
    }

    func testUnderIndentedNestedListUnderOrderedItem() {
        XCTAssertEqual(
            MarkdownParser.parse("1. first\n  - sub\n2. second"),
            [.orderedList(start: 1, [item("first", .bulletList([item("sub")])), item("second")])]
        )
    }

    func testCodeBlockInsideListItem() {
        XCTAssertEqual(
            MarkdownParser.parse("1. Install:\n   ```sh\n   npm i\n   ```\n2. Run"),
            [.orderedList(start: 1, [item("Install:", .codeBlock(language: "sh", code: "npm i")), item("Run")])]
        )
    }

    func testTaskItems() {
        XCTAssertEqual(
            MarkdownParser.parse("- [ ] todo\n- [x] done\n- [X] also\n- [link](x) plain"),
            [.bulletList([
                item("todo", checked: false),
                item("done", checked: true),
                item("also", checked: true),
                item("[link](x) plain"),
            ])]
        )
    }

    func testDashLineIsNotAListWithoutSpace() {
        XCTAssertEqual(MarkdownParser.parse("-not a list\n**bold**"), [.paragraph("-not a list\n**bold**")])
    }

    // MARK: Quotes

    func testBlockquoteWithNestedBlocksAndLazyLine() {
        XCTAssertEqual(
            MarkdownParser.parse("> # Note\n> text\nlazy\n>\n> - item\n\nafter"),
            [
                .blockquote([.heading(level: 1, text: "Note"), .paragraph("text\nlazy"), .bulletList([item("item")])]),
                .paragraph("after"),
            ]
        )
    }

    func testNestedBlockquote() {
        XCTAssertEqual(MarkdownParser.parse("> outer\n>> inner"), [.blockquote([.paragraph("outer"), .blockquote([.paragraph("inner")])])])
    }

    // MARK: Tables

    func testTableWithAlignmentRowAndRaggedRows() {
        XCTAssertEqual(
            MarkdownParser.parse("Intro\n| Name | Size |\n|:-----|-----:|\n| a | 1 |\n| b |\n| c | 3 | extra |\n\nAfter"),
            [
                .paragraph("Intro"),
                .table(header: ["Name", "Size"], rows: [["a", "1"], ["b", ""], ["c", "3"]]),
                .paragraph("After"),
            ]
        )
    }

    func testTableWithoutOuterPipesAndEscapedPipe() {
        XCTAssertEqual(
            MarkdownParser.parse("a | b\n--- | :---:\n`x \\| y` | 2"),
            [.table(header: ["a", "b"], rows: [["`x | y`", "2"]])]
        )
    }

    func testPipeTextWithoutDelimiterRowIsAParagraph() {
        XCTAssertEqual(MarkdownParser.parse("a | b\nc | d"), [.paragraph("a | b\nc | d")])
    }

    // MARK: Streaming

    func testUnterminatedFenceIsCodeToTheEnd() {
        XCTAssertEqual(MarkdownParser.parse("Here:\n```python\ndef f():\n    pass"), [
            .paragraph("Here:"), .codeBlock(language: "python", code: "def f():\n    pass"),
        ])
        // A trailing newline or a half-arrived closing fence must not flash in the block.
        XCTAssertEqual(MarkdownParser.parse("```\ncode\n"), [.codeBlock(language: nil, code: "code")])
        XCTAssertEqual(MarkdownParser.parse("```\ncode\n``"), [.codeBlock(language: nil, code: "code")])
        XCTAssertEqual(MarkdownParser.parse("```"), [.codeBlock(language: nil, code: "")])
    }

    func testHalfWrittenTable() {
        XCTAssertEqual(MarkdownParser.parse("| a | b |"), [.paragraph("| a | b |")])
        XCTAssertEqual(MarkdownParser.parse("| a | b |\n|--"), [.table(header: ["a", "b"], rows: [])])
        XCTAssertEqual(MarkdownParser.parse("| a | b |\n|---|---|\n| 1"), [.table(header: ["a", "b"], rows: [["1", ""]])])
    }

    func testEveryPrefixParses() {
        let text = "# T\n\n- [x] a\n  - b\n\n> q\n\n| h | i |\n|---|---|\n| 1 | 2 |\n\n```js\nx\n```\n\n1. end"
        var prefix = ""
        for character in text {
            prefix.append(character)
            XCTAssertFalse(MarkdownParser.parse(prefix).isEmpty, "prefix: \(prefix.debugDescription)")
        }
    }

    // MARK: Text

    func testCyrillicText() {
        XCTAssertEqual(
            MarkdownParser.parse("## Привет, мир\nЭто *курсив* и `код`.\n- пункт один\n- [x] готово\n| Имя | Значение |\n|---|---|\n| ключ | значение |"),
            [
                .heading(level: 2, text: "Привет, мир"),
                .paragraph("Это *курсив* и `код`."),
                .bulletList([item("пункт один"), item("готово", checked: true)]),
                .table(header: ["Имя", "Значение"], rows: [["ключ", "значение"]]),
            ]
        )
    }

    // MARK: Performance

    func testLargeMessageParsesQuickly() {
        let section = """
        ## Section

        Some paragraph with **bold**, `code` and a [link](https://example.com).
        It continues on a second line.

        - item one
          - nested item
        - [ ] task

        | col | value |
        |-----|-------|
        | a   | 1     |

        ```swift
        let value = compute()
        print(value)
        ```

        > quoted text

        """
        let text = String(repeating: section, count: 110)
        XCTAssertGreaterThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 2000)
        let start = Date()
        let blocks = MarkdownParser.parse(text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(blocks.isEmpty)
        // Generous bound for slow CI simulators; on device this is a few milliseconds.
        XCTAssertLessThan(elapsed, 0.1)
        measure { _ = MarkdownParser.parse(text) }
    }
}
