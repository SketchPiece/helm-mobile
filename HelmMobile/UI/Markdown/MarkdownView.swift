import SwiftUI
import UIKit

/// Renders an assistant message. Parsing happens once per `MarkdownView` value, and every segment
/// is an equatable view, so a streaming update only re-renders the segments whose text changed.
/// Prose (paragraphs, headings, lists) runs together as one selectable text, so a selection can
/// cross paragraphs; code blocks, tables, quotes and rules are their own views.
struct MarkdownView: View {
    let text: String
    private let segments: [MarkdownSegment]

    init(text: String) {
        self.text = text
        self.segments = Perf.measure("markdown.parse", units: text.utf8.count) {
            MarkdownSegment.split(MarkdownParser.parse(text))
        }
    }

    var body: some View {
        let style = MarkdownText.Style.current
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MarkdownSegmentView(segment: segment, style: style)
                    .equatable()
            }
        }
        .font(Typography.body)
        .foregroundStyle(Palette.text)
        .selectableText()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MarkdownSegment: Hashable {
    case prose([MarkdownBlock])
    case quote([MarkdownBlock])
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case rule

    static func split(_ blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var prose: [MarkdownBlock] = []
        func flush() {
            if !prose.isEmpty { segments.append(.prose(prose)) }
            prose.removeAll()
        }
        for block in blocks {
            switch block {
            case let .codeBlock(language, code): flush(); segments.append(.code(language: language, code: code))
            case let .table(header, rows): flush(); segments.append(.table(header: header, rows: rows))
            case let .blockquote(inner): flush(); segments.append(.quote(inner))
            case .thematicBreak: flush(); segments.append(.rule)
            default: prose.append(block)
            }
        }
        flush()
        return segments
    }
}

private struct MarkdownSegmentView: View, Equatable {
    let segment: MarkdownSegment
    let style: MarkdownText.Style
    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func == (a: Self, b: Self) -> Bool { a.segment == b.segment && a.style == b.style }

    var body: some View {
        switch segment {
        case let .prose(blocks):
            SelectableTextView(text: MarkdownText.attributed(blocks, style: style, typeSize: typeSize), linkColor: style.link)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .quote(blocks):
            SelectableTextView(text: MarkdownText.attributed(blocks, style: style, typeSize: typeSize, color: style.muted),
                               linkColor: style.link)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 13)
                .background(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.border).frame(width: 3)
                }
        case let .code(language, code):
            MarkdownCodeBlock(language: language, code: code)
        case let .table(header, rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Rectangle()
                .fill(Palette.border)
                .frame(height: 1)
                .padding(.vertical, 6)
        }
    }
}

// MARK: Inline

enum MarkdownInline {
    /// Inline Markdown (emphasis, code spans, links) with Helm's fonts. Falls back to the raw
    /// text when Foundation rejects the source.
    static func render(_ source: String, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var string = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }
        let strongFont = Typography.sans(size, .semibold)
        let codeFont = Typography.mono(size - 2, relativeTo: .body)
        var styled: [(Range<AttributedString.Index>, InlinePresentationIntent?, Bool)] = []
        for run in string.runs {
            let intent = run.inlinePresentationIntent
            if intent != nil || run.link != nil { styled.append((run.range, intent, run.link != nil)) }
        }
        for (range, intent, isLink) in styled {
            if let intent {
                if intent.contains(.code) {
                    string[range].font = codeFont
                    string[range].backgroundColor = Palette.border
                } else if intent.contains(.stronglyEmphasized), weight == .regular {
                    string[range].font = strongFont
                }
                // Fonts are set explicitly above; leave only the intents SwiftUI must still apply.
                let remaining = intent.subtracting([.code, .stronglyEmphasized])
                string[range].inlinePresentationIntent = remaining.isEmpty ? nil : remaining
            }
            if isLink { string[range].foregroundColor = Palette.accentText }
        }
        return string
    }
}

// MARK: Code

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String
    @Environment(\.codeAppearance) private var appearance
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                if let language {
                    Text(language)
                        .font(Typography.mono(12, relativeTo: .caption))
                        .foregroundStyle(Palette.codeText.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.codeText.opacity(copied ? 0.9 : 0.6))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            if appearance.wordWrap {
                SelectableTextView(text: codeText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    SelectableTextView(text: codeText, wraps: false)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var codeText: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let font = appearance.fontSize.flatMap { UIFont(name: "IBMPlexMono-Regular", size: $0) }
            ?? MarkdownText.font("IBMPlexMono-Regular", PhonePreferences.defaultCodeFontSize, .footnote, typeSize)
        return NSAttributedString(string: code, attributes: [
            .font: font, .foregroundColor: UIColor(Palette.codeText), .paragraphStyle: paragraph,
        ])
    }
}

// MARK: Tables

private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        self.cell(cell, weight: .semibold)
                    }
                }
                separator
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            self.cell(cell, weight: .regular)
                        }
                    }
                    if index < rows.count - 1 { separator }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.border, lineWidth: 1)
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    private func cell(_ text: String, weight: Font.Weight) -> some View {
        CappedWidthLayout(maxWidth: 260) {
            Text(MarkdownInline.render(text, size: 15, weight: weight))
                .font(Typography.sans(15, weight, relativeTo: .subheadline))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// Sizes its child to its natural width up to `maxWidth`, wrapping beyond that. A horizontal
/// scroll view proposes no width, so a plain `frame(maxWidth:)` would leave long cells on one line.
private struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, maxWidth)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
