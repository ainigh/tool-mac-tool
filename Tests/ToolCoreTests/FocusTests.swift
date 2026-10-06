import Foundation
import XCTest
@testable import ToolCore

final class FocusTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testTenMinutesHalvesTheReminders() {
        var s = FocusSession(board: "goals", strict: false, note: 0, now: t0)
        XCTAssertEqual(s.interval, 600)
        XCTAssertEqual(s.reminderMarks, [300, 120, 60])
        XCTAssertNil(s.step(now: at(100)))
        XCTAssertEqual(s.step(now: at(300)), .reminder(left: 300))
        XCTAssertNil(s.step(now: at(301)))
        XCTAssertEqual(s.step(now: at(480)), .reminder(left: 120))
        XCTAssertEqual(s.step(now: at(540)), .reminder(left: 60))
        XCTAssertNil(s.step(now: at(570)))
        XCTAssertEqual(s.step(now: at(600)), .timeUp)
        XCTAssertEqual(s.phase, .ringing)
        XCTAssertNil(s.remaining(now: at(700)))
        // It waits at time's up for an answer.
        XCTAssertNil(s.step(now: at(5000)))
    }

    func testAStaleReminderPassesQuietly() {
        var s = FocusSession(board: "goals", strict: false, note: 0, now: t0)
        // Asleep through the 5- and 2-minute marks: only the fresh one would show, and it isn't.
        XCTAssertNil(s.step(now: at(500)))
        XCTAssertEqual(s.reminded, 120)
        XCTAssertEqual(s.step(now: at(540)), .reminder(left: 60))
    }

    func testOneSnoozeARound() {
        var s = FocusSession(board: "goals", strict: false, note: 0, now: t0)
        _ = s.step(now: at(600))
        XCTAssertTrue(s.canSnooze)
        s.snooze(now: at(610))
        XCTAssertEqual(s.phase, .snoozed)
        XCTAssertFalse(s.canSnooze)
        XCTAssertEqual(s.remaining(now: at(700)), 90)
        XCTAssertNil(s.step(now: at(700)))
        XCTAssertEqual(s.step(now: at(790)), .snoozeOver)
        XCTAssertEqual(s.phase, .ringing)
        XCTAssertFalse(s.canSnooze)
    }

    func testPendingRestsThenTheSameNoteAgain() {
        var s = FocusSession(board: "goals", strict: false, note: 2, now: t0)
        _ = s.step(now: at(600))
        s.pending(now: at(620))
        XCTAssertEqual(s.phase, .rest)
        XCTAssertFalse(s.canComplete)
        XCTAssertNil(s.step(now: at(700)))
        XCTAssertEqual(s.step(now: at(800)), .focusStarted)
        XCTAssertEqual(s.note, 2)
        XCTAssertEqual(s.round, 2)
        XCTAssertTrue(s.canSnooze == false)
        // The snooze comes back with the new round.
        _ = s.step(now: at(1400))
        XCTAssertTrue(s.canSnooze)
    }

    func testCompletedEarlyRestsAndMovesOn() {
        var s = FocusSession(board: "goals", strict: true, interval: 25 * 60, note: 0, now: t0)
        XCTAssertTrue(s.canComplete)
        s.complete(next: 1, now: at(120))
        XCTAssertEqual(s.phase, .rest)
        XCTAssertEqual(s.note, 1)
        XCTAssertEqual(s.completed, 1)
        XCTAssertEqual(s.remaining(now: at(120)), 180)
        XCTAssertEqual(s.step(now: at(300)), .focusStarted)
        XCTAssertEqual(s.remaining(now: at(300)), 1500)
    }

    func testNextNoteSkipsCompletedAndGoesRound() {
        var done = Array(repeating: false, count: 36)
        XCTAssertEqual(FocusSession.nextNote(after: 0, completed: done, shown: 4, including: true), 0)
        XCTAssertEqual(FocusSession.nextNote(after: 0, completed: done, shown: 4), 1)
        done[1] = true
        done[2] = true
        XCTAssertEqual(FocusSession.nextNote(after: 0, completed: done, shown: 4), 3)
        XCTAssertEqual(FocusSession.nextNote(after: 3, completed: done, shown: 4), 0)
        done[0] = true
        done[3] = true
        // Every shown note done: the next hidden box.
        XCTAssertEqual(FocusSession.nextNote(after: 3, completed: done, shown: 4), 4)
        XCTAssertNil(FocusSession.nextNote(after: 0, completed: Array(repeating: true, count: 36), shown: 4))
        // The first shown note is completed: start on the next.
        var first = Array(repeating: false, count: 36)
        first[0] = true
        XCTAssertEqual(FocusSession.nextNote(after: 0, completed: first, shown: 3, including: true), 1)
    }

    func testTextIsNeededToComplete() {
        XCTAssertFalse(FocusSession.hasText(""))
        XCTAssertFalse(FocusSession.hasText("  \n\t"))
        XCTAssertTrue(FocusSession.hasText("Draft the intro"))
    }

    func testIntervalsAndRoundTrip() throws {
        XCTAssertTrue(FocusSession.intervals.contains(FocusSession.defaultInterval))
        let s = FocusSession(board: "ideas", strict: true, interval: 5 * 60, note: 3, now: t0, onTestClock: true)
        XCTAssertEqual(try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(s)), s)
        XCTAssertEqual(FocusSession(board: "x", strict: false, interval: 1, note: 0, now: t0).interval, 60)
    }

    func testRebaseBringsFutureTimesBack() {
        var s = FocusSession(board: "goals", strict: false, note: 0, now: at(3600))
        s.rebase(now: t0)
        XCTAssertEqual(s.since, t0)
        XCTAssertEqual(s.started, t0)
    }
}
