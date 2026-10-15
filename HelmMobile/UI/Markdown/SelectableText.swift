import SwiftUI
import UIKit

/// Text the reader can select part of, the way iOS does it elsewhere: long-press and drag the
/// handles, or click and drag with a pointer on iPad. SwiftUI's `.textSelection` on iOS only copies
/// a whole `Text`, so messages draw through a non-editable UITextView instead.
struct SelectableTextView: UIViewRepresentable {
    let text: NSAttributedString
    /// Wraps to the offered width; false keeps lines whole (code that scrolls sideways).
    var wraps = true
    var linkColor: Color?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if !wraps {
            view.textContainer.widthTracksTextView = false
            view.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if let linkColor { view.linkTextAttributes = [.foregroundColor: UIColor(linkColor)] }
        if !view.attributedText.isEqual(to: text) { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let limit = wraps ? (proposal.width ?? .greatestFiniteMagnitude) : .greatestFiniteMagnitude
        let cache = context.coordinator
        if cache.text === text, cache.limit == limit, let size = cache.size { return size }
        // The width the text needs, so a short message's bubble hugs it; the height from the
        // text view itself at that width, so its own layout never wraps a line more.
        let needed = text.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let width = min(ceil(needed.width) + 1, limit)
        let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let size = CGSize(width: width, height: ceil(height))
        (cache.text, cache.limit, cache.size) = (text, limit, size)
        return size
    }

    func makeCoordinator() -> SizeCache { SizeCache() }

    final class SizeCache {
        var text: NSAttributedString?
        var limit: CGFloat = 0
        var size: CGSize?
    }
}

/// Markdown blocks as one attributed string, so a selection can run across paragraphs and lists.
/// Code blocks, tables and quotes at the top level stay their own views (see `MarkdownView`).
enum MarkdownText {
    struct Style: Equatable {
        var text: Color
        var muted: Color
        var link: Color
        var inlineCode: Color
        var code: Color
        var codeText: Color

        @MainActor static var current: Style {
            Style(text: Palette.text, muted: Palette.textMuted, link: Palette.accentText,
                  inlineCode: Palette.border, code: Palette.code, codeText: Palette.codeText)
        }
    }

    static func font(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle, _ typeSize: DynamicTypeSize) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }

    /// Plain text in the body font: the user's own messages.
    static func plain(_ text: String, color: Color, typeSize: DynamicTypeSize) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: font("IBMPlexSans-Regular", 17, .body, typeSize),
            .foregroundColor: UIColor(color),
            .paragraphStyle: paragraph,
        ])
    }

    static func attributed(_ blocks: [MarkdownBlock], style: Style, typeSize: DynamicTypeSize,
                           color: Color? = nil) -> NSAttributedString {
        var builder = Builder(style: style, typeSize: typeSize)
        builder.append(blocks, indent: 0, depth: 0, color: UIColor(color ?? style.text), between: 10, after: 0)
        let out = builder.out
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    private struct Builder {
        let style: Style
        let typeSize: DynamicTypeSize
        let out = NSMutableAttributedString()
        let body: UIFont
        let strong: UIFont
        let mono: UIFont

        init(style: Style, typeSize: DynamicTypeSize) {
            self.style = style
            self.typeSize = typeSize
            body = MarkdownText.font("IBMPlexSans-Regular", 17, .body, typeSize)
            strong = MarkdownText.font("IBMPlexSans-SemiBold", 17, .body, typeSize)
            mono = MarkdownText.font("IBMPlexMono-Regular", 15, .body, typeSize)
        }

        mutating func append(_ blocks: [MarkdownBlock], indent: CGFloat, depth: Int, color: UIColor,
                             between: CGFloat, after: CGFloat) {
            for (index, block) in blocks.enumerated() {
                let spacing = index == blocks.count - 1 ? after : between
                append(block, indent: indent, depth: depth, color: color, after: spacing, isFirst: out.length == 0)
            }
        }

        private mutating func append(_ block: MarkdownBlock, indent: CGFloat, depth: Int, color: UIColor,
                                     after: CGFloat, isFirst: Bool) {
            switch block {
            case let .heading(level, text):
                let size: CGFloat = level == 1 ? 22 : level == 2 ? 19 : 17
                let font = MarkdownText.font("IBMPlexSans-SemiBold", size, level <= 2 ? .title3 : .headline, typeSize)
                let line = inline(text, font: font, strong: font, color: color)
                paragraph(line, indent: indent, after: after, before: isFirst ? 0 : 4)
            case let .paragraph(text):
                paragraph(inline(text, font: body, strong: strong, color: color), indent: indent, after: after)
            case let .codeBlock(_, code):
                let line = NSMutableAttributedString(string: code.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
                    .font: MarkdownText.font("IBMPlexMono-Regular", 13, .footnote, typeSize),
                    .foregroundColor: UIColor(style.codeText),
                    .backgroundColor: UIColor(style.code),
                ])
                paragraph(line, indent: indent, after: after)
            case let .bulletList(items):
                list(items, start: nil, indent: indent, depth: depth, color: color, after: after)
            case let .orderedList(start, items):
                list(items, start: start, indent: indent, depth: depth, color: color, after: after)
            case let .blockquote(blocks):
                append(blocks, indent: indent + 13, depth: depth, color: UIColor(style.muted), between: 8, after: after)
            case let .table(header, rows):
                let text = ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\u{2028}")
                paragraph(inline(text, font: body, strong: strong, color: color), indent: indent, after: after)
            case .thematicBreak:
                break
            }
        }

        private mutating func list(_ items: [MarkdownBlock.ListItem], start: Int?, indent: CGFloat, depth: Int,
                                   color: UIColor, after: CGFloat) {
            let muted = UIColor(style.muted)
            // The widest number reserves the column, so labels align on their trailing edge.
            let numberWidth = start.map { ceil(("\($0 + items.count - 1)." as NSString).size(withAttributes: [.font: body]).width) }
            for (index, item) in items.enumerated() {
                let itemAfter = index == items.count - 1 ? after : 6
                let marker = NSMutableAttributedString()
                let textIndent: CGFloat
                var tabs: [NSTextTab] = []
                if let checked = item.checked {
                    let symbol = UIImage(systemName: checked ? "checkmark.square.fill" : "square",
                                         withConfiguration: UIImage.SymbolConfiguration(font: body.withSize(15)))?
                        .withTintColor(checked ? UIColor(style.link) : muted, renderingMode: .alwaysOriginal)
                    if let symbol { marker.append(NSAttributedString(attachment: NSTextAttachment(image: symbol))) }
                    textIndent = indent + 26
                } else if let start, let numberWidth {
                    marker.append(NSAttributedString(string: "\t\(start + index).", attributes: [.font: body, .foregroundColor: muted]))
                    tabs.append(NSTextTab(textAlignment: .right, location: indent + numberWidth))
                    textIndent = indent + numberWidth + 8
                } else {
                    let bullet = depth == 0 ? "•" : depth == 1 ? "◦" : "▪"
                    marker.append(NSAttributedString(string: bullet, attributes: [.font: body, .foregroundColor: muted]))
                    textIndent = indent + 20
                }
                marker.append(NSAttributedString(string: "\t", attributes: [.font: body]))
                tabs.append(NSTextTab(textAlignment: .left, location: textIndent))

                var rest = item.blocks[...]
                if case let .paragraph(text)? = rest.first {
                    rest = rest.dropFirst()
                    marker.append(inline(text, font: body, strong: strong, color: color))
                }
                paragraph(marker, indent: textIndent, firstIndent: indent, tabs: tabs, after: rest.isEmpty ? itemAfter : 6)
                if !rest.isEmpty {
                    append(Array(rest), indent: textIndent, depth: depth + 1, color: color, between: 6, after: itemAfter)
                }
            }
        }

        private func paragraph(_ line: NSMutableAttributedString, indent: CGFloat, firstIndent: CGFloat? = nil,
                               tabs: [NSTextTab] = [], after: CGFloat, before: CGFloat = 0) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.headIndent = indent
            style.firstLineHeadIndent = firstIndent ?? indent
            style.tabStops = tabs
            style.defaultTabInterval = 28
            style.paragraphSpacing = after
            style.paragraphSpacingBefore = before
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
            out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style]))
        }

        /// Inline Markdown (emphasis, code spans, links). Line breaks inside a paragraph become line
        /// separators, so they don't pick up the spacing between paragraphs.
        private func inline(_ source: String, font: UIFont, strong: UIFont, color: UIColor) -> NSMutableAttributedString {
            let options = AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
            let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
            let out = NSMutableAttributedString()
            let code = mono.withSize(font.pointSize - 2)
            for run in parsed.runs {
                let text = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) {
                        attributes[.font] = code
                        attributes[.backgroundColor] = UIColor(style.inlineCode)
                    } else if intent.contains(.stronglyEmphasized) {
                        attributes[.font] = strong
                    }
                    if intent.contains(.emphasized) { attributes[.obliqueness] = 0.18 }
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
                if let link = run.link { attributes[.link] = link }
                out.append(NSAttributedString(string: text, attributes: attributes))
            }
            return out
        }
    }
}
