import XCTest
@testable import Taki

/// `path:line:col` in agent output becomes a file to open, resolved against the tab's folder.
final class FileLinkTests: XCTestCase {
    let files: Set<String> = ["/repo/src/app.ts", "/repo/README.md", "/abs/x.swift", "/repo/My File.ts", "/repo/app/[slug]/page.tsx"]
    func parse(_ s: String) -> FileLink? { FileLink.parse(s, cwd: "/repo", isDocument: { self.files.contains($0) }) }

    func testRelativePathWithLineAndColumn() {
        XCTAssertEqual(parse("src/app.ts:42:7"), FileLink(path: "/repo/src/app.ts", line: 42, column: 7))
        XCTAssertEqual(parse("./src/app.ts:42"), FileLink(path: "/repo/src/app.ts", line: 42, column: nil))
        XCTAssertEqual(parse("README.md"), FileLink(path: "/repo/README.md", line: nil, column: nil))
    }

    func testAbsoluteAndFileURL() {
        XCTAssertEqual(parse("/abs/x.swift:3"), FileLink(path: "/abs/x.swift", line: 3, column: nil))
        XCTAssertEqual(parse("file:///abs/x.swift"), FileLink(path: "/abs/x.swift", line: nil, column: nil))
    }

    func testWrappingPunctuationIsIgnored() {
        XCTAssertEqual(parse("(src/app.ts:9),"), FileLink(path: "/repo/src/app.ts", line: 9, column: nil))
        XCTAssertEqual(parse("`src/app.ts`"), FileLink(path: "/repo/src/app.ts", line: nil, column: nil))
    }

    func testCompilerStyleAndBracketedRoutes() {
        XCTAssertEqual(parse("src/app.ts:42:"), FileLink(path: "/repo/src/app.ts", line: 42, column: nil))
        XCTAssertEqual(parse("app/[slug]/page.tsx:3"), FileLink(path: "/repo/app/[slug]/page.tsx", line: 3, column: nil))
        XCTAssertNil(parse("src/app.ts:+5"))                  // a sign is not a line number
    }

    func testWebLinksAndMissingFilesAreNotFiles() {
        XCTAssertNil(parse("https://example.com/src/app.ts:4"))
        XCTAssertNil(parse("src/nope.ts:1"))
        XCTAssertNil(parse("../../etc/passwd"))      // resolves outside, and does not exist in this fake disk
    }

    func testEditorLinks() {
        let link = FileLink(path: "/repo/My File.ts", line: 12, column: 3)
        XCTAssertEqual(FileLink.url(for: link, in: .vscode)?.absoluteString, "vscode://file/repo/My%20File.ts:12:3")
        XCTAssertEqual(FileLink.url(for: link, in: .cursor)?.absoluteString, "cursor://file/repo/My%20File.ts:12:3")
        XCTAssertEqual(FileLink.url(for: link, in: .zed)?.absoluteString, "zed://file/repo/My%20File.ts:12:3")
        XCTAssertNil(FileLink.url(for: link, in: .finder))           // Finder shows the file, never opens it
    }

    func testOnlyPlainDocumentsCanBeOpened() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taki-filelink-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appending(path: "Evil.app/Contents"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        fm.createFile(atPath: dir.appending(path: "notes.md").path, contents: Data("x".utf8))
        fm.createFile(atPath: dir.appending(path: "setup.command").path, contents: Data("x".utf8))
        fm.createFile(atPath: dir.appending(path: "run").path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertTrue(FileLink.isPlainDocument(dir.appending(path: "notes.md").path))
        XCTAssertFalse(FileLink.isPlainDocument(dir.appending(path: "Evil.app").path))      // a bundle is a folder
        XCTAssertFalse(FileLink.isPlainDocument(dir.appending(path: "setup.command").path)) // runs in Terminal
        XCTAssertFalse(FileLink.isPlainDocument(dir.appending(path: "run").path))           // executable bit
        XCTAssertFalse(FileLink.isPlainDocument(dir.path))                                  // folders never
    }
}
