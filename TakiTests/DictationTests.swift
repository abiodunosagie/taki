import AppKit
import XCTest
@testable import Taki

/// How dictation results become one line of text, and which key presses start push-to-talk.
final class DictationTests: XCTestCase {
    func testVolatileTextIsReplacedAndFinishedTextKept() {
        var t = TranscriptAccumulator()
        t.add("fix the", isFinal: false)
        t.add("fix the login", isFinal: false)
        XCTAssertEqual(t.text, "fix the login")
        t.add("Fix the login bug.", isFinal: true)
        t.add("then run", isFinal: false)
        XCTAssertEqual(t.text, "Fix the login bug. then run")
        t.add("Then run the tests.", isFinal: true)
        XCTAssertEqual(t.text, "Fix the login bug. Then run the tests.")
    }

    func testEmptyResultsAddNothing() {
        var t = TranscriptAccumulator()
        t.add("  ", isFinal: true)
        t.add("", isFinal: false)
        XCTAssertEqual(t.text, "")
    }

    func testOnlyOptionAloneStartsPushToTalk() {
        XCTAssertTrue(PushToTalk.isAlone([.option]))
        XCTAssertFalse(PushToTalk.isAlone([.option, .command]))
        XCTAssertFalse(PushToTalk.isAlone([.option, .shift]))
        XCTAssertFalse(PushToTalk.isAlone([]))
    }

    func testRightOptionIsReadFromItsOwnKeyBit() {
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | PushToTalk.rightOptionDeviceMask)
        let leftOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        XCTAssertTrue(PushToTalk.rightOptionDown(right))
        XCTAssertFalse(PushToTalk.rightOptionDown(leftOnly))    // left Option held, right just released
    }
}
