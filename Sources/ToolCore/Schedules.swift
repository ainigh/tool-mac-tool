import Foundation

/// The scheduler's jobs: at the times you set, each does one thing with its text: asks the model
/// (which can use the model tools and your shortcuts), shows it as a reminder, says it out loud,
/// runs one of the model tools, or runs a shortcut, with the text as what it's given.
public struct ScheduledJob: Codable, Equatable, Identifiable {
    /// What a job does with its text.
    public enum Action: String, Codable, CaseIterable {
        /// The text is a prompt: the model answers it, and may call tools while it does.
        case askModel
        /// The text is shown on a card that stays until you close it.
        case remind
        /// The text is read out in the voice from Read aloud.
        case speak
        /// The text is what one of the model tools is given (`target`: its name, e.g. sound_alarm).
        case tool
        /// The text is a shortcut's input (`target`: the shortcut's name).
        case shortcut

        public var title: String {
            switch self {
            case .askModel: return "Ask the model"
            case .remind: return "Remind me"
            case .speak: return "Say it"
            case .tool: return "Model tool"
            case .shortcut: return "Shortcut"
            }
        }

        public var symbol: String {
            switch self {
            case .askModel: return "sparkles"
            case .remind: return "bell"
            case .speak: return "speaker.wave.2"
            case .tool: return "wrench.and.screwdriver"
            case .shortcut: return "bolt.horizontal.circle"
            }
        }

        /// It gives back text worth showing or saying (a reminder is already shown, a spoken line said).
        public var hasResult: Bool { self == .askModel || self == .shortcut }
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    public var action: Action
    /// The model tool's name or the shortcut's name; for Ask the model, a model ("" is the chat's).
    public var target: String
    /// The prompt, the reminder, or what the tool or shortcut is given. {{date}}, {{time}},
    /// {{last}} (the previous result) and {{clipboard}} are filled in when it runs.
    public var text: String
    public var when: Schedule
    /// Ask the model: it may call the model tools and your shortcuts.
    public var useTools: Bool
    /// What happens with a result: a card on screen, read out loud.
    public var showResult: Bool
    public var speakResult: Bool
    /// When it runs next (nil: not again).
    public var next: Date?
    public var lastRun: Date?
    public var lastResult: String?
    public var lastOK: Bool?

    public init(id: String = UUID().uuidString, name: String = "New schedule", enabled: Bool = true,
                action: Action = .remind, target: String = "", text: String = "", when: Schedule = Schedule(),
                useTools: Bool = true, showResult: Bool = true, speakResult: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.action = action
        self.target = target
        self.text = text
        self.when = when
        self.useTools = useTools
        self.showResult = showResult
        self.speakResult = speakResult
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, action, target, text, when, useTools, showResult, speakResult, next, lastRun,
             lastResult, lastOK
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Schedule"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        action = (try? c.decodeIfPresent(Action.self, forKey: .action)) ?? .remind
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        when = (try? c.decodeIfPresent(Schedule.self, forKey: .when)) ?? Schedule()
        useTools = try c.decodeIfPresent(Bool.self, forKey: .useTools) ?? true
        showResult = try c.decodeIfPresent(Bool.self, forKey: .showResult) ?? true
        speakResult = try c.decodeIfPresent(Bool.self, forKey: .speakResult) ?? false
        next = try c.decodeIfPresent(Date.self, forKey: .next)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        lastOK = try c.decodeIfPresent(Bool.self, forKey: .lastOK)
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

/// When a job runs: once at a time, every so many minutes, or at a time of day (on some weekdays).
public struct Schedule: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case once, every, daily

        public var title: String {
            switch self {
            case .once: return "Once"
            case .every: return "Every"
            case .daily: return "At a time of day"
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
    /// is every day).
    public var hour: Int
    public var minute: Int
    public var weekdays: [Int]

    public init(kind: Kind = .daily, at: Date = Date().addingTimeInterval(3600), minutes: Int = 60,
                start: Date = Date(), hour: Int = 9, minute: Int = 0, weekdays: [Int] = []) {
        self.kind = kind
        self.at = at
        self.minutes = minutes
        self.start = start
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    /// The first time after `date` it runs (nil: never again).
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
        }
    }

    /// "Every 15 minutes", "Every 2 hours", "Every day at 09:00", "Mon, Wed, Fri at 18:30",
    /// "Weekdays at 08:00", "Once, Friday 3 October at 14:00".
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
        }
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
}

/// The placeholders a job's text can hold, filled in when it runs.
public enum JobText {
    public static let placeholders = ["{{date}}", "{{time}}", "{{last}}", "{{clipboard}}"]

    public static func fill(_ text: String, now: Date, last: String?, clipboard: String = "",
                            calendar: Calendar = .current, clock24: Bool = true) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = calendar.timeZone
        date.dateFormat = "EEEE d MMMM yyyy"
        let c = calendar.dateComponents([.hour, .minute], from: now)
        return text
            .replacingOccurrences(of: "{{date}}", with: date.string(from: now))
            .replacingOccurrences(of: "{{time}}", with: Schedule.time(hour: c.hour ?? 0, minute: c.minute ?? 0, clock24: clock24))
            .replacingOccurrences(of: "{{last}}", with: last ?? "")
            .replacingOccurrences(of: "{{clipboard}}", with: clipboard)
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
