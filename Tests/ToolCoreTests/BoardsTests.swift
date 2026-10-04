import Foundation
import XCTest
@testable import ToolCore

final class BoardsTests: XCTestCase {
    func testMoreAndFewerShowAndHideWithoutLosingText() {
        var b = Board()
        XCTAssertEqual(b.shown, 4)
        XCTAssertEqual(b.boxes.count, Board.maxBoxes)
        b.boxes[3].text = "keep me"
        b.fewer()
        XCTAssertEqual(b.shown, 3)
        b.more()
        XCTAssertEqual(b.shown, 4)
        XCTAssertEqual(b.boxes[3].text, "keep me")
        for _ in 0..<10 { b.fewer() }
        XCTAssertEqual(b.shown, Board.minBoxes)
        for _ in 0..<100 { b.more() }
        XCTAssertEqual(b.shown, Board.maxBoxes)
    }

    func testTintsCycleThroughAndBack() {
        var tint = 0
        var seen: Set<Int> = []
        for _ in Board.tints.indices {
            seen.insert(tint)
            tint = Board.nextTint(after: tint)
        }
        XCTAssertEqual(seen.count, Board.tints.count)
        XCTAssertEqual(tint, 0)
    }

    func testGutterNarrowsAsBoxesGrow() {
        var last = Double.infinity
        for n in 1...Board.maxBoxes {
            let g = Board.gutter(for: n)
            XCTAssertLessThanOrEqual(g, last)
            XCTAssertGreaterThanOrEqual(g, 2)
            last = g
        }
        XCTAssertGreaterThan(Board.gutter(for: 1), Board.gutter(for: 16))
    }

    func testRowsHoldEveryBoxAndFillEvenly() {
        for n in 1...Board.maxBoxes {
            for (w, h) in [(1000.0, 700.0), (700.0, 1000.0), (1600.0, 500.0)] {
                let rows = Board.rows(for: n, width: w, height: h)
                XCTAssertEqual(rows.reduce(0, +), n)
                XCTAssertLessThanOrEqual(rows.max()! - rows.min()!, 1)
                XCTAssertFalse(rows.contains(0))
            }
        }
        XCTAssertEqual(Board.rows(for: 4, width: 1000, height: 700), [2, 2])
        XCTAssertEqual(Board.rows(for: 2, width: 1000, height: 700), [2])
        XCTAssertEqual(Board.rows(for: 2, width: 500, height: 1000), [1, 1])
    }

    func testSavesAndLoadsAndTidiesAnOddFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString)/goals.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(Board.load(from: url), Board())
        var b = Board()
        b.boxes[0] = .init(text: "Ship it", tint: 2)
        b.more()
        try b.save(to: url)
        XCTAssertEqual(Board.load(from: url), b)

        try #"{"shown": 99, "boxes": [{"text": "a", "tint": 42}]}"#.data(using: .utf8)!.write(to: url)
        let odd = Board.load(from: url)
        XCTAssertEqual(odd.shown, Board.maxBoxes)
        XCTAssertEqual(odd.boxes.count, Board.maxBoxes)
        XCTAssertEqual(odd.boxes[0], .init(text: "a", tint: 0))
    }
}
