import Foundation

/// One line inside a hunk. `text` is the line without its leading marker (" ", "+", "-", "\").
struct DiffLine: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case context
        case addition
        case deletion
        /// The "\ No newline at end of file" marker; applies to the line right before it.
        case noNewline
    }

    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

struct DiffHunk: Hashable, Sendable {
    /// The full "@@ -a,b +c,d @@ section" line.
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    var lines: [DiffLine]
}

struct DiffFile: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case added
        case deleted
        case modified
        case renamed
        case binary
    }

    /// Stable across re-parses of the same diff: the display path, suffixed if it repeats.
    let id: String
    /// Nil when the file did not exist before (added).
    let oldPath: String?
    /// Nil when the file no longer exists (deleted).
    let newPath: String?
    let displayPath: String
    let status: Status
    let additions: Int
    let deletions: Int
    let hunks: [DiffHunk]
    /// Widest line in display columns (tabs count as 4), so a viewer can size its content once.
    let widestLine: Int

    var fileName: String {
        guard let slash = displayPath.lastIndex(of: "/") else { return displayPath }
        return String(displayPath[displayPath.index(after: slash)...])
    }

    /// Parent directory of `displayPath`, empty for files at the root.
    var directory: String {
        guard let slash = displayPath.lastIndex(of: "/") else { return "" }
        return String(displayPath[..<slash])
    }
}

/// Parses `git diff` output (and plain `diff -u` output) into files, hunks and numbered lines.
/// Single pass over the input; hunk line counts decide where a hunk ends, so content lines that
/// look like headers ("--- foo" as a deleted "-- foo") are never misread.
enum UnifiedDiff {
    static func parse(_ diff: String) -> [DiffFile] {
        var parser = Parser()
        // Split on bytes: as Characters, "\r\n" is one grapheme and would never match "\n".
        for raw in diff.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            let trimmed = raw.last == UInt8(ascii: "\r") ? raw.dropLast() : raw
            parser.consume(Substring(trimmed))
        }
        return parser.finish()
    }
}

// MARK: - Parser

private struct FileBuilder {
    var oldPath: String?
    var newPath: String?
    var oldIsNull = false
    var newIsNull = false
    var isNew = false
    var isDeleted = false
    var renameFrom: String?
    var renameTo: String?
    var copyFrom: String?
    var copyTo: String?
    var isBinary = false
    var sawMinusHeader = false
    var hunks: [DiffHunk] = []
    var additions = 0
    var deletions = 0
    var widestLine = 0
}

private struct Parser {
    private var files: [DiffFile] = []
    private var usedIds: Set<String> = []
    private var file: FileBuilder?

    // Current hunk state. `hunkHeader != nil` means a hunk is open.
    private var hunkHeader: (header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)?
    private var hunkLines: [DiffLine] = []
    private var oldLine = 0
    private var newLine = 0
    private var oldRemaining = 0
    private var newRemaining = 0

    mutating func consume(_ line: Substring) {
        if hunkHeader != nil, consumeHunkLine(line) { return }
        consumeHeaderLine(line)
    }

    mutating func finish() -> [DiffFile] {
        finishFile()
        return files
    }

    /// Returns false when the line does not belong to the open hunk (the hunk is closed then).
    private mutating func consumeHunkLine(_ line: Substring) -> Bool {
        let first = line.utf8.first
        if first == UInt8(ascii: "\\") {
            let text = line.dropFirst().drop(while: { $0 == " " })
            hunkLines.append(DiffLine(kind: .noNewline, oldNumber: nil, newNumber: nil, text: String(text)))
            return true
        }
        if oldRemaining > 0 || newRemaining > 0 {
            switch first {
            case UInt8(ascii: " "), nil:
                // An empty line is a context line whose trailing space was stripped by some tool.
                appendLine(.context, old: oldLine, new: newLine, text: line.dropFirst())
                oldLine += 1
                newLine += 1
                oldRemaining = max(0, oldRemaining - 1)
                newRemaining = max(0, newRemaining - 1)
                return true
            case UInt8(ascii: "+"):
                appendLine(.addition, old: nil, new: newLine, text: line.dropFirst())
                newLine += 1
                newRemaining = max(0, newRemaining - 1)
                file?.additions += 1
                return true
            case UInt8(ascii: "-"):
                appendLine(.deletion, old: oldLine, new: nil, text: line.dropFirst())
                oldLine += 1
                oldRemaining = max(0, oldRemaining - 1)
                file?.deletions += 1
                return true
            default:
                break
            }
        }
        closeHunk()
        return false
    }

    private mutating func appendLine(_ kind: DiffLine.Kind, old: Int?, new: Int?, text: Substring) {
        var columns = 0
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\t") {
                columns += 4
            } else if byte & 0xC0 != 0x80 {
                columns += 1
            }
        }
        if columns > (file?.widestLine ?? 0) { file?.widestLine = columns }
        hunkLines.append(DiffLine(kind: kind, oldNumber: old, newNumber: new, text: String(text)))
    }

    private mutating func consumeHeaderLine(_ line: Substring) {
        if line.hasPrefix("diff --git ") {
            finishFile()
            var builder = FileBuilder()
            if let paths = Self.gitHeaderPaths(line.dropFirst("diff --git ".count)) {
                builder.oldPath = paths.old
                builder.newPath = paths.new
            }
            file = builder
            return
        }
        if line.hasPrefix("@@ ") {
            guard let range = Self.hunkRange(line) else { return }
            if file == nil { file = FileBuilder() }
            hunkHeader = (String(line), range.oldStart, range.oldCount, range.newStart, range.newCount)
            hunkLines = []
            oldLine = range.oldStart
            newLine = range.newStart
            oldRemaining = range.oldCount
            newRemaining = range.newCount
            return
        }
        if line.hasPrefix("--- ") {
            // A plain `diff -u` has no "diff --git" line; "---" outside a hunk starts the next file.
            if file == nil || file?.sawMinusHeader == true || file?.hunks.isEmpty == false {
                finishFile()
                file = FileBuilder()
            }
            file?.sawMinusHeader = true
            if let path = Self.markerPath(line.dropFirst(4), prefix: "a/") {
                file?.oldPath = path
            } else {
                file?.oldIsNull = true
            }
            return
        }
        guard file != nil else { return }
        if line.hasPrefix("+++ ") {
            if let path = Self.markerPath(line.dropFirst(4), prefix: "b/") {
                file?.newPath = path
            } else {
                file?.newIsNull = true
            }
        } else if line.hasPrefix("new file mode") {
            file?.isNew = true
        } else if line.hasPrefix("deleted file mode") {
            file?.isDeleted = true
        } else if line.hasPrefix("rename from ") {
            file?.renameFrom = Self.unquote(line.dropFirst("rename from ".count))
        } else if line.hasPrefix("rename to ") {
            file?.renameTo = Self.unquote(line.dropFirst("rename to ".count))
        } else if line.hasPrefix("copy from ") {
            file?.copyFrom = Self.unquote(line.dropFirst("copy from ".count))
        } else if line.hasPrefix("copy to ") {
            file?.copyTo = Self.unquote(line.dropFirst("copy to ".count))
        } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            file?.isBinary = true
        }
        // index, mode, similarity and binary patch payload lines carry nothing we show.
    }

    private mutating func closeHunk() {
        guard let header = hunkHeader else { return }
        file?.hunks.append(DiffHunk(
            header: header.header,
            oldStart: header.oldStart,
            oldCount: header.oldCount,
            newStart: header.newStart,
            newCount: header.newCount,
            lines: hunkLines
        ))
        hunkHeader = nil
        hunkLines = []
        oldRemaining = 0
        newRemaining = 0
    }

    private mutating func finishFile() {
        closeHunk()
        guard let builder = file else { return }
        file = nil

        let added = builder.isNew || builder.oldIsNull || builder.copyTo != nil
        let deleted = builder.isDeleted || builder.newIsNull
        let renamed = builder.renameFrom != nil || builder.renameTo != nil

        let oldPath: String? = if let from = builder.renameFrom ?? builder.copyFrom {
            from
        } else if added {
            nil
        } else {
            builder.oldPath
        }
        let newPath: String? = if let to = builder.renameTo ?? builder.copyTo {
            to
        } else if deleted {
            nil
        } else {
            builder.newPath
        }

        let status: DiffFile.Status = if builder.isBinary {
            .binary
        } else if deleted {
            .deleted
        } else if added {
            .added
        } else if renamed {
            .renamed
        } else {
            .modified
        }

        let displayPath = newPath ?? oldPath ?? builder.newPath ?? builder.oldPath ?? ""
        var id = displayPath
        var suffix = 2
        while usedIds.contains(id) {
            id = "\(displayPath)#\(suffix)"
            suffix += 1
        }
        usedIds.insert(id)

        files.append(DiffFile(
            id: id,
            oldPath: oldPath,
            newPath: newPath,
            displayPath: displayPath,
            status: status,
            additions: builder.additions,
            deletions: builder.deletions,
            hunks: builder.hunks,
            widestLine: builder.widestLine
        ))
    }

    // MARK: Header helpers

    /// "@@ -12,5 +12,7 @@ func foo()" -> (12, 5, 12, 7). A missing count means 1.
    private static func hunkRange(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        var cursor = ByteCursor(line.utf8)
        guard cursor.skip("@@ -") else { return nil }
        guard let oldStart = cursor.readInt() else { return nil }
        let oldCount = cursor.skip(",") ? cursor.readInt() : 1
        guard let oldCount, cursor.skip(" +") else { return nil }
        guard let newStart = cursor.readInt() else { return nil }
        let newCount = cursor.skip(",") ? cursor.readInt() : 1
        guard let newCount, cursor.skip(" @@") else { return nil }
        return (oldStart, oldCount, newStart, newCount)
    }

    /// Path after "--- " / "+++ ", or nil for /dev/null. Drops a trailing tab (git adds one when
    /// the path has a space; GNU diff puts a timestamp there) and the git "a/" / "b/" prefix.
    private static func markerPath(_ rest: Substring, prefix: String) -> String? {
        let raw: String
        if rest.first == "\"" {
            raw = unquote(rest)
        } else if let tab = rest.firstIndex(of: "\t") {
            raw = String(rest[..<tab])
        } else {
            raw = String(rest)
        }
        if raw == "/dev/null" { return nil }
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    /// Paths from "diff --git a/x b/y". Ambiguous when paths contain " b/"; renames and the
    /// ---/+++ lines override these, so this only has to be right for headers-only files.
    private static func gitHeaderPaths(_ rest: Substring) -> (old: String, new: String)? {
        func strip(_ path: String, _ prefix: String) -> String {
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }

        if rest.first == "\"" {
            guard let end = closingQuote(rest) else { return nil }
            let old = unquote(rest[...end])
            let new = unquote(rest[rest.index(after: end)...].drop(while: { $0 == " " }))
            return (strip(old, "a/"), strip(new, "b/"))
        }
        if let quoted = rest.range(of: " \"", options: .backwards) {
            let old = String(rest[..<quoted.lowerBound])
            let new = unquote(rest[rest.index(after: quoted.lowerBound)...])
            return (strip(old, "a/"), strip(new, "b/"))
        }
        // Same path on both sides (the common case): the line splits exactly in half.
        let bytes = rest.utf8
        if bytes.count % 2 == 1 {
            let mid = bytes.index(bytes.startIndex, offsetBy: bytes.count / 2)
            if bytes[mid] == UInt8(ascii: " ") {
                let old = strip(String(Substring(bytes[..<mid])), "a/")
                let new = strip(String(Substring(bytes[bytes.index(after: mid)...])), "b/")
                if old == new { return (old, new) }
            }
        }
        if let split = rest.range(of: " b/") {
            return (strip(String(rest[..<split.lowerBound]), "a/"), String(rest[split.upperBound...]))
        }
        guard let space = rest.firstIndex(of: " ") else { return nil }
        return (strip(String(rest[..<space]), "a/"), strip(String(rest[rest.index(after: space)...]), "b/"))
    }

    private static func closingQuote(_ s: Substring) -> Substring.Index? {
        var index = s.index(after: s.startIndex)
        while index < s.endIndex {
            if s[index] == "\\" {
                index = s.index(after: index)
                if index == s.endIndex { return nil }
            } else if s[index] == "\"" {
                return index
            }
            index = s.index(after: index)
        }
        return nil
    }

    /// Git C-style quoting: "dir/na\303\257ve \"x\".txt" -> dir/naïve "x".txt.
    static func unquote(_ s: Substring) -> String {
        guard s.count >= 2, s.first == "\"", let end = closingQuote(s) else { return String(s) }
        let body = s.utf8[s.utf8.index(after: s.utf8.startIndex)..<end]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(body.count)
        var iterator = body.makeIterator()
        while let byte = iterator.next() {
            guard byte == UInt8(ascii: "\\"), let escaped = iterator.next() else {
                bytes.append(byte)
                continue
            }
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.next(), (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct ByteCursor {
    let bytes: Substring.UTF8View
    var index: Substring.UTF8View.Index

    init(_ bytes: Substring.UTF8View) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    mutating func skip(_ literal: StaticString) -> Bool {
        var probe = index
        let buffer = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
        for expected in buffer {
            guard probe < bytes.endIndex, bytes[probe] == expected else { return false }
            probe = bytes.index(after: probe)
        }
        index = probe
        return true
    }

    mutating func readInt() -> Int? {
        var value = 0
        var sawDigit = false
        while index < bytes.endIndex, case let byte = bytes[index], byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            value = value &* 10 &+ Int(byte - UInt8(ascii: "0"))
            sawDigit = true
            index = bytes.index(after: index)
        }
        return sawDigit ? value : nil
    }
}
