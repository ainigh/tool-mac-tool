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
        XCTAssertEqual(book.jobs.first?.inline?.kind, .remind)
        XCTAssertEqual(book.jobs.first?.inline?.text, "x")
        XCTAssertEqual(book.jobs.first?.when.kind, .daily)
    }

    // MARK: Every hour, and events

    func testHourlyKeepsToItsHours() {
        let s = Schedule(kind: .hourly, minute: 0, hours: Schedule.dayHours)
        XCTAssertEqual(s.next(after: at(9, 15), calendar: calendar), at(10))
        XCTAssertEqual(s.next(after: at(22, 1), calendar: calendar), at(6, day: 4))
        let night = Schedule(kind: .hourly, minute: 0, hours: Schedule.nightHours)
        XCTAssertEqual(night.next(after: at(12), calendar: calendar), at(23))
        XCTAssertEqual(night.next(after: at(23, 30), calendar: calendar), at(0, day: 4))
        XCTAssertEqual(Schedule(kind: .hourly, minute: 30).next(after: at(9, 31), calendar: calendar), at(10, 30))
    }

    func testHourlyDescribesItsRuns() {
        XCTAssertEqual(Schedule(kind: .hourly, minute: 0, hours: Schedule.dayHours).describe(), "Every hour, 06:00–22:00")
        XCTAssertEqual(Schedule(kind: .hourly, minute: 0, hours: Schedule.nightHours).describe(), "Every hour, 23:00–05:00")
        XCTAssertEqual(Schedule(kind: .hourly, minute: 15).describe(), "Every hour at :15")
        XCTAssertEqual(Schedule.hourRanges([1, 2, 3, 7]).map { "\($0.from)-\($0.to)" }, ["1-3", "7-7"])
        XCTAssertTrue(Schedule.hourRanges(Array(0...23)).isEmpty)
    }

    func testStartAndEndOfTheMonthAndWeek() {
        let start = Schedule(kind: .event, hour: 9, minute: 0, event: .startOfMonth)
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (2026, 11, 1, 9)
        XCTAssertEqual(start.next(after: at(10), calendar: calendar), calendar.date(from: c))
        let end = Schedule(kind: .event, hour: 18, minute: 0, event: .endOfMonth)
        XCTAssertEqual(end.next(after: at(10), calendar: calendar), at(18, day: 31))
        // 3 October 2026 is a Saturday: the week ends tomorrow and starts again on Monday the 5th.
        XCTAssertEqual(Schedule(kind: .event, hour: 20, minute: 0, event: .endOfWeek).next(after: at(10), calendar: calendar), at(20, day: 4))
        XCTAssertEqual(Schedule(kind: .event, hour: 8, minute: 0, event: .startOfWeek).next(after: at(10), calendar: calendar), at(8, day: 5))
        // One that waits for something to happen has no time.
        XCTAssertNil(Schedule(kind: .event, event: .alarmRang).next(after: at(10), calendar: calendar))
    }

    func testEventsMatchTheirLogEntries() {
        var log = ActivityLog()
        func add(_ kind: LogEntry.Kind, value: Double? = nil, minute: Int = 0) -> LogEntry {
            let e = LogEntry(at: at(9, minute), source: "box-goals-1", name: "Goals 1 · Timer 1", kind: kind, value: value)
            log.add(e)
            return e
        }
        let rang = add(.alarm)
        XCTAssertTrue(Schedule(kind: .event, event: .alarmRang).matches(rang, log: log, calendar: calendar))
        XCTAssertFalse(Schedule(kind: .event, event: .alarmSet).matches(rang, log: log, calendar: calendar))
        XCTAssertFalse(Schedule(kind: .daily).matches(rang, log: log, calendar: calendar))
        let forty = add(.batteryLevel, value: 40)
        XCTAssertTrue(Schedule(kind: .event, event: .batteryAt, level: 40).matches(forty, log: log, calendar: calendar))
        XCTAssertFalse(Schedule(kind: .event, event: .batteryAt, level: 30).matches(forty, log: log, calendar: calendar))
        XCTAssertTrue(Schedule(kind: .event, event: .batteryChange).matches(forty, log: log, calendar: calendar))
        let empty = add(.batteryEmpty, value: 0)
        XCTAssertTrue(Schedule(kind: .event, event: .batteryAt, level: 0).matches(empty, log: log, calendar: calendar))
        // Over 2 snoozes in a day: the third crosses it, the fourth doesn't again.
        let over = Schedule(kind: .event, event: .countOver, metric: .snoozes, limit: 2)
        var crossed: [Int] = []
        for m in 1...4 {
            let e = add(.snoozed, minute: m)
            if over.matches(e, log: log, calendar: calendar) { crossed.append(over.crossing(e, log: log, calendar: calendar) ?? -1) }
        }
        XCTAssertEqual(crossed, [3])
    }

    func testOldSchedulesStillReadWithTheNewFields() throws {
        let json = #"{"kind":"daily","at":0,"minutes":60,"start":0,"hour":7,"minute":45,"weekdays":[2]}"#
        let s = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
        XCTAssertEqual(s.kind, .daily)
        XCTAssertEqual(s.hour, 7)
        XCTAssertEqual(s.hours, [])
        XCTAssertEqual(s.event, .alarmRang)
    }

    // MARK: Built-ins, placeholders, web calls, the old signals

    func testBuiltinsAreAddedOnceAndFirst() {
        var book = ScheduleBook(jobs: [ScheduledJob(name: "Mine")])
        book.ensureBuiltins()
        XCTAssertEqual(book.jobs.map(\.name), ["Day chime", "Night watch", "Mine"])
        book.ensureBuiltins()
        XCTAssertEqual(book.jobs.count, 3)
        XCTAssertTrue(book.jobs[0].isBuiltin)
        XCTAssertTrue(book.jobs[0].enabled)
        XCTAssertEqual(book.jobs[0].when.next(after: at(9, 15), calendar: calendar), at(10))
        XCTAssertEqual(book.jobs[1].when.next(after: at(9, 15), calendar: calendar), at(23))
    }

    func testPlaceholdersFillFromTheTimeTheLogAndTheEvent() {
        var log = ActivityLog()
        log.add(LogEntry(at: at(8), source: "box-goals-1", name: "Goals 1 · Timer 1", kind: .alarm))
        log.add(LogEntry(at: at(8, 5), source: "box-goals-1", name: "Goals 1 · Timer 1", kind: .snoozed))
        let e = LogEntry(at: at(9), source: "battery", name: "Battery", kind: .batteryLevel, detail: "40%", value: 40)
        var values = JobText.logValues(log, now: at(10), calendar: calendar)
        values.merge(JobText.eventValues(e, now: at(10), calendar: calendar)) { $1 }
        let text = "{{weekday}} {{day_of_month}} ({{days_left_in_month}} left) · {{alarms_today}}/{{snoozes_today}} · {{event}} · {{event_value}} · {{last_alarm}} · [{{next_alarm}}]"
        XCTAssertEqual(JobText.fill(text, now: at(10), last: nil, calendar: calendar, values: values),
                       "Saturday 3 (28 left) · 1/1 · Battery level · Battery · 40% · 40 · Goals 1 · Timer 1 at 08:00 · []")
    }

    func testAWebCallSendsItsTextOrTheEvent() throws {
        let job = ScheduledJob(name: "Hook", action: .webhook, target: "https://a.b",
                               when: Schedule(kind: .event, event: .countOver, metric: .snoozes, limit: 2))
        let e = LogEntry(at: at(9), source: "box-goals-1", name: "Goals 1", kind: .snoozed)
        let json = WebCall.body(text: #"{"a": 1}"#, job: job, entry: e, crossing: nil, now: at(9), calendar: calendar, device: "Mac")
        XCTAssertEqual(json.contentType, "application/json")
        XCTAssertEqual(WebCall.body(text: "hello", job: job, entry: e, crossing: nil, now: at(9), calendar: calendar, device: "Mac").contentType,
                       "text/plain; charset=utf-8")
        let signal = WebCall.body(text: " ", job: job, entry: e, crossing: 3, now: at(9), calendar: calendar, device: "Mac")
        let object = try JSONSerialization.jsonObject(with: signal.data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "snooze")
        XCTAssertEqual((object?["threshold"] as? [String: Any])?["count"] as? Int, 3)
        let plain = WebCall.body(text: "", job: job, entry: nil, crossing: nil, now: at(9), calendar: calendar, device: "Mac")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: plain.data) as? [String: Any])?["type"] as? String, "schedule")
    }

    func testTheOldThresholdsAndSignalsBecomeSchedules() {
        var s = SignalSettings()
        s.rules = [ThresholdRule(metric: .alarms, limit: 6)]
        XCTAssertEqual(ScheduleBook.fromSignals(s).count, 1)
        s.url = "https://worker.example.dev/signal"
        s.secret = "shh"
        s.sendAlarms = true
        let jobs = ScheduleBook.fromSignals(s)
        XCTAssertEqual(jobs.map(\.when.event), [.countOver, .thresholdCrossed, .batteryChange, .alarmRang, .alarmSnoozed])
        XCTAssertEqual(jobs[0].when.limit, 6)
        XCTAssertEqual(jobs[0].inline?.kind, .remind)
        XCTAssertTrue(jobs.dropFirst().allSatisfy { $0.inline?.kind == .webhook && $0.inline?.target == s.url && $0.inline?.secret == "shh" })
    }

    func testOldJobsReadWithoutTheNewFields() throws {
        let json = #"{"jobs":[{"id":"a","name":"Old","action":"remind","text":"x"}],"runs":[]}"#
        let book = try JSONDecoder().decode(ScheduleBook.self, from: Data(json.utf8))
        XCTAssertEqual(book.jobs.first?.inline?.secret, "")
        XCTAssertEqual(book.jobs.first?.actionID, "")
        XCTAssertNil(book.jobs.first?.builtin)
    }
}
