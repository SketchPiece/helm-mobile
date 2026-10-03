import XCTest
@testable import HelmMobile

final class UnifiedDiffTests: XCTestCase {
    func testModifiedFileWithMultipleHunksNumbersLines() throws {
        let diff = """
        diff --git a/Sources/App/main.swift b/Sources/App/main.swift
        index 3b18e51..a2c4f0d 100644
        --- a/Sources/App/main.swift
        +++ b/Sources/App/main.swift
        @@ -1,4 +1,5 @@
         import Foundation
        +import os

         let a = 1
        -let b = 2
        +let b = 3
        @@ -20,3 +21,2 @@ func run() {
         start()
        --- not a header, a deleted line
         stop()

        """
        let files = UnifiedDiff.parse(diff)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.oldPath, "Sources/App/main.swift")
        XCTAssertEqual(file.newPath, "Sources/App/main.swift")
        XCTAssertEqual(file.displayPath, "Sources/App/main.swift")
        XCTAssertEqual(file.fileName, "main.swift")
        XCTAssertEqual(file.directory, "Sources/App")
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 2)
        XCTAssertEqual(file.hunks.count, 2)

        let first = file.hunks[0]
        XCTAssertEqual(first.header, "@@ -1,4 +1,5 @@")
        XCTAssertEqual(first.lines.map(\.kind), [.context, .addition, .context, .context, .deletion, .addition])
        XCTAssertEqual(first.lines.map(\.oldNumber), [1, nil, 2, 3, 4, nil])
        XCTAssertEqual(first.lines.map(\.newNumber), [1, 2, 3, 4, nil, 5])
        XCTAssertEqual(first.lines[1].text, "import os")
        XCTAssertEqual(first.lines[2].text, "")

        let second = file.hunks[1]
        XCTAssertEqual(second.header, "@@ -20,3 +21,2 @@ func run() {")
        XCTAssertEqual(second.lines.map(\.kind), [.context, .deletion, .context])
        XCTAssertEqual(second.lines.map(\.oldNumber), [20, 21, 22])
        XCTAssertEqual(second.lines.map(\.newNumber), [21, nil, 22])
        XCTAssertEqual(second.lines[1].text, "-- not a header, a deleted line")
    }

    func testNewFile() throws {
        let diff = """
        diff --git a/docs/new.md b/docs/new.md
        new file mode 100644
        index 0000000..e69de29
        --- /dev/null
        +++ b/docs/new.md
        @@ -0,0 +1,2 @@
        +# Title
        +Body
        """
        let file = try XCTUnwrap(UnifiedDiff.parse(diff).first)
        XCTAssertEqual(file.status, .added)
        XCTAssertNil(file.oldPath)
        XCTAssertEqual(file.newPath, "docs/new.md")
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 0)
        XCTAssertEqual(file.hunks[0].lines.map(\.newNumber), [1, 2])
        XCTAssertEqual(file.hunks[0].lines.map(\.oldNumber), [nil, nil])
    }

    func testDeletedFile() throws {
        let diff = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        index e69de29..0000000
        --- a/old.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        """
        let file = try XCTUnwrap(UnifiedDiff.parse(diff).first)
        XCTAssertEqual(file.status, .deleted)
        XCTAssertEqual(file.oldPath, "old.txt")
        XCTAssertNil(file.newPath)
        XCTAssertEqual(file.displayPath, "old.txt")
        XCTAssertEqual(file.deletions, 1)
        XCTAssertEqual(file.hunks[0].oldCount, 1)
        XCTAssertEqual(file.hunks[0].lines.map(\.oldNumber), [1])
    }

    func testRename() throws {
        let diff = """
        diff --git a/src/a b.ts b/src/c.ts
        similarity index 90%
        rename from src/a b.ts
        rename to src/c.ts
        index 1111111..2222222 100644
        --- a/src/a b.ts\t
        +++ b/src/c.ts
        @@ -1 +1 @@
        -x
        +y
        diff --git a/pure.txt b/moved/pure.txt
        similarity index 100%
        rename from pure.txt
        rename to moved/pure.txt
        """
        let files = UnifiedDiff.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].status, .renamed)
        XCTAssertEqual(files[0].oldPath, "src/a b.ts")
        XCTAssertEqual(files[0].newPath, "src/c.ts")
        XCTAssertEqual(files[0].additions, 1)
        XCTAssertEqual(files[0].deletions, 1)
        XCTAssertEqual(files[1].status, .renamed)
        XCTAssertEqual(files[1].oldPath, "pure.txt")
        XCTAssertEqual(files[1].displayPath, "moved/pure.txt")
        XCTAssertTrue(files[1].hunks.isEmpty)
    }

    func testBinaryFile() throws {
        let diff = """
        diff --git a/assets/logo.png b/assets/logo.png
        index 1234567..89abcde 100644
        Binary files a/assets/logo.png and b/assets/logo.png differ
        diff --git a/assets/new.bin b/assets/new.bin
        new file mode 100644
        index 0000000..1234567
        GIT binary patch
        literal 12
        TcmZQzWMXDvWn*Mx;9vj%04M+i

        literal 0
        HcmV?d00001

        """
        let files = UnifiedDiff.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].status, .binary)
        XCTAssertEqual(files[0].displayPath, "assets/logo.png")
        XCTAssertTrue(files[0].hunks.isEmpty)
        XCTAssertEqual(files[1].status, .binary)
        XCTAssertNil(files[1].oldPath)
        XCTAssertEqual(files[1].displayPath, "assets/new.bin")
    }

    func testNoNewlineAtEndOfFile() throws {
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         keep
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let file = try XCTUnwrap(UnifiedDiff.parse(diff).first)
        let lines = file.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .noNewline, .addition, .noNewline])
        XCTAssertEqual(lines[2].text, "No newline at end of file")
        XCTAssertNil(lines[2].oldNumber)
        XCTAssertNil(lines[2].newNumber)
        XCTAssertEqual(lines[3].newNumber, 2)
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
    }

    func testMultipleFilesAndCRLF() {
        let diff = "diff --git a/one.txt b/one.txt\r\n--- a/one.txt\r\n+++ b/one.txt\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n"
            + "diff --git a/two.txt b/two.txt\n--- a/two.txt\n+++ b/two.txt\n@@ -5,2 +5,3 @@\n x\n+y\n z\n"
        let files = UnifiedDiff.parse(diff)
        XCTAssertEqual(files.map(\.displayPath), ["one.txt", "two.txt"])
        XCTAssertEqual(files[0].hunks[0].lines.map(\.text), ["a", "b"])
        XCTAssertEqual(files[1].hunks[0].lines.map(\.newNumber), [5, 6, 7])
        XCTAssertEqual(files.map(\.additions), [1, 1])
        XCTAssertEqual(Set(files.map(\.id)).count, 2)
    }

    func testPlainUnifiedDiffWithoutGitHeaders() {
        let diff = """
        --- a/x.c\t2024-01-01 00:00:00
        +++ b/x.c\t2024-01-02 00:00:00
        @@ -1 +1 @@
        -1
        +2
        --- a/y.c
        +++ b/y.c
        @@ -1 +1,2 @@
         1
        +2
        """
        let files = UnifiedDiff.parse(diff)
        XCTAssertEqual(files.map(\.displayPath), ["x.c", "y.c"])
        XCTAssertEqual(files.map(\.status), [.modified, .modified])
    }

    func testQuotedPaths() throws {
        let diff = """
        diff --git "a/na\\303\\257ve.txt" "b/na\\303\\257ve.txt"
        new file mode 100644
        index 0000000..e69de29
        """
        let file = try XCTUnwrap(UnifiedDiff.parse(diff).first)
        XCTAssertEqual(file.displayPath, "na\u{EF}ve.txt")
        XCTAssertEqual(file.status, .added)
    }

    func testEmptyInput() {
        XCTAssertTrue(UnifiedDiff.parse("").isEmpty)
        XCTAssertTrue(UnifiedDiff.parse("\n\n").isEmpty)
    }
}
