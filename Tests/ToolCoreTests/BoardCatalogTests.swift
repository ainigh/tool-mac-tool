import Foundation
import XCTest
@testable import ToolCore

final class BoardCatalogTests: XCTestCase {
    func testComesWithTheTenBoardsThenBlankOnesAndTheDailyPlanApart() {
        let c = BoardCatalog()
        XCTAssertEqual(c.boards.count, BoardCatalog.slots)
        XCTAssertEqual(c.boards.prefix(10).map(\.id), BoardCatalog.defaults.map(\.id))
        XCTAssertTrue(c.boards.prefix(10).allSatisfy(\.builtin))
        XCTAssertEqual(Set(c.boards.map(\.id)).count, BoardCatalog.slots)
        XCTAssertFalse(c.boards.contains { $0.id == BoardCatalog.dailyPlanID })
        XCTAssertEqual(c.dailyPlan.name, "Daily plan")
        XCTAssertEqual(c.all.first?.id, BoardCatalog.dailyPlanID)
        XCTAssertEqual(c.title("goals"), "Goals")
        XCTAssertEqual(c.title(c.boards[11].id), "Board 12")
        XCTAssertNil(c.slot(BoardCatalog.dailyPlanID))
    }

    func testTidiesAnOddFileKeepingWhatWasNamed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)/board-catalog.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // No file: the boards it comes with, with the icons picked for them before.
        let fresh = BoardCatalog.load(from: url, icons: ["ideas": "sparkles"])
        XCTAssertEqual(fresh.info("ideas")?.symbol, "sparkles")
        XCTAssertEqual(fresh.info("ideas")?.defaultSymbol, "lightbulb.fill")

        var c = fresh
        c.boards[12].name = "Travel"
        c.boards[12].detail = "Trips to plan"
        try c.save(to: url)
        XCTAssertEqual(BoardCatalog.load(from: url), c)

        // Goals gone, Travel twice, the Daily plan on the grid: tidied.
        let travel = c.boards[12]
        var odd = c
        odd.boards = [travel, travel, c.dailyPlan] + Array(c.boards.dropFirst(1).prefix(5))
        try JSONEncoder().encode(odd).write(to: url)
        let tidy = BoardCatalog.load(from: url)
        XCTAssertEqual(tidy.boards.count, BoardCatalog.slots)
        XCTAssertEqual(tidy.boards.filter { $0.id == travel.id }.count, 1)
        XCTAssertEqual(tidy.info(travel.id)?.name, "Travel")
        XCTAssertNotNil(tidy.slot("goals"))
        XCTAssertNil(tidy.slot(BoardCatalog.dailyPlanID))
        XCTAssertEqual(Set(tidy.boards.map(\.id)).count, BoardCatalog.slots)
    }

    func testDailyPlanOpensAtSixNineAndNoonOnce() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: h, minute: m))! }
        XCTAssertNil(DailyPlan.due(now: at(5, 59), last: nil, calendar: cal))
        XCTAssertEqual(DailyPlan.due(now: at(6), last: nil, calendar: cal), at(6))
        XCTAssertEqual(DailyPlan.due(now: at(6, 30), last: at(5), calendar: cal), at(6))
        XCTAssertNil(DailyPlan.due(now: at(6, 31), last: at(6, 30), calendar: cal))
        // Missed by more than an hour (asleep): it waits for the next.
        XCTAssertNil(DailyPlan.due(now: at(7, 30), last: nil, calendar: cal))
        XCTAssertEqual(DailyPlan.due(now: at(9, 5), last: at(6), calendar: cal), at(9))
        XCTAssertEqual(DailyPlan.due(now: at(12, 59), last: at(9), calendar: cal), at(12))
        XCTAssertNil(DailyPlan.due(now: at(13, 0), last: at(9), calendar: cal))
        XCTAssertNil(DailyPlan.due(now: at(18), last: nil, calendar: cal))
        XCTAssertEqual(DailyPlan.hoursText, "6 AM, 9 AM and 12 PM")
    }

    func testShowOnlyKeepsTheirOrderAndHidesTheRest() {
        var b = Board(shown: 6)
        b.showOnly { [1, 4, 30].contains($0) }
        XCTAssertEqual(b.shown, 3)
        XCTAssertEqual(b.visible, [1, 4, 30])
        b.showOnly { _ in false }
        XCTAssertEqual(b.shown, Board.minBoxes)
    }
}
