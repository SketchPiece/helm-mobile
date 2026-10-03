import SwiftUI
import UIKit

/// Renders an assistant message. Parsing happens once per `MarkdownView` value, and every block
/// is an equatable view, so a streaming update only re-renders the blocks whose text changed.
struct MarkdownView: View {
    let text: String
    private let blocks: [MarkdownBlock]

    init(text: String) {
        self.text = text
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks, depth: 0, spacing: 10)
            .font(Typography.body)
            .foregroundStyle(Palette.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    /// List nesting depth, which picks the bullet glyph.
    let depth: Int
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(block: block, depth: depth, isFirst: index == 0)
                    .equatable()
            }
        }
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    let depth: Int
    let isFirst: Bool

    var body: some View {
        switch block {
        case let .heading(level, text):
            let size: CGFloat = level == 1 ? 22 : level == 2 ? 19 : 17
            Text(MarkdownInline.render(text, size: size, weight: .semibold))
                .font(Typography.sans(size, .semibold, relativeTo: level <= 2 ? .title3 : .headline))
                .padding(.top, isFirst ? 0 : 4)
                .accessibilityAddTraits(.isHeader)
        case let .paragraph(text):
            Text(MarkdownInline.render(text, size: 17))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case let .codeBlock(language, code):
            MarkdownCodeBlock(language: language, code: code)
        case let .bulletList(items):
            MarkdownList(items: items, start: nil, depth: depth)
        case let .orderedList(start, items):
            MarkdownList(items: items, start: start, depth: depth)
        case let .blockquote(blocks):
            MarkdownBlocksView(blocks: blocks, depth: depth, spacing: 8)
                .foregroundStyle(Palette.textMuted)
                .padding(.leading, 13)
                .background(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.border).frame(width: 3)
                }
        case let .table(header, rows):
            MarkdownTable(header: header, rows: rows)
        case .thematicBreak:
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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(Typography.code)
                    .foregroundStyle(Palette.codeText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: true, vertical: true)
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
}

// MARK: Lists

private struct MarkdownList: View {
    let items: [MarkdownBlock.ListItem]
    /// `nil` for a bullet list.
    let start: Int?
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(for: item, at: index)
                    MarkdownBlocksView(blocks: item.blocks, depth: depth + 1, spacing: 6)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownBlock.ListItem, at index: Int) -> some View {
        if let checked = item.checked {
            Text(Image(systemName: checked ? "checkmark.square.fill" : "square"))
                .font(.system(size: 15))
                .foregroundStyle(checked ? Palette.accentText : Palette.textMuted)
                .frame(minWidth: 18)
        } else if let start {
            // The widest number reserves the column, so labels align on their trailing edge.
            ZStack(alignment: .trailing) {
                Text(verbatim: "\(start + items.count - 1).").hidden()
                Text(verbatim: "\(start + index).")
            }
            .monospacedDigit()
            .foregroundStyle(Palette.textMuted)
        } else {
            Text(verbatim: depth == 0 ? "•" : depth == 1 ? "◦" : "▪")
                .foregroundStyle(Palette.textMuted)
                .frame(width: 12)
        }
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
