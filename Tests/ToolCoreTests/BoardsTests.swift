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

    func testTagsIconAndDockAreKeptAndOldFilesStillRead() throws {
        var box = Board.Box(text: "\n  Call Sam  \nabout the trip")
        XCTAssertEqual(box.title, "Call Sam")
        box.toggle(.think)
        box.toggle(.important)
        XCTAssertEqual(box.tags, [.important, .think])
        box.toggle(.think)
        XCTAssertEqual(box.tags, [.important])
        box.icon = "star"
        box.docked = true
        let data = try JSONEncoder().encode(box)
        XCTAssertEqual(try JSONDecoder().decode(Board.Box.self, from: data), box)
        let old = try JSONDecoder().decode(Board.Box.self, from: Data(#"{"text":"a","tint":2,"tags":["urgent","someday"]}"#.utf8))
        XCTAssertEqual(old.tags, [.urgent])
        XCTAssertNil(old.icon)
        XCTAssertFalse(old.docked)
        XCTAssertNil(Board.Box(text: " \n ").title)
    }

    // MARK: Order and size

    func testOldBoardsKeepTheirOrderAndSize() throws {
        let json = #"{"shown":3,"boxes":[{"text":"a"},{"text":"b"},{"text":"c"}]}"#
        let b = try JSONDecoder().decode(Board.self, from: Data(json.utf8)).tidied()
        XCTAssertEqual(b.order, Array(0..<Board.maxBoxes))
        XCTAssertEqual(b.visible, [0, 1, 2])
        XCTAssertEqual(b.boxes[1].text, "b")
        XCTAssertEqual(b.boxes[1].across, 1)
        XCTAssertEqual(b.boxes[1].down, 1)
    }

    func testOrderIsTidiedToEveryBoxOnce() {
        let b = Board(shown: 4, order: [3, 3, 99, -1, 0])
        XCTAssertEqual(b.order.count, Board.maxBoxes)
        XCTAssertEqual(Set(b.order).count, Board.maxBoxes)
        XCTAssertEqual(Array(b.order.prefix(3)), [3, 0, 1])
    }

    func testMoveTakesTheTargetsPlace() {
        var b = Board()
        b.move(0, to: 2)                       // forward: after the ones between
        XCTAssertEqual(b.visible, [1, 2, 0, 3])
        b.move(3, to: 1)                       // back: before the target
        XCTAssertEqual(b.visible, [3, 1, 2, 0])
        b.move(3, to: 3)
        XCTAssertEqual(b.visible, [3, 1, 2, 0])
    }

    func testOrderAndSizeRoundTrip() throws {
        var b = Board()
        b.boxes[2].text = "big"
        b.move(2, to: 0)
        b.resize(2, across: 2, down: 9)
        let back = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(b)).tidied()
        XCTAssertEqual(back, b)
        XCTAssertEqual(back.visible, [2, 0, 1, 3])
        XCTAssertEqual(back.boxes[2].across, 2)
        XCTAssertEqual(back.boxes[2].down, Board.maxSpan)
    }

    func testRevealBringsAHiddenBoxAfterTheShownOnes() {
        var b = Board()
        b.move(1, to: 0)
        b.reveal(9)
        XCTAssertEqual(b.visible, [1, 0, 2, 3, 9])
        XCTAssertTrue(b.isShown(9))
        b.reveal(9)
        XCTAssertEqual(b.shown, 5)
    }

    func testFocusGoesRoundInTheBoardsOrder() {
        var b = Board()
        b.move(3, to: 0)                       // 3, 0, 1, 2
        XCTAssertEqual(b.nextNote(after: nil, including: true), 3)
        XCTAssertEqual(b.nextNote(after: 3), 0)
        XCTAssertEqual(b.nextNote(after: 2), 3)
        b.boxes[0].status = .completed
        XCTAssertEqual(b.nextNote(after: 3), 1)
        for i in [3, 1, 2] { b.boxes[i].status = .completed }
        XCTAssertEqual(b.nextNote(after: 2), 4)  // the first hidden one
    }

    func testSingleBlocksLayOutInRows() {
        let b = Board(shown: 5)
        let l = b.layout(width: 1000, height: 700)
        let rows = Board.rows(for: 5, width: 1000, height: 700)
        XCTAssertEqual(l.cells.map(\.box), [0, 1, 2, 3, 4])
        XCTAssertEqual(l.down, rows.count)
        // Each row fills the width.
        for y in Set(l.cells.map(\.y)) {
            XCTAssertEqual(l.cells.filter { $0.y == y }.map(\.width).reduce(0, +), 1, accuracy: 1e-9)
        }
    }

    func testABigBoxSpansBlocksAndNothingOverlaps() {
        for shown in 2...12 {
            var b = Board(shown: shown)
            b.resize(b.visible[0], across: 2, down: 2)
            if shown > 3 { b.resize(b.visible[3], across: 3, down: 1) }
            for (w, h) in [(1000.0, 700.0), (600.0, 900.0)] {
                let l = b.layout(width: w, height: h)
                XCTAssertEqual(l.cells.map(\.box), b.visible)
                let blockW = 1 / Double(l.across), blockH = 1 / Double(l.down)
                for c in l.cells {
                    XCTAssertEqual(c.width / blockW, Double(min(b.boxes[c.box].across, l.across)), accuracy: 1e-9)
                    XCTAssertEqual(c.height / blockH, Double(b.boxes[c.box].down), accuracy: 1e-9)
                    XCTAssertLessThanOrEqual(c.x + c.width, 1 + 1e-9)
                    XCTAssertLessThanOrEqual(c.y + c.height, 1 + 1e-9)
                }
                for (i, a) in l.cells.enumerated() {
                    for d in l.cells[(i + 1)...] {
                        let apart = a.x + a.width <= d.x + 1e-9 || d.x + d.width <= a.x + 1e-9
                            || a.y + a.height <= d.y + 1e-9 || d.y + d.height <= a.y + 1e-9
                        XCTAssertTrue(apart, "\(shown) boxes: \(a) and \(d) overlap")
                    }
                }
            }
        }
    }

    func testTwoByTwoInFourBlocksAcross() {
        var b = Board(shown: 5)
        b.resize(0, across: 2, down: 2)
        let l = b.layout(width: 1000, height: 500)
        XCTAssertEqual(l.across, 4)
        XCTAssertEqual(l.down, 2)
        XCTAssertEqual(l.cells[0], Board.Cell(box: 0, x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(l.cells[1], Board.Cell(box: 1, x: 0.5, y: 0, width: 0.25, height: 0.5))
        XCTAssertEqual(l.cells[3], Board.Cell(box: 3, x: 0.5, y: 0.5, width: 0.25, height: 0.5))
        XCTAssertTrue(l.cells[0].contains(x: 0.2, y: 0.9))
        XCTAssertFalse(l.cells[1].contains(x: 0.2, y: 0.9))
    }

    // MARK: Links, rows, colors

    func testLinksAndRowsAreKeptAndOldFilesHaveNone() throws {
        var b = Board()
        b.boxes[0].links = [NoteLink(board: "ideas", box: 3), NoteLink(board: "goals", box: 1)]
        b.arrange(rows: 2)
        let back = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(b)).tidied()
        XCTAssertEqual(back.boxes[0].links, b.boxes[0].links)
        XCTAssertEqual(back.rows, 2)
        let old = try JSONDecoder().decode(Board.self, from: Data(#"{"shown":2,"boxes":[{"text":"a"}]}"#.utf8))
        XCTAssertEqual(old.boxes[0].links, [])
        XCTAssertNil(old.rows)
    }

    func testShowWrittenShowsEveryNoteWithTextAndHidesTheEmpty() {
        var b = Board(shown: 3)
        b.boxes[1].text = "one"
        b.boxes[7].text = "  \nseven"
        b.boxes[9].text = "   "
        b.move(1, to: 0)                     // 1, 0, 2, 3 …
        b.showWritten()
        XCTAssertEqual(b.visible, [1, 7])
        XCTAssertEqual(b.order.count, Board.maxBoxes)
        var empty = Board(shown: 5)
        empty.showWritten()
        XCTAssertEqual(empty.shown, 1)
    }

    func testTwoRowsHoldTheShownBoxes() {
        var b = Board(shown: 7)
        b.resize(0, across: 2, down: 2)
        b.arrange(rows: 2)
        XCTAssertEqual(b.boxes[0].across, 1)
        let l = b.layout(width: 600, height: 900)   // tall: unfixed, it would take more rows
        XCTAssertEqual(l.down, 2)
        XCTAssertEqual(Set(l.cells.map(\.y)).count, 2)
        XCTAssertEqual(Board.rows(for: 7, width: 600, height: 900, fixed: 2), [4, 3])
        XCTAssertEqual(Board.rows(for: 1, width: 600, height: 900, fixed: 2), [1])
        // A big box in two rows: the grid widens rather than growing a third row.
        b.resize(1, across: 2, down: 2)
        XCTAssertEqual(b.layout(width: 600, height: 900).down, 2)
        b.arrange(rows: nil)
        XCTAssertNil(b.rows)
    }

    func testColorizeGivesNeighboursDifferentColors() {
        for shown in [2, 4, 6, 9, 12] {
            var b = Board(shown: shown)
            b.colorize(width: 1000, height: 700)
            let cells = b.layout(width: 1000, height: 700).cells
            for c in cells {
                XCTAssertNotEqual(b.boxes[c.box].tint, 0)
                for d in cells where d.box != c.box && d.touches(c) {
                    XCTAssertNotEqual(b.boxes[c.box].tint, b.boxes[d.box].tint, "\(shown): \(c.box) and \(d.box)")
                }
            }
        }
    }

    func testNextTintSkipsTheColorsAround() {
        var b = Board(shown: 4)                 // 2 × 2
        b.boxes[0].tint = 0
        b.boxes[1].tint = 1                     // right of 0
        b.boxes[2].tint = 2                     // below 0
        b.boxes[3].tint = 3                     // diagonal: not beside it
        XCTAssertEqual(b.nextTint(for: 0, width: 1000, height: 700), 3)
        b.boxes[0].tint = 7
        XCTAssertEqual(b.nextTint(for: 0, width: 1000, height: 700), 0)
    }

    func testCellsTouchOnlyAlongAnEdge() {
        let a = Board.Cell(box: 0, x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertTrue(a.touches(Board.Cell(box: 1, x: 0.5, y: 0, width: 0.5, height: 0.5)))
        XCTAssertTrue(a.touches(Board.Cell(box: 2, x: 0, y: 0.5, width: 0.5, height: 0.5)))
        XCTAssertFalse(a.touches(Board.Cell(box: 3, x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
    }
}
