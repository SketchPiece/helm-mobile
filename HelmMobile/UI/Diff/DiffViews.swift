import SwiftUI

enum DiffPalette {
    static let addedText = Palette.dynamic(light: 0x3E7A2E, dark: 0x8FC56A)
    static let addedBackground = Color(hex: 0x5FA346).opacity(0.18)
    static let deletedBackground = Palette.error.opacity(0.18)
}

// MARK: - File list

/// The files changed by a turn. Tapping a row pushes that file's diff.
struct DiffFileList: View {
    let files: [DiffFile]

    var body: some View {
        List(files) { file in
            NavigationLink {
                DiffFileView(file: file)
            } label: {
                DiffFileRow(file: file)
            }
            .accessibilityIdentifier("diffFile")
            .listRowBackground(Palette.surface)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("No file changes", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}

private struct DiffFileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.status.symbol)
                .foregroundStyle(file.status.tint)
                .font(.system(size: 17))
                .accessibilityLabel(file.status.label)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.fileName)
                    .font(Typography.sans(15, .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if file.additions > 0 || file.deletions == 0 {
                    Text(verbatim: "+\(file.additions)").foregroundStyle(DiffPalette.addedText)
                }
                if file.deletions > 0 {
                    Text(verbatim: "\u{2212}\(file.deletions)").foregroundStyle(Palette.errorText)
                }
            }
            .font(Typography.mono(12))
            .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// Directory, or where a renamed file came from.
    private var subtitle: String? {
        if file.status == .renamed, let oldPath = file.oldPath {
            return "from \(oldPath)"
        }
        return file.directory.isEmpty ? nil : file.directory
    }
}

private extension DiffFile.Status {
    var symbol: String {
        switch self {
        case .added: "plus.circle"
        case .deleted: "minus.circle"
        case .modified: "pencil.circle"
        case .renamed: "arrow.right.circle"
        case .binary: "doc.circle"
        }
    }

    var tint: Color {
        switch self {
        case .added: DiffPalette.addedText
        case .deleted: Palette.errorText
        case .modified: Palette.accentText
        case .renamed, .binary: Palette.textMuted
        }
    }

    var label: String {
        switch self {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .binary: "Binary"
        }
    }
}

// MARK: - File diff

/// One file's hunks. Long lines wrap unless Settings → Code and diffs turns that off; then the
/// whole file pans horizontally as one block so lines stay aligned. Rows are lazy so a 20k-line
/// file only builds what is on screen. A new file reads as a document: no hunk header, markers
/// or tint, and Markdown is shown formatted with a toolbar switch to its source.
struct DiffFileView: View {
    let file: DiffFile

    // IBM Plex Mono advances 0.6em, so 12pt is 7.2pt per column; scales with Dynamic Type
    // unless Settings → Code and diffs fixes the size.
    @ScaledMetric(relativeTo: .footnote) private var scaledColumnWidth: CGFloat = 7.2
    @ScaledMetric(relativeTo: .footnote) private var scaledRowHeight: CGFloat = 18
    @Environment(\.codeAppearance) private var appearance
    @State private var showsSource = false

    private var columnWidth: CGFloat { appearance.fontSize.map { $0 * 0.6 } ?? scaledColumnWidth }
    private var rowHeight: CGFloat { appearance.fontSize.map { $0 * 1.5 } ?? scaledRowHeight }
    private var font: Font { appearance.font(automatic: 12) }
    private var wraps: Bool { appearance.diffWordWrap }

    /// Every line is new, so there is nothing to compare against.
    private var isDocument: Bool { file.status == .added }

    private var isMarkdown: Bool {
        let ext = (file.fileName as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }

    private var showsFormatted: Bool { isDocument && isMarkdown && !showsSource }

    var body: some View {
        Group {
            if file.status == .binary {
                ContentUnavailableView("Binary file not shown", systemImage: "doc")
            } else if file.hunks.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "doc.text")
            } else if showsFormatted {
                formatted
            } else {
                lines
            }
        }
        .background(Palette.canvas)
        .navigationTitle(file.fileName)
        .navigationSubtitle(navigationSubtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isDocument && isMarkdown && !file.hunks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSource.toggle()
                    } label: {
                        Image(systemName: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel(showsSource ? "Show formatted" : "Show source")
                    .accessibilityIdentifier("diffSourceToggle")
                }
            }
        }
    }

    private var formatted: some View {
        ScrollView {
            MarkdownView(text: documentText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
    }

    private var documentText: String {
        file.hunks.flatMap(\.lines).filter { $0.kind != .noNewline }.map(\.text).joined(separator: "\n")
    }

    private var lines: some View {
        GeometryReader { proxy in
            ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks.indices, id: \.self) { hunkIndex in
                        let hunk = file.hunks[hunkIndex]
                        if !isDocument {
                            DiffHunkHeader(header: hunk.header, height: rowHeight, font: font, wraps: wraps)
                        }
                        ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                            DiffLineRow(
                                line: hunk.lines[lineIndex],
                                gutterWidth: gutterWidth,
                                height: rowHeight,
                                font: font,
                                wraps: wraps,
                                plain: isDocument
                            )
                        }
                    }
                }
                .padding(.top, isDocument ? 8 : 0)
                .frame(width: wraps ? proxy.size.width : max(proxy.size.width, contentWidth), alignment: .leading)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }

    private var emptyTitle: String {
        switch file.status {
        case .renamed: "Renamed without changes"
        case .added: "Empty file"
        default: "No content changes"
        }
    }

    private var navigationSubtitle: String {
        if file.status == .renamed, let oldPath = file.oldPath {
            return "\(oldPath) \u{2192} \(file.displayPath)"
        }
        return file.directory
    }

    /// Width of one line-number column, sized to the largest number in the file.
    private var gutterWidth: CGFloat {
        let largest = file.hunks.last.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) } ?? 1
        return CGFloat(String(largest).count) * columnWidth + 12
    }

    private var contentWidth: CGFloat {
        // Two gutters, the marker column, then the text.
        gutterWidth * 2 + columnWidth * CGFloat(file.widestLine + 2) + 24
    }
}

private struct DiffHunkHeader: View {
    let header: String
    let height: CGFloat
    let font: Font
    let wraps: Bool

    var body: some View {
        Text(verbatim: header)
            .font(font)
            .foregroundStyle(Palette.textMuted)
            .lineLimit(1)
            .fixedSize(horizontal: !wraps, vertical: false)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height + 10, alignment: .leading)
            .background(Palette.surface)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let gutterWidth: CGFloat
    let height: CGFloat
    let font: Font
    let wraps: Bool
    /// A new file's line: one gutter, no marker or tint.
    let plain: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if !plain {
                lineNumber(line.oldNumber)
            }
            lineNumber(line.newNumber)
            Text(verbatim: plain ? "" : marker)
                .foregroundStyle(markerColor)
                .frame(width: plain ? 8 : 16)
            Text(verbatim: displayText)
                .foregroundStyle(line.kind == .noNewline ? Palette.textMuted : Palette.text)
                .italic(line.kind == .noNewline)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
                .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
                .padding(.trailing, 12)
        }
        .font(font)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
        .background(plain ? .clear : background)
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(verbatim: number.map(String.init) ?? "")
            .foregroundStyle(Palette.textMuted)
            .monospacedDigit()
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var displayText: String {
        line.text.contains("\t") ? line.text.replacingOccurrences(of: "\t", with: "    ") : line.text
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "\u{2212}"
        case .context, .noNewline: ""
        }
    }

    private var markerColor: Color {
        line.kind == .addition ? DiffPalette.addedText : Palette.errorText
    }

    private var background: Color {
        switch line.kind {
        case .addition: DiffPalette.addedBackground
        case .deletion: DiffPalette.deletedBackground
        case .context, .noNewline: .clear
        }
    }
}
