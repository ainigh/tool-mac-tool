import XCTest
@testable import ToolCore

final class SchedulesTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    /// 3 October 2026 (a Saturday) at `hour`:`minute`, London time.
    private func at(_ hour: Int, _ minute: Int = 0, day d: Int = 3) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, d, hour, minute)
        return calendar.date(from: c)!
    }

    func testOnceIsOnlyInTheFuture() {
        let s = Schedule(kind: .once, at: at(14))
        XCTAssertEqual(s.next(after: at(9), calendar: calendar), at(14))
        XCTAssertNil(s.next(after: at(15), calendar: calendar))
    }

    func testEveryCountsFromTheStart() {
        let s = Schedule(kind: .every, minutes: 15, start: at(9))
        XCTAssertEqual(s.next(after: at(8), calendar: calendar), at(9))
        XCTAssertEqual(s.next(after: at(9), calendar: calendar), at(9, 15))
        XCTAssertEqual(s.next(after: at(9, 7), calendar: calendar), at(9, 15))
        XCTAssertEqual(s.next(after: at(10, 59), calendar: calendar), at(11))
    }

    func testDailyAtATime() {
        let s = Schedule(kind: .daily, hour: 9, minute: 30)
        XCTAssertEqual(s.next(after: at(8), calendar: calendar), at(9, 30))
        XCTAssertEqual(s.next(after: at(9, 30), calendar: calendar), at(9, 30, day: 4))
    }

    func testDailyOnWeekdaysSkipsTheWeekend() {
        // Saturday the 3rd: the next weekday is Monday the 5th.
        let s = Schedule(kind: .daily, hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6])
        XCTAssertEqual(s.next(after: at(7), calendar: calendar), at(8, day: 5))
    }

    func testDescriptions() {
        XCTAssertEqual(Schedule(kind: .every, minutes: 15).describe(), "Every 15 minutes")
        XCTAssertEqual(Schedule(kind: .every, minutes: 60).describe(), "Every hour")
        XCTAssertEqual(Schedule(kind: .every, minutes: 90).describe(), "Every 1 hour 30 minutes")
        XCTAssertEqual(Schedule(kind: .every, minutes: 2880).describe(), "Every 2 days")
        XCTAssertEqual(Schedule(kind: .daily, hour: 9, minute: 5).describe(), "Every day at 09:05")
        XCTAssertEqual(Schedule(kind: .daily, hour: 18, minute: 30, weekdays: [6, 2, 4]).describe(clock24: false),
                       "Mon, Wed, Fri at 6:30 PM")
        XCTAssertEqual(Schedule(kind: .daily, hour: 8, minute: 0, weekdays: [2, 3, 4, 5, 6]).describe(), "Weekdays at 08:00")
        XCTAssertEqual(Schedule(kind: .daily, hour: 10, minute: 0, weekdays: [1, 7]).describe(), "Weekends at 10:00")
        XCTAssertEqual(Schedule(kind: .once, at: at(14)).describe(calendar: calendar), "Once, Saturday 3 October at 14:00")
    }

    func testAOneOffTurnsItselfOffAfterRunning() {
        var job = ScheduledJob(when: Schedule(kind: .once, at: at(14)))
        job.plan(from: at(9), calendar: calendar)
        XCTAssertEqual(job.next, at(14))
        XCTAssertFalse(job.isDue(at(13)))
        XCTAssertTrue(job.isDue(at(14, 1)))
        job.ran(at: at(14, 1), ok: true, result: "done", calendar: calendar)
        XCTAssertFalse(job.enabled)
        XCTAssertNil(job.next)
        XCTAssertEqual(job.lastResult, "done")
    }

    func testARepeatingJobMovesOnFromWhenItRan() {
        // The Mac was asleep through several runs: it runs once, then carries on from now.
        var job = ScheduledJob(when: Schedule(kind: .every, minutes: 30, start: at(9)))
        job.plan(from: at(9, 10), calendar: calendar)
        XCTAssertEqual(job.next, at(9, 30))
        job.ran(at: at(12, 5), ok: true, result: "", calendar: calendar)
        XCTAssertEqual(job.next, at(12, 30))
        XCTAssertTrue(job.enabled)
    }

    func testFillsThePlaceholders() {
        let text = JobText.fill("{{date}} {{time}} last: {{last}} clip: {{clipboard}}", now: at(14, 5),
                                last: "42", clipboard: "hello", calendar: calendar)
        XCTAssertEqual(text, "Saturday 3 October 2026 14:05 last: 42 clip: hello")
        XCTAssertEqual(JobText.fill("{{last}}", now: at(1), last: nil, calendar: calendar), "")
    }

    func testTheBookKeepsRecentRunsAndSavesDates() throws {
        var book = ScheduleBook(jobs: [ScheduledJob(name: "A", action: .askModel, text: "hi")])
        for i in 0..<(ScheduleBook.keep + 5) {
            book.record(JobRun(job: "a", name: "A", at: Date(timeIntervalSince1970: Double(i)), ok: true, output: "\(i)"))
        }
        XCTAssertEqual(book.runs.count, ScheduleBook.keep)
        XCTAssertEqual(book.runs.first?.output, "\(ScheduleBook.keep + 4)")
        book.jobs[0].plan(from: at(9), calendar: calendar)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try book.save(to: url)
        XCTAssertEqual(ScheduleBook.load(from: url), book)
    }

    func testOldOrPartialJobsStillLoad() throws {
        let json = #"{"jobs":[{"name":"Old","action":"somethingNew","text":"x"}],"runs":[]}"#
        let book = try JSONDecoder().decode(ScheduleBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.jobs.first?.name, "Old")
        XCTAssertEqual(book.jobs.first?.action, .remind)
        XCTAssertEqual(book.jobs.first?.when.kind, .daily)
    }
}
