import Foundation
import XCTest
@testable import ToolCore

/// The timers a box runs (the four countdowns and a due date), boxes kept with them and pinned,
/// and the battery's steps.
final class BoxTimersTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400
    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    func testABoxRunsTheFourCountdownsAndADueDate() {
        XCTAssertEqual(TimerSpec.forBoxes.map(\.id), ["timer-1", "timer-2", "repeat-1", "repeat-2", "due"])
        XCTAssertEqual(TimerSpec.chimes.map(\.id), ["day-chime", "night-chime"])
    }

    func testADueDateCountsDownAndRingsOnTheDay() {
        let due = TimerSpec.deadline
        let s = due.due(until: t0.addingTimeInterval(90 * day), now: t0)
        XCTAssertEqual(due.duration(s), 90 * day)
        XCTAssertEqual(due.phase(s, now: t0.addingTimeInterval(30 * day)),
                       .counting(remaining: 60 * day, of: 90 * day, round: 0))
        XCTAssertEqual(due.nextRing(s, now: t0), t0.addingTimeInterval(90 * day))
        let rang = due.due(s, now: t0.addingTimeInterval(90 * day), calendar: calendar)
        XCTAssertEqual(rang?.event, .finished(at: t0.addingTimeInterval(90 * day)))
        XCTAssertEqual(rang.map { due.phase($0.state, now: t0.addingTimeInterval(91 * day)) }, .finished)
    }

    func testAMissedDueDateStillRings() {
        let due = TimerSpec.deadline
        let s = due.due(until: t0.addingTimeInterval(day), now: t0)
        // The Mac was off for a week past it: it rings anyway (a countdown would pass quietly).
        XCTAssertEqual(due.due(s, now: t0.addingTimeInterval(8 * day), calendar: calendar)?.event,
                       .finished(at: t0.addingTimeInterval(day)))
        let once = TimerSpec.all[0]
        let c = once.chose(0, now: t0)
        XCTAssertNil(once.due(c, now: t0.addingTimeInterval(day), calendar: calendar)?.event)
    }

    func testADueDateRemindsAtWholeSpans() {
        let week = TimerSpec.deadlineReminders(for: 7 * day)
        XCTAssertEqual(week.first, 3 * day)
        XCTAssertEqual(week.last, 60)
        XCTAssertFalse(week.contains(7 * day))
        let s = TimerSpec.deadline.due(until: t0.addingTimeInterval(7 * day), now: t0)
        // Two days left: the two-day reminder.
        let at = t0.addingTimeInterval(5 * day)
        XCTAssertEqual(TimerSpec.deadline.due(s, now: at, calendar: calendar)?.event, .reminder(left: 2 * day))
    }

    func testNextRingForARepeatingTimerAtZeroIsTheNextRoundsEnd() {
        let r = TimerSpec.all.first { $0.id == "repeat-1" }!
        let s = r.chose(0, now: t0) // 15 min, then 5 at zero
        XCTAssertEqual(r.nextRing(s, now: t0), t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(r.nextRing(s, now: t0.addingTimeInterval(16 * 60)), t0.addingTimeInterval(35 * 60))
        XCTAssertNil(r.nextRing(TimerState(), now: t0))
    }

    func testLongCountdownsRead() {
        XCTAssertEqual(TimerText.countdown(299), "4:59")
        XCTAssertEqual(TimerText.countdown(3 * day + 4 * 3600 + 12 * 60 + 9), "3d 04:12:09")
        XCTAssertEqual(TimerText.span(3 * day), "3 d")
        XCTAssertEqual(TimerText.span(45 * day + 6 * 3600), "45 d 6 h")
        XCTAssertEqual(TimerText.span(395 * day), "1 y 30 d")
        XCTAssertEqual(TimerText.span(30 * 60), "30 min")
    }

    func testABoxKeepsItsTimerAndPinAndOldFilesStillLoad() throws {
        var b = Board()
        b.boxes[2].alarm = BoxAlarm(spec: "due", state: TimerSpec.deadline.due(until: t0.addingTimeInterval(day), now: t0))
        b.boxes[2].pinned = true
        let back = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back, b)
        XCTAssertEqual(back.boxes[2].alarm?.nextRing(now: t0), t0.addingTimeInterval(day))

        let old = #"{"shown": 2, "boxes": [{"text": "hi", "tint": 3}]}"#
        let loaded = try JSONDecoder().decode(Board.self, from: Data(old.utf8)).tidied()
        XCTAssertEqual(loaded.boxes[0].text, "hi")
        XCTAssertNil(loaded.boxes[0].alarm)
        XCTAssertFalse(loaded.boxes[0].pinned)
    }

    func testTidyingDropsATimerThatIsOffOrUnknown() {
        var b = Board()
        b.boxes[0].alarm = BoxAlarm(spec: "nope", state: TimerState(choice: 0, start: t0))
        b.boxes[1].alarm = BoxAlarm(spec: "timer-1", state: TimerState())
        b.boxes[2].alarm = BoxAlarm(spec: "timer-1", state: TimerState(choice: 0, start: t0))
        let t = b.tidied()
        XCTAssertNil(t.boxes[0].alarm)
        XCTAssertNil(t.boxes[1].alarm)
        XCTAssertNotNil(t.boxes[2].alarm)
    }

    func testBatteryStepsAndWhenItWasFull() {
        let s = BatteryState(choice: 0, level: 100, start: t0)
        // 20% an hour: 47% after 2 h 39 min; the next step is 40%, 21 minutes on.
        let now = t0.addingTimeInterval(2 * 3600 + 39 * 60)
        let steps = Battery.steps(s, now: now)
        XCTAssertEqual(steps.map(\.level), [40, 30, 20, 10, 0])
        XCTAssertEqual(steps.first?.at, t0.addingTimeInterval(3 * 3600))
        XCTAssertEqual(steps.last?.at, Battery.emptyAt(s))
        XCTAssertTrue(Battery.steps(BatteryState(), now: now).isEmpty)

        let set60 = LogEntry(at: t0.addingTimeInterval(-3600), source: "battery", name: "Battery", kind: .batterySet, value: 60)
        let set100 = LogEntry(at: t0.addingTimeInterval(-7200), source: "battery", name: "Battery", kind: .batterySet, value: 100)
        XCTAssertEqual(Battery.lastFull(BatteryState(choice: 2, level: 60, start: t0), entries: [set100, set60]),
                       t0.addingTimeInterval(-7200))
        XCTAssertEqual(Battery.lastFull(s, entries: [set100]), t0)
        XCTAssertNil(Battery.lastFull(BatteryState(), entries: [set60]))
    }
}
