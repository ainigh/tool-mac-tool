import Foundation

// Send to dashboard: one JSON report per run, POSTed to the dashboard's address (set once, on the
// built-in Send to dashboard action). It carries what set it off, everything that went in the
// timer log since the report before (so a burst that came while one was sending isn't lost), and a
// snapshot of the moment: today's and the week's counts, the battery, the timers running, the
// thresholds and how near each is, and the schedules coming up.

/// What Send to dashboard POSTs.
public struct DashboardReport: Codable, Equatable, Sendable {
    /// Who sent it: the schedule (or "by hand"), when it runs, the action, and the note (its text).
    public struct Trigger: Codable, Equatable, Sendable {
        public var job: String
        public var when: String
        public var action: String
        public var note: String

        public init(job: String, when: String, action: String, note: String = "") {
            self.job = job
            self.when = when
            self.action = action
            self.note = note
        }
    }

    /// One day's counts ("2026-10-04").
    public struct Counts: Codable, Equatable, Sendable {
        public var day: String
        public var alarms: Int
        public var snoozes: Int
        public var sets: Int
        public var stops: Int
        public var chimes: Int
        public var batteryEmpties: Int
        public var thresholds: Int

        public init(_ s: DaySummary, calendar: Calendar) {
            day = DashboardReport.dayString(s.day, calendar: calendar)
            alarms = s.alarms
            snoozes = s.snoozes
            sets = s.sets
            stops = s.stops
            chimes = s.chimes
            batteryEmpties = s.batteryEmpties
            thresholds = s.thresholds
        }
    }

    /// The battery now: its level, whether it's draining, what it was set to and when, and when it
    /// runs out.
    public struct BatteryNow: Codable, Equatable, Sendable {
        public var level: Double
        public var draining: Bool
        public var setTo: Double
        public var setAt: Date
        public var emptyAt: Date?

        public init?(_ s: BatteryState, now: Date) {
            guard let start = s.start else { return nil }
            level = (Battery.level(s, now: now) * 10).rounded() / 10
            draining = Battery.isDraining(s, now: now)
            setTo = s.level
            setAt = start
            emptyAt = Battery.emptyAt(s)
        }
    }

    /// A note running a timer (or ringing).
    public struct TimerNow: Codable, Equatable, Sendable {
        /// The note's title, else where it is.
        public var name: String
        /// "Goals · box 3".
        public var place: String
        /// The timer's name, and what kind it is ("countdown", "deadline" …).
        public var timer: String
        public var kind: String
        /// When it rings (nil: ringing now).
        public var at: Date?
        public var ringing: Bool

        public init(name: String, place: String, timer: String, kind: String, at: Date?) {
            self.name = name
            self.place = place
            self.timer = timer
            self.kind = kind
            self.at = at
            ringing = at == nil
        }
    }

    /// A threshold (a schedule on "A day's count goes over…"), and today's count against it.
    public struct ThresholdNow: Codable, Equatable, Sendable {
        public var rule: String
        public var metric: String
        public var limit: Int
        public var count: Int
        public var enabled: Bool
    }

    /// A schedule: when it runs, and how it last went.
    public struct ScheduleNow: Codable, Equatable, Sendable {
        public var name: String
        public var when: String
        public var action: String
        public var enabled: Bool
        public var next: Date?
        public var lastRun: Date?
        public var lastOK: Bool?
    }

    public var id: String
    public var type = "report"
    public var at: Date
    /// The day it's sent on, in the Mac's time zone, and that time zone.
    public var day: String
    public var timeZone: String
    public var device: String
    public var app = "ToolMacTool"
    public var version: String
    public var trigger: Trigger
    /// What set it off (an event schedule's log entry), as a signal.
    public var event: Signal?
    /// What went in the timer log since the report before (or the last day's, the first time),
    /// oldest first, at most `maxEntries`.
    public var entries: [Signal]
    public var today: Counts
    /// The last 7 days, oldest first (today last).
    public var week: [Counts]
    public var battery: BatteryNow?
    public var timers: [TimerNow]
    public var thresholds: [ThresholdNow]
    /// The schedules that are on, the soonest first (the ones waiting for something after).
    public var schedules: [ScheduleNow]

    public static let maxEntries = 100
    public static let maxSchedules = 30

    /// The report for `now`. `since`: when the last report went (nil: never; the last day's log
    /// goes). `event`/`crossing`: what set it off, and the count it took over the limit.
    public init(id: String = UUID().uuidString, now: Date, calendar: Calendar, device: String, version: String,
                trigger: Trigger, event: LogEntry? = nil, crossing: (rule: ThresholdRule, count: Int)? = nil,
                log: ActivityLog, since: Date?, battery: BatteryState, timers: [TimerNow], jobs: [ScheduledJob],
                actionName: (String) -> String? = { _ in nil }, clock24: Bool = true) {
        self.id = id
        at = now
        day = Self.dayString(now, calendar: calendar)
        timeZone = calendar.timeZone.identifier
        self.device = device
        self.version = version
        self.trigger = trigger
        self.event = event.map { Signal(entry: $0, calendar: calendar, device: device, threshold: crossing) }
        entries = Self.entries(log, since: since, now: now, calendar: calendar, device: device)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let days = log.days(from: weekStart, to: now, calendar: calendar)
        week = days.map { Counts($0, calendar: calendar) }
        let todays = days.last ?? DaySummary(day: calendar.startOfDay(for: now))
        today = Counts(todays, calendar: calendar)
        self.battery = BatteryNow(battery, now: now)
        self.timers = timers
        thresholds = jobs.filter { $0.when.kind == .event && $0.when.event == .countOver }.map { job in
            ThresholdNow(rule: job.when.rule.describe, metric: job.when.metric.rawValue, limit: job.when.limit,
                         count: todays.count(job.when.metric), enabled: job.enabled)
        }
        let on = jobs.filter(\.enabled)
        let timed = on.filter { $0.next != nil }.sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }
        schedules = (timed + on.filter { $0.next == nil }).prefix(Self.maxSchedules).map { job in
            ScheduleNow(name: job.name, when: job.when.describe(clock24: clock24, calendar: calendar),
                        action: actionName(job.actionID) ?? "", enabled: job.enabled, next: job.next,
                        lastRun: job.lastRun, lastOK: job.lastOK)
        }
    }

    /// The log's entries after `since` (the last day's when nil), up to `now`, oldest first: the
    /// newest `maxEntries` of them.
    public static func entries(_ log: ActivityLog, since: Date?, now: Date, calendar: Calendar, device: String) -> [Signal] {
        let from = since ?? now.addingTimeInterval(-86_400)
        let picked = log.entries.filter { $0.at > from && $0.at <= now }.suffix(maxEntries)
        return picked.map { Signal(entry: $0, calendar: calendar, device: device) }
    }

    /// "2026-10-04", in the calendar's time zone.
    public static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
