import Foundation

/// Block-level Markdown for assistant messages. Inline markup (emphasis, code spans, links) stays
/// in the strings and is rendered by `MarkdownView` through `AttributedString`.
enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    /// Lines of one paragraph joined with "\n"; newlines render as line breaks, as on web.
    case paragraph(String)
    case codeBlock(language: String?, code: String)
    case bulletList([ListItem])
    case orderedList(start: Int, [ListItem])
    case blockquote([MarkdownBlock])
    case table(header: [String], rows: [[String]])
    case thematicBreak

    struct ListItem: Hashable, Sendable {
        /// `nil` for a plain item, `false` / `true` for `- [ ]` / `- [x]` task items.
        var checked: Bool?
        /// The item's content. Usually a paragraph, followed by nested lists or code when indented.
        var blocks: [MarkdownBlock]
    }
}

/// A forgiving, line-based CommonMark/GFM subset. It is re-run on every streaming update, so it
/// never fails: half-written constructs degrade to the closest sensible block (an unterminated
/// fence is code to the end, a table with only its header is a header-only table). Indented code
/// blocks and setext headings are deliberately not supported; agents do not write them and they
/// misfire on sloppy indentation and on partial `-` lines while streaming.
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var lines: [Substring] = []
        for raw in text.utf8.split(separator: 10, omittingEmptySubsequences: false) {
            var line = Substring(raw)
            if line.utf8.last == 13 { line = Substring(line.utf8.dropLast()) }
            lines.append(line)
        }
        return parseBlocks(lines)
    }

    // MARK: Blocks

    private static func parseBlocks(_ lines: [Substring]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var i = 0
        let n = lines.count
        while i < n {
            let line = lines[i]
            let (indent, rest) = leading(line)
            if rest.isEmpty {
                i += 1
                continue
            }
            if let fence = fenceOpen(rest, indent: indent) {
                i = parseCode(lines, from: i + 1, fence: fence, into: &blocks)
            } else if let heading = heading(rest) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
            } else if isThematicBreak(rest) {
                blocks.append(.thematicBreak)
                i += 1
            } else if rest.utf8.first == UInt8(ascii: ">") {
                i = parseQuote(lines, from: i, into: &blocks)
            } else if let marker = listMarker(line) {
                i = parseList(lines, from: i, first: marker, into: &blocks)
            } else if i + 1 < n, isTableStart(rest, next: lines[i + 1]) {
                i = parseTable(lines, from: i, into: &blocks)
            } else {
                i = parseParagraph(lines, from: i, into: &blocks)
            }
        }
        return blocks
    }

    private static func parseCode(
        _ lines: [Substring], from start: Int, fence: Fence, into blocks: inout [MarkdownBlock]
    ) -> Int {
        var code: [Substring] = []
        var i = start
        var closed = false
        while i < lines.count {
            let line = lines[i]
            i += 1
            if isFenceClose(line, fence) {
                closed = true
                break
            }
            code.append(strip(line, columns: fence.indent))
        }
        if !closed {
            // Streaming: hide a closing fence that has only partly arrived, and trailing blank
            // lines that would make the block grow and then shrink a moment later.
            if let last = code.last {
                let (_, rest) = leading(last)
                if !rest.isEmpty, rest.utf8.count < fence.count,
                   rest.utf8.allSatisfy({ $0 == fence.char || $0 == 32 || $0 == 9 }) {
                    code.removeLast()
                }
            }
            while let last = code.last, leading(last).rest.isEmpty { code.removeLast() }
        }
        blocks.append(.codeBlock(language: fence.language, code: code.joined(separator: "\n")))
        return i
    }

    private static func parseQuote(_ lines: [Substring], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var inner: [Substring] = []
        var i = start
        var lazyAllowed = false
        while i < lines.count {
            let line = lines[i]
            let (_, rest) = leading(line)
            if rest.utf8.first == UInt8(ascii: ">") {
                var content = Substring(rest.utf8.dropFirst())
                if let first = content.utf8.first, first == 32 || first == 9 { content = Substring(content.utf8.dropFirst()) }
                inner.append(content)
                lazyAllowed = !leading(content).rest.isEmpty
                i += 1
            } else if !rest.isEmpty, lazyAllowed, !startsBlock(lines, at: i) {
                inner.append(line)
                i += 1
            } else {
                break
            }
        }
        blocks.append(.blockquote(parseBlocks(inner)))
        return i
    }

    private static func parseList(
        _ lines: [Substring], from start: Int, first: ListMarker, into blocks: inout [MarkdownBlock]
    ) -> Int {
        var items: [MarkdownBlock.ListItem] = []
        var i = start
        var marker = first
        while true {
            var itemLines: [Substring] = [marker.content]
            var openFence = fenceOpen(marker.content, indent: 0)
            var lazyAllowed = openFence == nil && !marker.content.isEmpty
            var pendingBlanks = 0
            i += 1

            func append(_ line: Substring) {
                for _ in 0..<pendingBlanks { itemLines.append("") }
                pendingBlanks = 0
                itemLines.append(line)
                let (indent, rest) = leading(line)
                if let fence = openFence {
                    if isFenceClose(line, fence) { openFence = nil }
                    lazyAllowed = false
                } else if let fence = fenceOpen(rest, indent: indent) {
                    openFence = fence
                    lazyAllowed = false
                } else {
                    lazyAllowed = !rest.isEmpty
                }
            }

            while i < lines.count {
                let line = lines[i]
                let (indent, rest) = leading(line)
                if rest.isEmpty {
                    pendingBlanks += 1
                } else if indent >= marker.contentIndent {
                    append(strip(line, columns: marker.contentIndent))
                } else if openFence == nil, indent > marker.indent, listMarker(line) != nil, !isThematicBreak(rest) {
                    // A nested item indented less than CommonMark wants (`1. a` / `  - b`).
                    append(strip(line, columns: indent))
                } else if pendingBlanks == 0, lazyAllowed, !startsBlock(lines, at: i) {
                    append(rest)
                } else {
                    break
                }
                i += 1
            }

            items.append(makeItem(itemLines))

            guard i < lines.count, let next = listMarker(lines[i]), next.ordered == first.ordered,
                  !isThematicBreak(leading(lines[i]).rest)
            else { break }
            marker = next
        }
        blocks.append(first.ordered ? .orderedList(start: first.start, items) : .bulletList(items))
        return i
    }

    private static func makeItem(_ lines: [Substring]) -> MarkdownBlock.ListItem {
        var lines = lines
        var checked: Bool?
        let head = lines[0].utf8
        if head.count >= 3, head.first == UInt8(ascii: "[") {
            let mark = head[head.index(after: head.startIndex)]
            let close = head[head.index(head.startIndex, offsetBy: 2)]
            let afterIndex = head.index(head.startIndex, offsetBy: 3)
            let endsOrSpace = afterIndex == head.endIndex || head[afterIndex] == 32 || head[afterIndex] == 9
            if close == UInt8(ascii: "]"), endsOrSpace {
                switch mark {
                case 32: checked = false
                case UInt8(ascii: "x"), UInt8(ascii: "X"): checked = true
                default: break
                }
            }
            if checked != nil { lines[0] = leading(Substring(head[afterIndex...])).rest }
        }
        return MarkdownBlock.ListItem(checked: checked, blocks: parseBlocks(lines))
    }

    private static func parseTable(_ lines: [Substring], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        let header = splitRow(lines[start])
        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count {
            let rest = leading(lines[i]).rest
            guard !rest.isEmpty, rest.utf8.contains(UInt8(ascii: "|")) else { break }
            var row = splitRow(rest)
            if row.count < header.count {
                row.append(contentsOf: repeatElement("", count: header.count - row.count))
            } else if row.count > header.count {
                row.removeLast(row.count - header.count)
            }
            rows.append(row)
            i += 1
        }
        blocks.append(.table(header: header, rows: rows))
        return i
    }

    private static func parseParagraph(_ lines: [Substring], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var text = String(trimmed(lines[start]))
        var i = start + 1
        while i < lines.count {
            let rest = leading(lines[i]).rest
            if rest.isEmpty || startsBlock(lines, at: i) { break }
            text += "\n"
            text += trimmed(rest)
            i += 1
        }
        blocks.append(.paragraph(text))
        return i
    }

    /// Whether `lines[index]` opens a block that interrupts a paragraph (or lazy continuation).
    private static func startsBlock(_ lines: [Substring], at index: Int) -> Bool {
        let line = lines[index]
        let (indent, rest) = leading(line)
        guard let first = rest.utf8.first else { return false }
        if first == UInt8(ascii: ">") { return true }
        if fenceOpen(rest, indent: indent) != nil || heading(rest) != nil || isThematicBreak(rest) { return true }
        if let marker = listMarker(line), !marker.content.isEmpty { return true }
        return index + 1 < lines.count && isTableStart(rest, next: lines[index + 1])
    }

    // MARK: Line classification

    private struct Fence {
        let char: UInt8
        let count: Int
        let indent: Int
        let language: String?
    }

    private static func fenceOpen(_ rest: Substring, indent: Int) -> Fence? {
        let bytes = rest.utf8
        guard let char = bytes.first, char == UInt8(ascii: "`") || char == UInt8(ascii: "~") else { return nil }
        let count = bytes.prefix(while: { $0 == char }).count
        guard count >= 3 else { return nil }
        let info = trimmed(Substring(bytes.dropFirst(count)))
        if char == UInt8(ascii: "`"), info.utf8.contains(UInt8(ascii: "`")) { return nil }
        let word = info.utf8.prefix(while: { $0 != 32 && $0 != 9 && $0 != UInt8(ascii: "{") })
        let language = word.isEmpty ? nil : String(Substring(word))
        return Fence(char: char, count: count, indent: indent, language: language)
    }

    private static func isFenceClose(_ line: Substring, _ fence: Fence) -> Bool {
        let bytes = leading(line).rest.utf8
        let count = bytes.prefix(while: { $0 == fence.char }).count
        return count >= fence.count && bytes.dropFirst(count).allSatisfy { $0 == 32 || $0 == 9 }
    }

    private static func heading(_ rest: Substring) -> (level: Int, text: String)? {
        let bytes = rest.utf8
        let level = bytes.prefix(while: { $0 == UInt8(ascii: "#") }).count
        guard level >= 1, level <= 6 else { return nil }
        let after = bytes.dropFirst(level)
        if let first = after.first, first != 32, first != 9 { return nil }
        var text = trimmed(Substring(after))
        // Optional closing sequence: `## Title ##`.
        let closing = text.utf8.reversed().prefix(while: { $0 == UInt8(ascii: "#") }).count
        if closing > 0 {
            let head = text.utf8.dropLast(closing)
            if head.isEmpty || head.last == 32 || head.last == 9 { text = trimmed(Substring(head)) }
        }
        return (level, String(text))
    }

    private static func isThematicBreak(_ rest: Substring) -> Bool {
        guard let char = rest.utf8.first,
              char == UInt8(ascii: "-") || char == UInt8(ascii: "*") || char == UInt8(ascii: "_")
        else { return false }
        var count = 0
        for byte in rest.utf8 {
            if byte == char { count += 1 } else if byte != 32 && byte != 9 { return false }
        }
        return count >= 3
    }

    private struct ListMarker {
        let ordered: Bool
        let start: Int
        /// Column of the marker and column where the item's content starts.
        let indent: Int
        let contentIndent: Int
        let content: Substring
    }

    private static func listMarker(_ line: Substring) -> ListMarker? {
        let (indent, rest) = leading(line)
        let bytes = rest.utf8
        guard let first = bytes.first else { return nil }
        var width: Int
        var start = 1
        var ordered = false
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
            width = 1
        } else if first >= 48, first <= 57 {
            let digits = bytes.prefix(while: { $0 >= 48 && $0 <= 57 })
            guard digits.count <= 9 else { return nil }
            let delimiterIndex = digits.endIndex
            guard delimiterIndex < bytes.endIndex,
                  bytes[delimiterIndex] == UInt8(ascii: ".") || bytes[delimiterIndex] == UInt8(ascii: ")")
            else { return nil }
            start = digits.reduce(0) { $0 * 10 + Int($1 - 48) }
            width = digits.count + 1
            ordered = true
        } else {
            return nil
        }
        let after = bytes.dropFirst(width)
        if let next = after.first, next != 32, next != 9 { return nil }
        let content = leading(Substring(after)).rest
        let gap = after.prefix(while: { $0 == 32 || $0 == 9 }).count
        // Content starts after 1-4 spaces; more means the content itself is indented.
        let contentIndent = indent + width + (content.isEmpty || gap > 4 ? 1 : max(gap, 1))
        return ListMarker(ordered: ordered, start: start, indent: indent, contentIndent: contentIndent, content: content)
    }

    private static func isTableStart(_ rest: Substring, next: Substring) -> Bool {
        guard rest.utf8.contains(UInt8(ascii: "|")) else { return false }
        let delimiter = leading(next).rest
        guard delimiter.utf8.contains(UInt8(ascii: "|")), delimiter.utf8.contains(UInt8(ascii: "-")) else { return false }
        for byte in delimiter.utf8 {
            switch byte {
            case UInt8(ascii: "|"), UInt8(ascii: "-"), UInt8(ascii: ":"), 32, 9: continue
            default: return false
            }
        }
        // Every cell must be `:?-+:?`; a streaming partial row like `| --` still qualifies.
        return splitRow(delimiter).allSatisfy { cell in
            let core = cell.utf8.drop(while: { $0 == UInt8(ascii: ":") }).reversed().drop(while: { $0 == UInt8(ascii: ":") })
            return !core.isEmpty && core.allSatisfy { $0 == UInt8(ascii: "-") }
        }
    }

    /// Cells of a `| a | b |` row, honouring `\|` escapes.
    private static func splitRow(_ line: Substring) -> [String] {
        var row = trimmed(line)
        if row.utf8.first == UInt8(ascii: "|") { row = Substring(row.utf8.dropFirst()) }
        if row.utf8.last == UInt8(ascii: "|") {
            let beforeLast = row.utf8.dropLast().last
            if beforeLast != UInt8(ascii: "\\") { row = Substring(row.utf8.dropLast()) }
        }
        var cells: [String] = []
        var cellStart = row.utf8.startIndex
        var escaped = false
        var hasEscape = false
        var index = row.utf8.startIndex
        func finish(_ end: String.Index) {
            var cell = String(trimmed(Substring(row.utf8[cellStart..<end])))
            if hasEscape { cell = cell.replacingOccurrences(of: "\\|", with: "|") }
            cells.append(cell)
        }
        while index < row.utf8.endIndex {
            let byte = row.utf8[index]
            if escaped {
                escaped = false
                if byte == UInt8(ascii: "|") { hasEscape = true }
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "|") {
                finish(index)
                cellStart = row.utf8.index(after: index)
                hasEscape = false
            }
            index = row.utf8.index(after: index)
        }
        finish(row.utf8.endIndex)
        return cells
    }

    // MARK: Whitespace

    /// Leading whitespace width in columns (tabs to the next multiple of 4) and the rest of the line.
    /// For a blank line `rest` is empty.
    private static func leading(_ line: Substring) -> (indent: Int, rest: Substring) {
        var columns = 0
        var index = line.utf8.startIndex
        while index < line.utf8.endIndex {
            let byte = line.utf8[index]
            if byte == 32 {
                columns += 1
            } else if byte == 9 {
                columns += 4 - columns % 4
            } else {
                break
            }
            index = line.utf8.index(after: index)
        }
        return (columns, Substring(line.utf8[index...]))
    }

    /// Removes up to `columns` columns of leading whitespace.
    private static func strip(_ line: Substring, columns: Int) -> Substring {
        var removed = 0
        var index = line.utf8.startIndex
        while removed < columns, index < line.utf8.endIndex {
            let byte = line.utf8[index]
            if byte == 32 {
                removed += 1
            } else if byte == 9 {
                removed += 4 - removed % 4
            } else {
                break
            }
            index = line.utf8.index(after: index)
        }
        return Substring(line.utf8[index...])
    }

    private static func trimmed(_ text: Substring) -> Substring {
        let bytes = text.utf8
        let start = bytes.firstIndex(where: { $0 != 32 && $0 != 9 }) ?? bytes.endIndex
        guard start < bytes.endIndex else { return Substring(bytes[start..<start]) }
        var end = bytes.endIndex
        while end > start {
            let before = bytes.index(before: end)
            if bytes[before] != 32 && bytes[before] != 9 { break }
            end = before
        }
        return Substring(bytes[start..<end])
    }
}
