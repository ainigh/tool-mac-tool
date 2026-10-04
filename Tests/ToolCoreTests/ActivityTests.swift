import XCTest
@testable import ToolCore

final class ActivityTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func at(_ hour: Int, _ minute: Int = 0, day d: Int = 5) -> Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, d, hour, minute)
        return calendar.date(from: c)!
    }

    private func entry(_ kind: LogEntry.Kind, _ date: Date, value: Double? = nil) -> LogEntry {
        LogEntry(at: date, source: "timer-1", name: "Timer 1", kind: kind, value: value)
    }

    func testDaysCountEachKind() {
        var log = ActivityLog()
        log.add(entry(.set, at(9)))
        log.add(entry(.alarm, at(9, 10)))
        log.add(entry(.snoozed, at(9, 11)))
        log.add(entry(.alarm, at(9, 14)))
        log.add(entry(.alarm, at(10, day: 7)))
        let days = log.days(from: at(0), to: at(23, day: 7), calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].alarms, 2)
        XCTAssertEqual(days[0].snoozes, 1)
        XCTAssertTrue(days[0].anySet)
        XCTAssertFalse(days[1].anySet)
        XCTAssertEqual(days[1].alarms, 0)
        XCTAssertEqual(days[2].alarms, 1)
        XCTAssertEqual(log.count(.alarm, on: at(12), calendar: calendar), 2)
    }

    func testThresholdCrossesTheMomentTheCountGoesOver() {
        let rule = ThresholdRule(metric: .snoozes, limit: 4)
        var log = ActivityLog()
        var crossings: [Int] = []
        for i in 0..<7 {
            let e = entry(.snoozed, at(9, i))
            log.add(e)
            crossings += ThresholdRule.crossed(by: e, rules: [rule], log: log, calendar: calendar).map(\.count)
        }
        XCTAssertEqual(crossings, [5])
        // A new day starts over.
        let e = entry(.snoozed, at(9, day: 6))
        log.add(e)
        XCTAssertTrue(ThresholdRule.crossed(by: e, rules: [rule], log: log, calendar: calendar).isEmpty)
        // Turned off, or another kind: nothing.
        var off = rule
        off.enabled = false
        XCTAssertTrue(ThresholdRule.crossed(by: entry(.snoozed, at(9, 30)), rules: [off], log: log, calendar: calendar).isEmpty)
    }

    func testSignalJSON() throws {
        let rule = ThresholdRule(id: "r", metric: .snoozes, limit: 4)
        let e = LogEntry(id: "e1", at: at(9), source: "thresholds", name: "Thresholds", kind: .threshold, detail: rule.describe)
        let signal = Signal(entry: e, calendar: calendar, device: "Mac", threshold: (rule, 5))
        let json = String(decoding: try signal.json(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"type\":\"threshold\""))
        XCTAssertTrue(json.contains("\"day\":\"2026-10-05\""))
        XCTAssertTrue(json.contains("\"count\":5"))
        XCTAssertTrue(json.contains("\"at\":\"2026-10-05T08:00:00Z\""))
        let battery = Signal(entry: LogEntry(at: at(9), source: "battery", name: "Battery", kind: .batteryLevel, value: 60),
                             calendar: calendar, device: "Mac")
        XCTAssertEqual(battery.type, "battery")
    }

    func testSettingsEndpointAndWhatIsSent() throws {
        var s = SignalSettings()
        XCTAssertNil(s.endpoint)
        s.url = " https://example.workers.dev/hook "
        XCTAssertEqual(s.endpoint?.host, "example.workers.dev")
        s.url = "not a url"
        XCTAssertNil(s.endpoint)
        XCTAssertTrue(s.sends(.threshold))
        XCTAssertTrue(s.sends(.batteryEmpty))
        XCTAssertFalse(s.sends(.alarm))
        // Old saved settings without the newer keys still load.
        let old = try JSONDecoder().decode(SignalSettings.self, from: Data(#"{"url":"https://a.b"}"#.utf8))
        XCTAssertEqual(old.url, "https://a.b")
        XCTAssertEqual(old.rules.first?.limit, 4)
    }

    func testLogRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString).json")
        var log = ActivityLog()
        log.add(entry(.alarm, at(9), value: 60))
        try log.save(to: url)
        XCTAssertEqual(ActivityLog.load(from: url), log)
    }

    func testBatteryCyclesAndDrainsTwentyPercentAnHour() {
        var s = BatteryState()
        s = Battery.cycled(s, now: at(9))
        XCTAssertEqual(s.level, 100)
        XCTAssertEqual(Battery.level(s, now: at(10)), 80, accuracy: 0.001)
        XCTAssertEqual(Battery.level(s, now: at(14)), 0)
        XCTAssertEqual(Battery.emptyAt(s), at(14))
        s = Battery.cycled(s, now: at(9))
        XCTAssertEqual(s.level, 80)
        for _ in 0..<4 { s = Battery.cycled(s, now: at(9)) }
        XCTAssertEqual(s.level, 0)
        XCTAssertFalse(Battery.isDraining(s, now: at(9)))
        XCTAssertNil(Battery.due(s, now: at(10)))
        XCTAssertEqual(Battery.cycled(s, now: at(9)).level, 100)
    }

    func testBatteryStepsThenEmpty() {
        var s = Battery.cycled(Battery.cycled(Battery.cycled(Battery.cycled(Battery.cycled(BatteryState(), now: at(9)), now: at(9)), now: at(9)), now: at(9)), now: at(9))
        XCTAssertEqual(s.level, 20)
        XCTAssertNil(Battery.due(s, now: at(9, 10)))   // 16.7%: still in the 20 step
        var due = Battery.due(s, now: at(9, 31))!         // 9.7%
        XCTAssertEqual(due.event, .step(10))
        s = due.state
        XCTAssertNil(Battery.due(s, now: at(9, 40)))
        due = Battery.due(s, now: at(10, 5))!
        XCTAssertEqual(due.event, .empty(at: at(10)))
        s = due.state
        XCTAssertNil(Battery.due(s, now: at(11)))
    }

    func testBatteryTrack() {
        let entries = [
            LogEntry(at: at(9), source: "battery", name: "Battery", kind: .batterySet, value: 40),
            LogEntry(at: at(13), source: "battery", name: "Battery", kind: .batterySet, value: 100),
        ]
        let track = Battery.track(entries, from: at(0), to: at(14))
        XCTAssertEqual(track.map(\.at), [at(9), at(11), at(13), at(13), at(14)])
        XCTAssertEqual(track.map(\.level), [40, 0, 0, 100, 80])
    }
}
