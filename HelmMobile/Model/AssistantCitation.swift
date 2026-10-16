import Foundation

/// A piece of an agent's answer quoted in a later message. The Mac writes it into the message as
/// `[Assistant quote](t3-citation://v1/<env>/<thread>/<message>?text=…&start=…&comment=…)`
/// (`packages/shared/src/assistantCitations.ts`) and draws it as a chip.
struct AssistantCitation: Hashable, Sendable {
    var environmentId: String
    var threadId: String
    var messageId: String
    var text: String
    var comment: String?

    static let scheme = "t3-citation"

    /// What the chip says: the comment if there is one, else the quote, on one line.
    var label: String {
        let source = comment.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? text
        let preview = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return preview.count > 64 ? "\(preview.prefix(64))…" : preview
    }

    /// The quote as plain text, with the comment under it (copying a message).
    var plainText: String { comment.map { "\(text)\nComment: \($0)" } ?? text }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host(percentEncoded: true) == "v1" else { return nil }
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.count == 3 else { return nil }
        let ids = parts.compactMap { $0.removingPercentEncoding }
        guard ids.count == 3, !ids.contains(where: \.isEmpty) else { return nil }
        // URLSearchParams writes spaces as "+", which URLComponents leaves alone.
        var query: [String: String] = [:]
        for pair in (url.query(percentEncoded: true) ?? "").split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (part: Substring) in part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
            guard field.count == 2, let key = decode(field[0]), let value = decode(field[1]) else { return nil }
            query[key] = value
        }
        guard let text = query["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        (environmentId, threadId, messageId) = (ids[0], ids[1], ids[2])
        self.text = text
        comment = query["comment"]
    }

    /// The quotes in a message's text, in order, with the Markdown link each one is written as.
    static func matches(in text: String) -> [(range: Range<String.Index>, citation: AssistantCitation, url: URL)] {
        guard text.contains("](\(scheme)://") else { return [] }
        return text.matches(of: /\[Assistant quote\]\((t3-citation:\/\/v1\/[^\s)]+)\)/).compactMap { match in
            guard let url = URL(string: String(match.1)), let citation = AssistantCitation(url: url) else { return nil }
            return (match.range, citation, url)
        }
    }

    /// Text with each quote replaced by what `replacement` makes of it.
    static func replacing(in text: String, with replacement: (AssistantCitation) -> String) -> String {
        var result = text
        for match in matches(in: text).reversed() { result.replaceSubrange(match.range, with: replacement(match.citation)) }
        return result
    }
}
