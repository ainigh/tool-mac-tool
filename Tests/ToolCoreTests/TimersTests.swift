import XCTest
@testable import ToolCore

final class TimersTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    /// 5 October 2026 (a Monday) at `hour`:`minute`, London time.
    private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0, day d: Int = 5) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, d, hour, minute, second)
        return calendar.date(from: c)!
    }

    private func spec(_ id: String) -> TimerSpec { TimerSpec.all.first { $0.id == id }! }

    func testSixTimersTwoOfEachKindAndOneOfEachChime() {
        let kinds = TimerSpec.all.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .once }.count, 2)
        XCTAssertEqual(kinds.filter { $0 == .repeating }.count, 2)
        XCTAssertEqual(kinds.filter { $0 == .dayChime }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .nightChime }.count, 1)
        XCTAssertEqual(Set(TimerSpec.all.map(\.id)).count, 6)
    }

    func testClickingStepsThroughThePresetsThenOff() {
        let t = spec("timer-1")
        var s = TimerState()
        for i in t.presets.indices {
            s = t.cycled(s, now: at(9, i))
            XCTAssertEqual(s.choice, i)
            XCTAssertEqual(s.start, at(9, i))
        }
        s = t.cycled(s, now: at(10))
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(t.phase(s, now: at(10)), .off)
    }

    func testAChimeTogglesOnAndOff() {
        let c = spec("day-chime")
        let on = c.cycled(TimerState(), now: at(9))
        XCTAssertTrue(on.isOn)
        XCTAssertEqual(c.phase(on, now: at(9)), .chiming)
        XCTAssertFalse(c.cycled(on, now: at(9)).isOn)
    }

    func testOnceCountsDownThenRingsOnce() {
        let t = spec("timer-1")   // 1 minute first
        let s = t.chose(0, now: at(9))
        XCTAssertEqual(t.phase(s, now: at(9, 0, 20)), .counting(remaining: 40, of: 60, round: 0))
        XCTAssertNil(t.due(s, now: at(9, 0, 59), calendar: calendar))
        let (event, after) = t.due(s, now: at(9, 1, 1), calendar: calendar)!
        XCTAssertEqual(event, .finished(at: at(9, 1)))
        XCTAssertEqual(t.phase(after, now: at(9, 1, 1)), .finished)
        XCTAssertNil(t.due(after, now: at(9, 2), calendar: calendar))
    }

    func testOnceLongOverdueSwitchesOffQuietly() {
        let t = spec("timer-1")
        let s = t.chose(0, now: at(9))
        let (event, after) = t.due(s, now: at(12), calendar: calendar)!
        XCTAssertNil(event)
        XCTAssertFalse(after.isOn)
    }

    func testRepeatingRingsHoldsFiveMinutesThenStartsAgain() {
        let t = spec("repeat-1")   // 15 minutes first
        var s = t.chose(0, now: at(9))
        XCTAssertNil(t.due(s, now: at(9, 14), calendar: calendar))
        let (event, after) = t.due(s, now: at(9, 15), calendar: calendar)!
        XCTAssertEqual(event, .roundDone(round: 1))
        s = after
        XCTAssertEqual(t.phase(s, now: at(9, 17)), .holding(remaining: 180, round: 0))
        XCTAssertNil(t.due(s, now: at(9, 19), calendar: calendar))
        // Back to counting at 9:20, the second round.
        XCTAssertEqual(t.phase(s, now: at(9, 21)), .counting(remaining: 14 * 60, of: 15 * 60, round: 1))
        XCTAssertEqual(t.due(s, now: at(9, 35), calendar: calendar)?.event, .roundDone(round: 2))
    }

    func testRepeatingMissedRoundsPassQuietly() {
        let t = spec("repeat-1")
        let s = t.chose(0, now: at(9))
        // Asleep until 10:05: rounds ended at 9:15, 9:35, 9:55; at 10:05 it's counting round 4.
        let (event, after) = t.due(s, now: at(10, 5), calendar: calendar)!
        XCTAssertNil(event)
        XCTAssertEqual(after.rung, 3)
        // Woke at 10:16 instead: sitting at zero after the fourth round, so it rings.
        XCTAssertEqual(t.due(s, now: at(10, 16), calendar: calendar)?.event, .roundDone(round: 4))
    }

    func testDayChimeOnTheHourFromSixToTen() {
        let c = spec("day-chime")
        var s = c.chose(0, now: at(5, 30))
        XCTAssertNil(c.due(s, now: at(5, 59), calendar: calendar))
        let (event, after) = c.due(s, now: at(6, 0, 3), calendar: calendar)!
        XCTAssertEqual(event, .chime(at: at(6)))
        s = after
        XCTAssertNil(c.due(s, now: at(6, 30), calendar: calendar))
        XCTAssertEqual(c.due(s, now: at(22, 0, 1), calendar: calendar)?.event, .chime(at: at(22)))
        s = c.due(s, now: at(22, 0, 1), calendar: calendar)!.state
        XCTAssertNil(c.due(s, now: at(23, 0, 1), calendar: calendar))
        XCTAssertEqual(c.nextChime(after: at(22, 10), calendar: calendar), at(6, day: 6))
    }

    func testTurningAChimeOnMidHourWaitsForTheNextHour() {
        let c = spec("day-chime")
        let s = c.chose(0, now: at(14, 2))
        XCTAssertNil(c.due(s, now: at(14, 3), calendar: calendar))
        XCTAssertEqual(c.due(s, now: at(15), calendar: calendar)?.event, .chime(at: at(15)))
    }

    func testAMissedChimeIsSkipped() {
        let c = spec("day-chime")
        let s = c.chose(0, now: at(13, 50))
        let (event, after) = c.due(s, now: at(14, 20), calendar: calendar)!
        XCTAssertNil(event)
        XCTAssertEqual(after.lastChime, at(14))
    }

    func testNightWatchFromElevenToFive() {
        let c = spec("night-chime")
        let s = c.chose(0, now: at(21))
        XCTAssertNil(c.due(s, now: at(22), calendar: calendar))
        XCTAssertEqual(c.due(s, now: at(23), calendar: calendar)?.event, .chime(at: at(23)))
        XCTAssertEqual(c.due(s, now: at(5, 0, 1, day: 6), calendar: calendar)?.event, .chime(at: at(5, day: 6)))
        XCTAssertNil(c.due(s, now: at(6, 0, 1, day: 6), calendar: calendar))
        XCTAssertEqual(c.nextChime(after: at(5, 10, day: 6), calendar: calendar), at(23, day: 6))
    }

    func testCardWords() {
        let day = TimerText.day(at(14), calendar: calendar)
        XCTAssertEqual(day.title, "Monday 2 PM")
        XCTAssertEqual(day.since, "8 hours since 6 AM")
        XCTAssertEqual(day.left, "8 hours to 10 PM")
        XCTAssertEqual(day.progress, 0.5)
        XCTAssertEqual(TimerText.day(at(6), calendar: calendar).since, "The day starts")
        XCTAssertEqual(TimerText.day(at(21), calendar: calendar).left, "1 hour to 10 PM")
        XCTAssertEqual(TimerText.day(at(22), calendar: calendar).left, "It's 10 PM: the day is done")

        let late = TimerText.night(at(1, day: 6), calendar: calendar)
        XCTAssertEqual(late.title, "Tuesday 1 AM")
        XCTAssertEqual(late.left, "5 hours left before 6 AM")
        XCTAssertEqual(TimerText.night(at(23), calendar: calendar).left, "7 hours left before 6 AM")
        XCTAssertEqual(TimerText.night(at(5), calendar: calendar).left, "1 hour left before 6 AM")
    }

    func testClockAndDurations() {
        XCTAssertEqual(TimerText.clock(600), "10:00")
        XCTAssertEqual(TimerText.clock(0.2), "0:01")
        XCTAssertEqual(TimerText.clock(0), "0:00")
        XCTAssertEqual(TimerText.clock(3900), "1:05:00")
        XCTAssertEqual(TimerText.duration(300), "5 min")
        XCTAssertEqual(TimerText.duration(5400), "1 h 30 min")
        XCTAssertEqual(TimerText.duration(7200), "2 h")
        XCTAssertEqual(TimerText.hourLabel(0), "12 AM")
        XCTAssertEqual(TimerText.hourLabel(12), "12 PM")
        XCTAssertEqual(TimerText.hourLabel(15), "3 PM")
    }

    func testEveryToneIsAudibleAndInRange() {
        for tone in Tone.allCases {
            let s = tone.samples()
            XCTAssertGreaterThan(s.count, Int(Tone.rate / 2), "\(tone)")
            let peak = s.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.2, "\(tone)")
            XCTAssertLessThanOrEqual(peak, 1, "\(tone)")
        }
        // Each sounds different.
        let all = Tone.allCases.map { $0.samples() }
        for i in all.indices {
            for j in all.indices where j > i { XCTAssertNotEqual(all[i], all[j]) }
        }
    }

    func testStateRoundTripsThroughJSON() throws {
        let s = TimerState(choice: 2, start: at(9), rung: 3, lastChime: at(8))
        let back = try JSONDecoder().decode(TimerState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}
