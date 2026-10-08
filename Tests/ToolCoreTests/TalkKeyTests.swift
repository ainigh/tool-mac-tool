import Foundation
import XCTest
@testable import ToolCore

final class TalkKeyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testHoldThenReleaseFinishes() {
        var k = TalkKey()
        XCTAssertEqual(k.down(at: t0), .start)
        XCTAssertTrue(k.listening)
        XCTAssertEqual(k.up(at: t0.addingTimeInterval(1.5)), .finish)
        XCTAssertEqual(k.state, .idle)
    }

    func testTapGoesHandsFreeAndTheNextTapFinishes() {
        var k = TalkKey()
        XCTAssertEqual(k.down(at: t0), .start)
        XCTAssertEqual(k.up(at: t0.addingTimeInterval(0.1)), .none)
        XCTAssertEqual(k.state, .handsFree)
        XCTAssertEqual(k.down(at: t0.addingTimeInterval(5)), .none)
        XCTAssertEqual(k.up(at: t0.addingTimeInterval(5.05)), .finish)
        XCTAssertEqual(k.state, .idle)
    }

    func testAShortcutWithTheKeyCancels() {
        var k = TalkKey()
        _ = k.down(at: t0)
        XCTAssertEqual(k.otherKey(), .cancel)
        XCTAssertEqual(k.up(at: t0.addingTimeInterval(0.1)), .none)
        XCTAssertEqual(k.state, .idle)
    }

    func testTypingWhileHandsFreeKeepsListening() {
        var k = TalkKey()
        _ = k.down(at: t0)
        _ = k.up(at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(k.otherKey(), .none)
        XCTAssertEqual(k.state, .handsFree)
    }

    func testEscapeCancelsHeldOrHandsFree() {
        var k = TalkKey()
        _ = k.down(at: t0)
        XCTAssertEqual(k.escape(), .cancel)
        XCTAssertEqual(k.escape(), .none)
        _ = k.down(at: t0)
        _ = k.up(at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(k.escape(), .cancel)
        XCTAssertEqual(k.state, .idle)
    }

    func testReleaseWithoutPressDoesNothing() {
        var k = TalkKey()
        XCTAssertEqual(k.up(at: t0), .none)
        XCTAssertEqual(k.state, .idle)
    }

    func testText() {
        XCTAssertEqual(TalkKey.text("  Hello there.\n"), "Hello there.")
        XCTAssertNil(TalkKey.text(" \n "))
    }
}
