import Foundation

/// What Copy puts on the clipboard for a message.
enum ClipboardText {
    /// The message as Markdown a reader can use anywhere: a `t3-context://` chip becomes a link
    /// to its pull request when the record has one, otherwise its label. Ordinary links stay.
    static func markdown(_ text: String, context: JSON? = nil) -> String {
        guard text.contains("t3-context://") else { return text }
        var records: [String: JSON] = [:]
        for record in context?["records"]?.array ?? [] {
            if let id = record["contextId"]?.string { records[id] = record }
        }
        var result = text
        for (range, link) in QueuedEdit.links(in: text).reversed() {
            let record = records[link.contextId]
            let label = record?["label"]?.string ?? labelOf(link.source)
            if let url = record?["pullRequest"]?["url"]?.string, !url.isEmpty {
                let title = record?["pullRequest"]?["title"]?.string
                let shown = title.map { "\(label) \(ContextReference.label($0, kind: link.kind))" } ?? label
                result.replaceSubrange(range, with: "[\(shown)](\(url))")
            } else {
                result.replaceSubrange(range, with: label)
            }
        }
        return result
    }

    /// The message as plain text, Markdown markup removed: lists keep a bullet or number,
    /// code keeps its lines, tables become tab-separated rows.
    static func plain(_ markdown: String) -> String {
        render(MarkdownParser.parse(markdown), indent: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ blocks: [MarkdownBlock], indent: String) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text):
                return indented(inline(text), indent)
            case .codeBlock(_, let code):
                return indented(code, indent)
            case .bulletList(let items):
                return items.map { item(prefix: item(checked: $0.checked) ?? "•", $0, indent: indent) }.joined(separator: "\n")
            case .orderedList(let start, let items):
                return items.enumerated().map { offset, entry in
                    item(prefix: item(checked: entry.checked) ?? "\(start + offset).", entry, indent: indent)
                }.joined(separator: "\n")
            case .blockquote(let inner):
                return render(inner, indent: indent)
            case .table(let header, let rows):
                return ([header] + rows).map { $0.map(inline).joined(separator: "\t") }.map { indent + $0 }.joined(separator: "\n")
            case .thematicBreak:
                return indent + "———"
            }
        }.joined(separator: "\n\n")
    }

    private static func item(checked: Bool?) -> String? {
        checked.map { $0 ? "☑︎" : "☐" }
    }

    private static func item(prefix: String, _ item: MarkdownBlock.ListItem, indent: String) -> String {
        let body = render(item.blocks, indent: indent + "   ")
            .replacingOccurrences(of: "\n\n", with: "\n")
        let trimmed = body.hasPrefix(indent + "   ") ? String(body.dropFirst(indent.count + 3)) : body
        return "\(indent)\(prefix) \(trimmed)"
    }

    private static func indented(_ text: String, _ indent: String) -> String {
        indent.isEmpty ? text : text.split(separator: "\n", omittingEmptySubsequences: false).map { indent + $0 }.joined(separator: "\n")
    }

    /// Emphasis, code spans and links reduced to their text.
    private static func inline(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: ContextReference.displayText(text), options: options) else { return text }
        return String(attributed.characters)
    }

    private static func labelOf(_ source: String) -> String {
        guard let open = source.firstIndex(of: "["), let close = source.firstIndex(of: "]") else { return source }
        return String(source[source.index(after: open)..<close])
    }
}
