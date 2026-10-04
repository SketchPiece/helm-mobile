import XCTest
@testable import HelmMobile

final class ShareInboxTests: XCTestCase {
    private var root: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "share-inbox-\(UUID().uuidString)")
        root = base.appending(path: "Shares")
        destination = base.appending(path: "Taken")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// A finished share as the extension leaves it.
    @discardableResult
    private func share(_ texts: [String], files: [(String, Bool)] = [], at date: Date) throws -> URL {
        let folder = try ShareInbox.makeFolder(in: root)
        for (name, _) in files { try Data(name.utf8).write(to: folder.appending(path: name)) }
        try ShareInbox.finish(.init(createdAt: date, texts: texts, files: files.map { .init(name: $0.0, isImage: $0.1) }), in: folder)
        return folder
    }

    func testManifestRoundTrips() throws {
        let manifest = ShareInbox.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), texts: ["hello", "https://example.com"],
            files: [.init(name: "IMG_1.HEIC", isImage: true), .init(name: "notes.pdf", isImage: false)]
        )
        let folder = try ShareInbox.makeFolder(in: root)
        try ShareInbox.finish(manifest, in: folder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: folder.appending(path: ShareInbox.manifestName))
        XCTAssertEqual(try decoder.decode(ShareInbox.Manifest.self, from: data), manifest)
    }

    func testTakeMergesSharesOldestFirstAndCleansUp() throws {
        let now = Date()
        try share(["second"], files: [("b.png", true)], at: now)
        try share(["first", "https://example.com"], files: [("a.pdf", false)], at: now.addingTimeInterval(-60))

        let content = ShareInbox.take(from: root, to: destination, now: now)

        XCTAssertEqual(content.text, "first\n\nhttps://example.com\n\nsecond")
        XCTAssertEqual(content.files.map(\.url.lastPathComponent), ["a.pdf", "b.png"])
        XCTAssertEqual(content.files.map(\.isImage), [false, true])
        for file in content.files {
            XCTAssertTrue(file.url.path.hasPrefix(destination.path))
            XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), file.url.lastPathComponent)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertTrue(ShareInbox.take(from: root, to: destination, now: now).isEmpty)
    }

    func testUnfinishedSharesWaitThenExpire() throws {
        let folder = try ShareInbox.makeFolder(in: root)
        try Data("partial".utf8).write(to: folder.appending(path: "big.mov"))

        XCTAssertTrue(ShareInbox.take(from: root, to: destination, now: Date()).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a share still being written is left alone")

        XCTAssertTrue(ShareInbox.take(from: root, to: destination, now: Date().addingTimeInterval(2 * 24 * 3600)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCorruptManifestIsDroppedAndNamesStayInsideTheShare() throws {
        let corrupt = try ShareInbox.makeFolder(in: root)
        try Data("{".utf8).write(to: corrupt.appending(path: ShareInbox.manifestName))
        let outside = root.deletingLastPathComponent().appending(path: "escape.txt")
        try Data("not shared".utf8).write(to: outside)
        try ShareInbox.finish(.init(createdAt: Date(), files: [.init(name: "../escape.txt", isImage: false)]),
                              in: try ShareInbox.makeFolder(in: root))

        let content = ShareInbox.take(from: root, to: destination)

        XCTAssertTrue(content.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testTextIsTrimmedAndDeduplicated() {
        var content = SharedContent()
        content.append(texts: ["  https://example.com \n", "", "https://example.com", "note"], files: [])
        content.append(SharedContent(text: "note"))
        XCTAssertEqual(content.text, "https://example.com\n\nnote")
    }

    func testUniqueNames() {
        XCTAssertEqual(ShareInbox.uniqueName("photo.jpg", existing: []), "photo.jpg")
        XCTAssertEqual(ShareInbox.uniqueName("photo.jpg", existing: ["Photo.JPG"]), "photo 2.jpg")
        XCTAssertEqual(ShareInbox.uniqueName("photo.jpg", existing: ["photo.jpg", "photo 2.jpg"]), "photo 3.jpg")
        XCTAssertEqual(ShareInbox.uniqueName("README", existing: ["README"]), "README 2")
    }
}
