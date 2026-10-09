import Foundation
import XCTest
@testable import ToolCore

final class NoteCountdownTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func testCountdownsToggleOnAndOffAndSeveralRunAtOnce() {
        var box = Board.Box()
        box.toggleCountdown(5, now: t0)
        box.toggleCountdown(2, now: t0)
        box.toggleCountdown(7, now: t0)
        XCTAssertEqual(box.countdowns.map(\.minutes), [2, 5], "in order; only the choices")
        box.toggleCountdown(5, now: t0)
        XCTAssertEqual(box.countdowns.map(\.minutes), [2])
    }

    func testAtZeroItRingsAndWaitsUntilTheStatusChanges() {
        var box = Board.Box()
        box.toggleCountdown(2, now: t0)
        box.toggleCountdown(5, now: t0)
        XCTAssertEqual(box.ringCountdowns(now: at(1.9)), [])
        XCTAssertEqual(box.nextCountdown?.minutes, 2)
        XCTAssertEqual(box.ringCountdowns(now: at(2)), [2])
        XCTAssertTrue(box.isRinging)
        // Still ringing: it isn't rung twice, and the other one keeps counting.
        XCTAssertEqual(box.ringCountdowns(now: at(3)), [])
        XCTAssertEqual(box.nextCountdown?.minutes, 5)
        XCTAssertEqual(box.countdown(2)?.remaining(now: at(3)), 0)
        // Nothing changed the status yet.
        XCTAssertFalse(box.settleCountdowns())
        // A status picked after it began ringing: quiet, and counting down again from then.
        box.toggle(.p30, now: at(3))
        XCTAssertTrue(box.settleCountdowns())
        XCTAssertFalse(box.isRinging)
        XCTAssertEqual(box.countdown(2)?.start, at(3))
        XCTAssertEqual(box.countdown(5)?.start, t0, "the one that wasn't ringing goes on as it was")
        XCTAssertEqual(box.ringCountdowns(now: at(5)), [2, 5])
    }

    func testAStatusSetBeforeItRangDoesNotStopIt() {
        var box = Board.Box()
        box.toggleCountdown(2, now: t0)
        box.toggle(.pending, now: at(1))
        _ = box.ringCountdowns(now: at(2))
        XCTAssertFalse(box.settleCountdowns())
        XCTAssertTrue(box.isRinging)
    }

    func testCountdownsAreKeptAndOldFilesHaveNone() throws {
        var box = Board.Box(text: "Stretch")
        box.toggleCountdown(10, now: t0)
        box.toggleCountdown(45, now: t0)
        let back = try JSONDecoder().decode(Board.Box.self, from: JSONEncoder().encode(box))
        XCTAssertEqual(back.countdowns, box.countdowns)
        let old = try JSONDecoder().decode(Board.Box.self, from: Data(#"{"text":"hi"}"#.utf8))
        XCTAssertEqual(old.countdowns, [])
        // An odd file: unknown minutes and repeats go.
        var board = Board()
        board.boxes[0].countdowns = [NoteCountdown(minutes: 5, start: t0), NoteCountdown(minutes: 3, start: t0),
                                     NoteCountdown(minutes: 5, start: t0)]
        XCTAssertEqual(board.tidied().boxes[0].countdowns.map(\.minutes), [5])
    }

    func testStatusesRunFromToDoThroughTheirPercentagesToCompleted() {
        XCTAssertEqual(NoteStatus.allCases.map(\.title),
                       ["To do", "Pending", "10%", "30%", "40%", "50%", "70%", "90%", "Completed"])
        XCTAssertEqual(NoteStatus.pending.percent, 1)
        XCTAssertEqual(NoteStatus.completed.percent, 100)
        XCTAssertEqual(NoteStatus.allCases.filter(\.isProgress).map(\.percent), [10, 30, 40, 50, 70, 90])
        let percents = NoteStatus.allCases.map(\.percent)
        XCTAssertEqual(percents, percents.sorted())
    }

    func testThePartsOfTheDayAreAMsPMsAndNightly() {
        XCTAssertEqual(NoteRepeat.allCases.map(\.title), ["Daily", "AMs", "PMs", "Nightly", "Weekly", "Monthly"])
    }
}
