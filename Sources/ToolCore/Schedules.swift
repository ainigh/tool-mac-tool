import Foundation

/// The scheduler's jobs: at the times you set (or when something happens: an alarm goes off, the
/// battery gets low, a day's count goes over a limit), each runs an action (`SavedAction`, made in
/// Actions) with the arguments it gives. The day chime and the night watch are built-in jobs: on
/// from the start, and they can't be deleted.
public struct ScheduledJob: Codable, Equatable, Identifiable {
    /// What a step does (what a job did, before actions were their own).
    public typealias Action = ActionStep.Kind

    /// The built-in jobs' ids: on from the start, kept (they can be turned off, not deleted).
    public enum Builtin: String, CaseIterable, Sendable {
        case dayChime = "day-chime"
        case nightWatch = "night-chime"

        /// The built-in action it runs.
        public var action: SavedAction.Builtin {
            switch self {
            case .dayChime: return .dayChime
            case .nightWatch: return .nightWatch
            }
        }

        /// The job as it comes: a chime every hour, through the day or through the night.
        public var job: ScheduledJob {
            switch self {
            case .dayChime:
                return ScheduledJob(id: "builtin-\(rawValue)", name: "Day chime", enabled: true,
                                    when: Schedule(kind: .hourly, minute: 0, hours: Schedule.dayHours), showResult: false,
                                    builtin: rawValue, actionID: action.id)
            case .nightWatch:
                return ScheduledJob(id: "builtin-\(rawValue)", name: "Night watch", enabled: true,
                                    when: Schedule(kind: .hourly, minute: 0, hours: Schedule.nightHours), showResult: false,
                                    builtin: rawValue, actionID: action.id)
            }
        }
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    /// The action it runs (an id in the `ActionBook`; "" when none is picked yet).
    public var actionID: String
    /// The values it gives the action's arguments. {{date}}, {{time}}, {{last}} (the previous
    /// result), {{clipboard}} and the rest are filled in when it runs.
    public var arguments: [ActionArgument]
    /// What it did itself, before actions were their own (an older file, or a job made with one):
    /// made into an action of its own (`ScheduleBook.separate`), and then nil.
    public var inline: ActionStep?
    public var when: Schedule
    /// What happens with a result: a card on screen, read out loud.
    public var showResult: Bool
    public var speakResult: Bool
    /// When it runs next (nil: not again).
    public var next: Date?
    public var lastRun: Date?
    public var lastResult: String?
    public var lastOK: Bool?
    /// Which built-in job this is (`Builtin`), if it's one: it can't be deleted.
    public var builtin: String?

    public var isBuiltin: Bool { builtin != nil }

    /// A job running `actionID`; or, given `action`, one that does that itself until it's separated
    /// into an action of its own (with `target`, `text`, `useTools` and `secret`).
    public init(id: String = UUID().uuidString, name: String = "New schedule", enabled: Bool = true,
                action: Action? = nil, target: String = "", text: String = "", when: Schedule = Schedule(),
                useTools: Bool = true, showResult: Bool = true, speakResult: Bool = false, secret: String = "",
                builtin: String? = nil, actionID: String = "", arguments: [ActionArgument] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.actionID = actionID
        self.arguments = arguments
        self.inline = action.map { ActionStep(kind: $0, target: target, text: text, useTools: useTools, secret: secret) }
        self.when = when
        self.showResult = showResult
        self.speakResult = speakResult
        self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, actionID, arguments, inline, when, showResult, speakResult, next, lastRun,
             lastResult, lastOK, builtin
        // What a job did itself, before actions.
        case action, target, text, useTools, secret
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Schedule"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        actionID = try c.decodeIfPresent(String.self, forKey: .actionID) ?? ""
        arguments = (try? c.decodeIfPresent([ActionArgument].self, forKey: .arguments)) ?? []
        inline = try? c.decodeIfPresent(ActionStep.self, forKey: .inline)
        if inline == nil, actionID.isEmpty, c.contains(.action) {
            // A file from before actions: what the job did becomes its action when it's separated.
            inline = ActionStep(kind: (try? c.decodeIfPresent(Action.self, forKey: .action)) ?? .remind,
                                target: try c.decodeIfPresent(String.self, forKey: .target) ?? "",
                                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                                useTools: try c.decodeIfPresent(Bool.self, forKey: .useTools) ?? true,
                                secret: try c.decodeIfPresent(String.self, forKey: .secret) ?? "")
        }
        when = (try? c.decodeIfPresent(Schedule.self, forKey: .when)) ?? Schedule()
        showResult = try c.decodeIfPresent(Bool.self, forKey: .showResult) ?? true
        speakResult = try c.decodeIfPresent(Bool.self, forKey: .speakResult) ?? false
        next = try c.decodeIfPresent(Date.self, forKey: .next)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        lastOK = try c.decodeIfPresent(Bool.self, forKey: .lastOK)
        builtin = try c.decodeIfPresent(String.self, forKey: .builtin)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(actionID, forKey: .actionID)
        try c.encode(arguments, forKey: .arguments)
        try c.encodeIfPresent(inline, forKey: .inline)
        try c.encode(when, forKey: .when)
        try c.encode(showResult, forKey: .showResult)
        try c.encode(speakResult, forKey: .speakResult)
        try c.encodeIfPresent(next, forKey: .next)
        try c.encodeIfPresent(lastRun, forKey: .lastRun)
        try c.encodeIfPresent(lastResult, forKey: .lastResult)
        try c.encodeIfPresent(lastOK, forKey: .lastOK)
        try c.encodeIfPresent(builtin, forKey: .builtin)
    }

    /// Sets `next` from `now`: the first time the schedule gives after it (nil when it's off, or a
    /// one-off that's past).
    public mutating func plan(from now: Date, calendar: Calendar = .current) {
        next = enabled ? when.next(after: now, calendar: calendar) : nil
    }

    /// Due at `now`.
    public func isDue(_ now: Date) -> Bool {
        guard enabled, let next else { return false }
        return next <= now
    }

    /// After it ran at `now`: what's next. A one-off is done and turns itself off.
    public mutating func ran(at now: Date, ok: Bool, result: String, calendar: Calendar = .current) {
        lastRun = now
        lastOK = ok
        lastResult = result
        if when.kind == .once { enabled = false }
        plan(from: now, calendar: calendar)
    }
}

/// When a job runs: once at a time, every so many minutes, at a time of day (on some weekdays),
/// every hour (through some hours of the day), or when something happens (`ScheduleEvent`).
public struct Schedule: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case once, every, daily, hourly, event

        public var title: String {
            switch self {
            case .once: return "Once"
            case .every: return "Every"
            case .daily: return "At a time of day"
            case .hourly: return "Every hour"
            case .event: return "Event"
            }
        }
    }

    public var kind: Kind
    /// Once: when.
    public var at: Date
    /// Every: how many minutes apart (at least 1), counted from `start`.
    public var minutes: Int
    public var start: Date
    /// At a time of day: the hour and minute, and the weekdays (1 is Sunday … 7 is Saturday; none
    /// is every day). Every hour: the minute past the hour. A start or end of the week or month:
    /// the time of day.
    public var hour: Int
    public var minute: Int
    public var weekdays: [Int]
    /// Every hour: the hours of the day it runs in (none is all of them).
    public var hours: [Int]
    /// Event: what it waits for, and what that needs: the battery's level (in %), or the count a
    /// day must go over (and what's counted).
    public var event: ScheduleEvent
    public var level: Int
    public var metric: ThresholdRule.Metric
    public var limit: Int

    /// The day chime's hours (6 AM to 10 PM) and the night watch's (11 PM to 5 AM).
    public static let dayHours = Array(6...22)
    public static let nightHours = [23, 0, 1, 2, 3, 4, 5]

    public init(kind: Kind = .daily, at: Date = Date().addingTimeInterval(3600), minutes: Int = 60,
                start: Date = Date(), hour: Int = 9, minute: Int = 0, weekdays: [Int] = [], hours: [Int] = [],
                event: ScheduleEvent = .alarmRang, level: Int = 20, metric: ThresholdRule.Metric = .snoozes,
                limit: Int = 4) {
        self.kind = kind
        self.at = at
        self.minutes = minutes
        self.start = start
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.hours = hours
        self.event = event
        self.level = level
        self.metric = metric
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case kind, at, minutes, start, hour, minute, weekdays, hours, event, level, metric, limit
    }

    // A file from before hourly and event schedules has none of their fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Schedule()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? d.kind
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? d.at
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? d.minutes
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? d.start
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? d.minute
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? d.weekdays
        hours = try c.decodeIfPresent([Int].self, forKey: .hours) ?? d.hours
        event = (try? c.decodeIfPresent(ScheduleEvent.self, forKey: .event)) ?? d.event
        level = try c.decodeIfPresent(Int.self, forKey: .level) ?? d.level
        metric = (try? c.decodeIfPresent(ThresholdRule.Metric.self, forKey: .metric)) ?? d.metric
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? d.limit
    }

    /// The first time after `date` it runs (nil: never again, or it waits for something to happen
    /// rather than a time).
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .once:
            return at > date ? at : nil
        case .every:
            let step = TimeInterval(max(1, minutes) * 60)
            if start > date { return start }
            let passed = floor(date.timeIntervalSince(start) / step) + 1
            return start.addingTimeInterval(passed * step)
        case .daily:
            let days = Set(weekdays.filter { (1...7).contains($0) })
            var parts = DateComponents()
            parts.hour = min(23, max(0, hour))
            parts.minute = min(59, max(0, minute))
            parts.second = 0
            var from = date
            // At most a week of days to look through (a day the clock skips is passed over).
            for _ in 0..<8 {
                guard let candidate = calendar.nextDate(after: from, matching: parts, matchingPolicy: .nextTime) else { return nil }
                if days.isEmpty || days.contains(calendar.component(.weekday, from: candidate)) { return candidate }
                from = candidate
            }
            return nil
        case .hourly:
            let allowed = Set(hours.filter { (0...23).contains($0) })
            var parts = DateComponents()
            parts.minute = min(59, max(0, minute))
            parts.second = 0
            var from = date
            // At most two days of hours to look through.
            for _ in 0..<50 {
                guard let candidate = calendar.nextDate(after: from, matching: parts, matchingPolicy: .nextTime) else { return nil }
                if allowed.isEmpty || allowed.contains(calendar.component(.hour, from: candidate)) { return candidate }
                from = candidate
            }
            return nil
        case .event:
            guard event.isTimed else { return nil }
            guard let today = calendar.dateInterval(of: .day, for: date)?.start else { return nil }
            // A start or end of a week or month comes within the next 62 days.
            for offset in 0..<63 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today), event.falls(on: day, calendar: calendar),
                      let candidate = calendar.date(bySettingHour: min(23, max(0, hour)), minute: min(59, max(0, minute)),
                                                    second: 0, of: day) else { continue }
                if candidate > date { return candidate }
            }
            return nil
        }
    }

    /// "Every 15 minutes", "Every 2 hours", "Every day at 09:00", "Mon, Wed, Fri at 18:30",
    /// "Weekdays at 08:00", "Once, Friday 3 October at 14:00", "Every hour, 06:00–22:00",
    /// "When an alarm goes off", "When the battery reaches 20%".
    public func describe(clock24: Bool = true, calendar: Calendar = .current) -> String {
        switch kind {
        case .once:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone
            f.dateFormat = clock24 ? "EEEE d MMMM 'at' HH:mm" : "EEEE d MMMM 'at' h:mm a"
            return "Once, \(f.string(from: at))"
        case .every:
            return "Every " + Schedule.span(minutes)
        case .daily:
            let time = Schedule.time(hour: hour, minute: minute, clock24: clock24)
            let days = Set(weekdays.filter { (1...7).contains($0) })
            if days.isEmpty || days.count == 7 { return "Every day at \(time)" }
            if days == [2, 3, 4, 5, 6] { return "Weekdays at \(time)" }
            if days == [1, 7] { return "Weekends at \(time)" }
            return days.sorted { Schedule.mondayFirst($0) < Schedule.mondayFirst($1) }
                .map { Schedule.dayNames[$0 - 1] }.joined(separator: ", ") + " at \(time)"
        case .hourly:
            let past = minute == 0 ? "" : String(format: " at :%02d", min(59, max(0, minute)))
            let ranges = Schedule.hourRanges(hours)
            if ranges.isEmpty { return "Every hour" + past }
            let spans = ranges.map { r -> String in
                let a = Schedule.time(hour: r.from, minute: minute, clock24: clock24)
                return r.from == r.to ? a : "\(a)–\(Schedule.time(hour: r.to, minute: minute, clock24: clock24))"
            }
            return "Every hour\(past), " + spans.joined(separator: ", ")
        case .event:
            let time = Schedule.time(hour: hour, minute: minute, clock24: clock24)
            switch event {
            case .batteryAt: return level <= 0 ? "When the battery runs out" : "When the battery reaches \(level)%"
            case .countOver: return "When \(metric.words.lowercased()) in a day go over \(limit)"
            case .startOfWeek, .endOfWeek, .startOfMonth, .endOfMonth: return "\(event.title) at \(time)"
            default: return event.sentence
            }
        }
    }

    /// The hours as runs of neighbours, sorted, a run through midnight kept whole: [23, 0…5] is
    /// 23 to 5. Empty when it's none or all of them.
    public static func hourRanges(_ hours: [Int]) -> [(from: Int, to: Int)] {
        let set = Set(hours.filter { (0...23).contains($0) })
        guard !set.isEmpty, set.count < 24 else { return [] }
        var runs: [(from: Int, to: Int)] = []
        for h in set.sorted() {
            if let last = runs.last, last.to == h - 1 { runs[runs.count - 1].to = h } else { runs.append((h, h)) }
        }
        if runs.count > 1, runs.first?.from == 0, runs.last?.to == 23 {
            let first = runs.removeFirst()
            runs[runs.count - 1].to = first.to
        }
        return runs
    }

    /// Sun … Sat, by weekday number (1 is Sunday).
    public static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    /// Monday to Sunday, as weekday numbers: the order the editor shows them.
    public static let week = [2, 3, 4, 5, 6, 7, 1]
    static func mondayFirst(_ day: Int) -> Int { (day + 5) % 7 }

    /// "15 minutes", "1 hour", "1 hour 30 minutes", "2 days".
    public static func span(_ minutes: Int) -> String {
        let m = max(1, minutes)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if m % 1440 == 0 { return m == 1440 ? "day" : unit(m / 1440, "day") }
        if m % 60 == 0 { return m == 60 ? "hour" : unit(m / 60, "hour") }
        if m > 60 { return "\(unit(m / 60, "hour")) \(unit(m % 60, "minute"))" }
        return m == 1 ? "minute" : unit(m, "minute")
    }

    public static func time(hour: Int, minute: Int, clock24: Bool) -> String {
        if clock24 { return String(format: "%02d:%02d", hour, minute) }
        let h = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", h, minute, hour < 12 ? "AM" : "PM")
    }

    /// Whether this log entry is what an event schedule waits for. `log` already holds the entry
    /// (a day's count includes it).
    public func matches(_ entry: LogEntry, log: ActivityLog, calendar: Calendar = .current) -> Bool {
        guard kind == .event else { return false }
        switch event {
        case .alarmSet: return entry.kind == .set
        case .alarmRang: return entry.kind == .alarm
        case .alarmSnoozed: return entry.kind == .snoozed
        case .alarmStopped: return entry.kind == .stopped
        case .alarmDismissed: return entry.kind == .dismissed
        case .batteryAt:
            let at = Int((entry.value ?? -1).rounded())
            switch entry.kind {
            case .batteryLevel, .batterySet: return at == level
            case .batteryEmpty: return level <= 0
            default: return false
            }
        case .batteryChange: return entry.kind == .batterySet || entry.kind == .batteryLevel || entry.kind == .batteryEmpty
        case .chime: return entry.kind == .chime
        case .countOver: return crossing(entry, log: log, calendar: calendar) != nil
        case .thresholdCrossed: return entry.kind == .threshold
        case .startOfWeek, .endOfWeek, .startOfMonth, .endOfMonth, .appLaunch, .macWake: return false
        }
    }

    /// The limit a count-over schedule watches, as a threshold rule.
    public var rule: ThresholdRule { ThresholdRule(id: "schedule", metric: metric, limit: max(0, limit)) }

    /// The day's count, when this entry has just taken it over the limit.
    public func crossing(_ entry: LogEntry, log: ActivityLog, calendar: Calendar = .current) -> Int? {
        guard kind == .event, event == .countOver else { return nil }
        return ThresholdRule.crossed(by: entry, rules: [rule], log: log, calendar: calendar).first?.count
    }
}

/// What an event schedule waits for: something in the timer log (an alarm set, going off, snoozed,
/// stopped or OK'd; the battery; a chime; a day's count going over a limit), a start or end of
/// the week or month, the app starting, or the Mac waking.
public enum ScheduleEvent: String, Codable, CaseIterable, Sendable {
    case alarmSet, alarmRang, alarmSnoozed, alarmStopped, alarmDismissed
    case batteryAt, batteryChange
    case chime
    case countOver, thresholdCrossed
    case startOfWeek, endOfWeek, startOfMonth, endOfMonth
    case appLaunch, macWake

    public var title: String {
        switch self {
        case .alarmSet: return "An alarm is set"
        case .alarmRang: return "An alarm goes off"
        case .alarmSnoozed: return "An alarm is snoozed"
        case .alarmStopped: return "An alarm is stopped"
        case .alarmDismissed: return "An alarm is OK'd"
        case .batteryAt: return "The battery is at…"
        case .batteryChange: return "The battery changes"
        case .chime: return "A chime sounds"
        case .countOver: return "A day's count goes over…"
        case .thresholdCrossed: return "Any threshold is crossed"
        case .startOfWeek: return "Start of the week"
        case .endOfWeek: return "End of the week"
        case .startOfMonth: return "Start of the month"
        case .endOfMonth: return "End of the month"
        case .appLaunch: return "The app starts"
        case .macWake: return "The Mac wakes"
        }
    }

    /// "When an alarm goes off".
    public var sentence: String {
        switch self {
        case .alarmSet: return "When an alarm is set"
        case .alarmRang: return "When an alarm goes off"
        case .alarmSnoozed: return "When an alarm is snoozed"
        case .alarmStopped: return "When an alarm is stopped"
        case .alarmDismissed: return "When an alarm is OK'd"
        case .batteryAt: return "When the battery reaches a level"
        case .batteryChange: return "When the battery is set, passes 10%, or runs out"
        case .chime: return "When a chime sounds"
        case .countOver: return "When a day's count goes over a limit"
        case .thresholdCrossed: return "When any threshold is crossed"
        case .startOfWeek: return "Every Monday"
        case .endOfWeek: return "Every Sunday"
        case .startOfMonth: return "On the 1st of every month"
        case .endOfMonth: return "On the last day of every month"
        case .appLaunch: return "When Tool Mac Tool starts"
        case .macWake: return "When the Mac wakes from sleep"
        }
    }

    public var symbol: String {
        switch self {
        case .alarmSet: return "alarm"
        case .alarmRang: return "alarm.waves.left.and.right"
        case .alarmSnoozed: return "zzz"
        case .alarmStopped: return "stop.circle"
        case .alarmDismissed: return "checkmark.circle"
        case .batteryAt: return "battery.25"
        case .batteryChange: return "battery.100"
        case .chime: return "bell"
        case .countOver: return "exclamationmark.octagon"
        case .thresholdCrossed: return "chart.line.uptrend.xyaxis"
        case .startOfWeek, .endOfWeek: return "calendar"
        case .startOfMonth, .endOfMonth: return "calendar.circle"
        case .appLaunch: return "power"
        case .macWake: return "sun.horizon"
        }
    }

    /// The menu's groups, in order.
    public static let groups: [(title: String, events: [ScheduleEvent])] = [
        ("Alarms", [.alarmSet, .alarmRang, .alarmSnoozed, .alarmStopped, .alarmDismissed]),
        ("Battery", [.batteryAt, .batteryChange]),
        ("Timer log", [.chime, .countOver, .thresholdCrossed]),
        ("Calendar", [.startOfWeek, .endOfWeek, .startOfMonth, .endOfMonth]),
        ("This Mac", [.appLaunch, .macWake]),
    ]

    /// It comes at a time of day on certain days, rather than when something happens.
    public var isTimed: Bool { [.startOfWeek, .endOfWeek, .startOfMonth, .endOfMonth].contains(self) }

    /// It's something that goes into the timer log.
    public var isLogged: Bool { !isTimed && self != .appLaunch && self != .macWake }

    /// Whether `day` is one it comes on (a timed one).
    public func falls(on day: Date, calendar: Calendar) -> Bool {
        switch self {
        case .startOfWeek: return calendar.component(.weekday, from: day) == 2
        case .endOfWeek: return calendar.component(.weekday, from: day) == 1
        case .startOfMonth: return calendar.component(.day, from: day) == 1
        case .endOfMonth:
            guard let days = calendar.range(of: .day, in: .month, for: day) else { return false }
            return calendar.component(.day, from: day) == days.count
        default: return false
        }
    }
}

/// The placeholders a job's text can hold, filled in when it runs.
public enum JobText {
    public struct Placeholder: Equatable, Sendable {
        public let token: String
        public let help: String
    }

    /// Every placeholder, in groups: the time it runs, the job itself, what happened (for an event
    /// schedule), and the timer log.
    public static let groups: [(title: String, items: [Placeholder])] = [
        ("Time", [
            Placeholder(token: "{{date}}", help: "Today's date when it runs"),
            Placeholder(token: "{{time}}", help: "The time when it runs"),
            Placeholder(token: "{{weekday}}", help: "The day of the week (Monday)"),
            Placeholder(token: "{{month}}", help: "The month (October)"),
            Placeholder(token: "{{day_of_month}}", help: "The day of the month (5)"),
            Placeholder(token: "{{days_left_in_month}}", help: "Days left in the month after today"),
        ]),
        ("This job", [
            Placeholder(token: "{{last}}", help: "What it gave back the last time it ran"),
            Placeholder(token: "{{clipboard}}", help: "What's on the clipboard when it runs"),
            Placeholder(token: "{{job}}", help: "This schedule's name"),
            Placeholder(token: "{{when}}", help: "When it runs, in words (When an alarm goes off)"),
        ]),
        ("What happened", [
            Placeholder(token: "{{event}}", help: "What set it off, in words (Alarm · Goals 3 · Timer 1). Empty unless it waits for an event"),
            Placeholder(token: "{{event_name}}", help: "Which timer or thing it was (Goals 3 · Timer 1)"),
            Placeholder(token: "{{event_detail}}", help: "The event's detail (Time's up · 5 min, 40%)"),
            Placeholder(token: "{{event_value}}", help: "The event's number (seconds set, the battery's %, a day's count)"),
            Placeholder(token: "{{event_time}}", help: "When it happened"),
            Placeholder(token: "{{count}}", help: "A day's count that went over the limit"),
            Placeholder(token: "{{limit}}", help: "The limit it went over"),
        ]),
        ("Timer log", [
            Placeholder(token: "{{alarms_today}}", help: "Alarms that went off today"),
            Placeholder(token: "{{snoozes_today}}", help: "Snoozes used today"),
            Placeholder(token: "{{sets_today}}", help: "Timers (and the battery) set today"),
            Placeholder(token: "{{stops_today}}", help: "Timers stopped today"),
            Placeholder(token: "{{chimes_today}}", help: "Chimes today"),
            Placeholder(token: "{{alarms_week}}", help: "Alarms in the last 7 days"),
            Placeholder(token: "{{snoozes_week}}", help: "Snoozes in the last 7 days"),
            Placeholder(token: "{{last_alarm}}", help: "The last alarm that went off, and when"),
            Placeholder(token: "{{next_alarm}}", help: "The next alarm coming up in the boards' notes"),
            Placeholder(token: "{{battery}}", help: "The battery's level now"),
            Placeholder(token: "{{battery_empty}}", help: "When the battery runs out"),
        ]),
    ]

    /// Every token, in order.
    public static var placeholders: [String] { groups.flatMap { $0.items.map(\.token) } }

    /// The text with its placeholders filled in: the time ones from `now`, the rest from `values`
    /// (keyed by the name inside the braces). A known placeholder with no value is left empty.
    public static func fill(_ text: String, now: Date, last: String?, clipboard: String = "",
                            calendar: Calendar = .current, clock24: Bool = true, values: [String: String] = [:]) -> String {
        var all = timeValues(now, calendar: calendar, clock24: clock24)
        all["last"] = last ?? ""
        all["clipboard"] = clipboard
        for (k, v) in values { all[k] = v }
        var out = text
        for token in placeholders {
            let key = String(token.dropFirst(2).dropLast(2))
            out = out.replacingOccurrences(of: token, with: all[key] ?? "")
        }
        // Anything else asked for by name that there's a value for.
        for (k, v) in values where !placeholders.contains("{{\(k)}}") {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return out
    }

    /// The time's placeholders.
    public static func timeValues(_ now: Date, calendar: Calendar, clock24: Bool) -> [String: String] {
        func format(_ f: String) -> String {
            let d = DateFormatter()
            d.locale = Locale(identifier: "en_US_POSIX")
            d.timeZone = calendar.timeZone
            d.calendar = calendar
            d.dateFormat = f
            return d.string(from: now)
        }
        let c = calendar.dateComponents([.hour, .minute, .day], from: now)
        let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        return [
            "date": format("EEEE d MMMM yyyy"),
            "time": Schedule.time(hour: c.hour ?? 0, minute: c.minute ?? 0, clock24: clock24),
            "weekday": format("EEEE"),
            "month": format("MMMM"),
            "day_of_month": "\(c.day ?? 1)",
            "days_left_in_month": "\(max(0, days - (c.day ?? 1)))",
        ]
    }

    /// The timer log's placeholders: today's and the week's counts, and the last alarm.
    public static func logValues(_ log: ActivityLog, now: Date, calendar: Calendar, clock24: Bool = true) -> [String: String] {
        let today = log.days(from: now, to: now, calendar: calendar).first ?? DaySummary(day: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        let week = log.days(from: weekStart, to: now, calendar: calendar)
        var out = [
            "alarms_today": "\(today.alarms)",
            "snoozes_today": "\(today.snoozes)",
            "sets_today": "\(today.sets)",
            "stops_today": "\(today.stops)",
            "chimes_today": "\(today.chimes)",
            "alarms_week": "\(week.map(\.alarms).reduce(0, +))",
            "snoozes_week": "\(week.map(\.snoozes).reduce(0, +))",
            "last_alarm": "none yet",
        ]
        if let last = log.entries.last(where: { $0.kind == .alarm && $0.at <= now }) {
            out["last_alarm"] = "\(last.name) at \(stamp(last.at, now: now, calendar: calendar, clock24: clock24))"
        }
        return out
    }

    /// What happened, for an event schedule's placeholders.
    public static func eventValues(_ entry: LogEntry, now: Date, calendar: Calendar, clock24: Bool = true) -> [String: String] {
        let value = entry.value.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) } ?? ""
        return [
            "event": [entry.kind.words, entry.name, entry.detail].filter { !$0.isEmpty }.joined(separator: " · "),
            "event_name": entry.name,
            "event_detail": entry.detail,
            "event_value": value,
            "event_time": stamp(entry.at, now: now, calendar: calendar, clock24: clock24),
        ]
    }

    /// "14:05" today, else "Mon 3 Oct 14:05".
    static func stamp(_ date: Date, now: Date, calendar: Calendar, clock24: Bool) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = Schedule.time(hour: c.hour ?? 0, minute: c.minute ?? 0, clock24: clock24)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = calendar.timeZone
        d.dateFormat = "EEE d MMM"
        return "\(d.string(from: date)) \(time)"
    }
}

/// What a job that calls a web address sends: its text (filled in) when it has some, as JSON if
/// it reads as JSON; otherwise the event as the timer log's signals sent it, or the job and the time.
public enum WebCall {
    public static func body(text: String, job: ScheduledJob, entry: LogEntry?, crossing: Int?, now: Date,
                            calendar: Calendar, device: String) -> (data: Data, contentType: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let data = Data(trimmed.utf8)
            let json = (try? JSONSerialization.jsonObject(with: data)) != nil
            return (data, json ? "application/json" : "text/plain; charset=utf-8")
        }
        if let entry {
            let threshold = crossing.map { (rule: job.when.rule, count: $0) }
            if let data = try? Signal(entry: entry, calendar: calendar, device: device, threshold: threshold).json() {
                return (data, "application/json")
            }
        }
        let iso = ISO8601DateFormatter()
        let object: [String: Any] = ["type": "schedule", "id": UUID().uuidString, "name": job.name,
                                     "when": job.when.describe(calendar: calendar), "at": iso.string(from: now),
                                     "device": device, "app": "ToolMacTool"]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (data, "application/json")
    }
}

/// One run of a job, for its history.
public struct JobRun: Codable, Equatable, Identifiable {
    public var id: String
    public var job: String
    public var name: String
    public var at: Date
    public var ok: Bool
    /// What it gave back, or what went wrong.
    public var output: String
    /// The tools the model called while it ran.
    public var tools: [String]

    public init(id: String = UUID().uuidString, job: String, name: String, at: Date, ok: Bool, output: String,
                tools: [String] = []) {
        self.id = id
        self.job = job
        self.name = name
        self.at = at
        self.ok = ok
        self.output = output
        self.tools = tools
    }
}

/// The jobs and their history, in ~/Library/Application Support/ToolMacTool/schedules.json.
public struct ScheduleBook: Codable, Equatable {
    public var jobs: [ScheduledJob] = []
    /// Newest first, at most `keep`.
    public var runs: [JobRun] = []
    public static let keep = 300
    /// The most of a result that's kept.
    public static let maxOutput = 20_000

    public init(jobs: [ScheduledJob] = [], runs: [JobRun] = []) {
        self.jobs = jobs
        self.runs = runs
    }

    public mutating func record(_ run: JobRun) {
        var r = run
        if r.output.count > Self.maxOutput { r.output = String(r.output.prefix(Self.maxOutput)) + "\n…(cut short)" }
        runs.insert(r, at: 0)
        if runs.count > Self.keep { runs.removeLast(runs.count - Self.keep) }
    }

    public func runs(of job: String) -> [JobRun] { runs.filter { $0.job == job } }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/schedules.json")
    }

    public static func load(from url: URL) -> ScheduleBook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScheduleBook.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The built-in jobs are all there (one that's missing is added, on); they go first, each
    /// running its built-in action.
    public mutating func ensureBuiltins() {
        for b in ScheduledJob.Builtin.allCases.reversed() where !jobs.contains(where: { $0.builtin == b.rawValue }) {
            jobs.insert(b.job, at: 0)
        }
        for i in jobs.indices {
            if let b = jobs[i].builtin.flatMap(ScheduledJob.Builtin.init(rawValue:)) {
                jobs[i].actionID = b.action.id
                jobs[i].inline = nil
            }
        }
    }

    /// Each job that still does something itself (from before actions) gets an action of its own,
    /// named after it, doing that; the job runs it from then on. Returns whether anything changed.
    @discardableResult
    public mutating func separate(into book: inout ActionBook) -> Bool {
        var changed = false
        for i in jobs.indices {
            guard let step = jobs[i].inline else { continue }
            if let b = jobs[i].builtin.flatMap(ScheduledJob.Builtin.init(rawValue:)) {
                jobs[i].actionID = b.action.id
            } else {
                let action = SavedAction(name: jobs[i].name.isEmpty ? "Action" : jobs[i].name, steps: [step])
                book.actions.append(action)
                jobs[i].actionID = action.id
            }
            jobs[i].inline = nil
            changed = true
        }
        return changed
    }

    /// The jobs that run an action (by its id).
    public func jobs(running id: String) -> [ScheduledJob] { jobs.filter { $0.actionID == id } }

    /// The timer log's thresholds and signals, as schedules: each threshold waits for its count to
    /// go over the limit and puts up a card; each kind of signal that was sent becomes a job that
    /// calls the address when that happens (sending the same JSON the signals did).
    public static func fromSignals(_ s: SignalSettings) -> [ScheduledJob] {
        var out: [ScheduledJob] = s.rules.map { rule in
            ScheduledJob(name: "Threshold: \(rule.describe)", enabled: rule.enabled, action: .remind,
                         text: "{{count}} today: over your limit of {{limit}}.",
                         when: Schedule(kind: .event, event: .countOver, metric: rule.metric, limit: rule.limit))
        }
        guard let url = s.endpoint?.absoluteString else { return out }
        func call(_ name: String, _ event: ScheduleEvent) -> ScheduledJob {
            ScheduledJob(name: name, action: .webhook, target: url, when: Schedule(kind: .event, event: event),
                         showResult: false, secret: s.secret)
        }
        if s.sendThresholds { out.append(call("Signal: thresholds crossed", .thresholdCrossed)) }
        if s.sendBattery { out.append(call("Signal: the battery", .batteryChange)) }
        if s.sendAlarms {
            out.append(call("Signal: alarms", .alarmRang))
            out.append(call("Signal: snoozes", .alarmSnoozed))
        }
        return out
    }

    /// Some to start from, turned off.
    public static var examples: [ScheduledJob] {
        [
            ScheduledJob(name: "Stretch", enabled: false, action: .remind,
                         text: "Stand up, stretch, and look away from the screen for a minute.",
                         when: Schedule(kind: .every, minutes: 60)),
            ScheduledJob(name: "Morning briefing", enabled: false, action: .askModel,
                         text: "It's {{date}}, {{time}}. Give me a short, friendly start to the day: what kind of day of the week it is, one thing worth focusing on, and a line of encouragement.",
                         when: Schedule(kind: .daily, hour: 8, minute: 30, weekdays: [2, 3, 4, 5, 6]),
                         showResult: true, speakResult: true),
        ]
    }
}
