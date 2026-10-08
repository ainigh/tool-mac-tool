import Foundation

// The timers' log: every time a timer or the battery is set or stopped, an alarm goes off, a
// snooze is used or a threshold is crossed. The report reads it (counts per day, a timeline, the
// battery's level over time), the thresholds watch it, and signals go from it to a web address.

public struct LogEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A timer was set (or the battery): `value` is the countdown in seconds (the level in %).
        case set
        /// Stopped by hand.
        case stopped
        /// An alarm went off (a countdown at zero, a round done, a snooze up).
        case alarm
        case snoozed
        /// OK on an alarm's card.
        case dismissed
        /// The day chime or the night watch.
        case chime
        /// The battery: set to a level (`value`), passed a step on the way down, or ran out.
        case batterySet
        case batteryLevel
        case batteryEmpty
        /// A threshold was crossed (`detail` says which).
        case threshold

        public var words: String {
            switch self {
            case .set: return "Set"
            case .stopped: return "Stopped"
            case .alarm: return "Alarm"
            case .snoozed: return "Snoozed"
            case .dismissed: return "OK"
            case .chime: return "Chime"
            case .batterySet: return "Battery set"
            case .batteryLevel: return "Battery level"
            case .batteryEmpty: return "Battery empty"
            case .threshold: return "Threshold"
            }
        }
    }

    public var id: String
    public var at: Date
    /// Which timer ("timer-1" …, "battery", "thresholds").
    public var source: String
    /// Its name, as shown ("Timer 1", "Battery").
    public var name: String
    public var kind: Kind
    public var detail: String
    public var value: Double?

    public init(id: String = UUID().uuidString, at: Date, source: String, name: String, kind: Kind,
                detail: String = "", value: Double? = nil) {
        self.id = id
        self.at = at
        self.source = source
        self.name = name
        self.kind = kind
        self.detail = detail
        self.value = value
    }
}

public struct ActivityLog: Codable, Equatable, Sendable {
    public var entries: [LogEntry] = []
    /// The oldest go once there are more than this.
    public static let limit = 20_000

    public init(entries: [LogEntry] = []) { self.entries = entries }

    public mutating func add(_ e: LogEntry) {
        entries.append(e)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// How many of a kind on the day `date` is in.
    public func count(_ kind: LogEntry.Kind, on date: Date, calendar: Calendar) -> Int {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return 0 }
        return entries.filter { $0.kind == kind && day.contains($0.at) }.count
    }

    public func entries(from: Date, to: Date) -> [LogEntry] {
        entries.filter { $0.at >= from && $0.at < to }
    }

    /// Each day from `from` to `to` (both included), with its counts, oldest first.
    public func days(from: Date, to: Date, calendar: Calendar) -> [DaySummary] {
        guard var day = calendar.dateInterval(of: .day, for: from)?.start,
              let last = calendar.dateInterval(of: .day, for: to)?.start else { return [] }
        var out: [DaySummary] = []
        while day <= last {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            var summary = DaySummary(day: day)
            for e in entries where e.at >= day && e.at < next { summary.add(e) }
            out.append(summary)
            day = next
        }
        return out
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/timer-log.json")
    }

    public static func load(from url: URL) -> ActivityLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ActivityLog.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One day's counts.
public struct DaySummary: Equatable, Identifiable, Sendable {
    public var day: Date
    public var alarms = 0
    public var snoozes = 0
    public var sets = 0
    public var stops = 0
    public var chimes = 0
    public var batteryEmpties = 0
    public var thresholds = 0
    public var id: Date { day }

    public init(day: Date) { self.day = day }

    /// Whether any timer (or the battery) was set that day.
    public var anySet: Bool { sets > 0 }

    mutating func add(_ e: LogEntry) {
        switch e.kind {
        case .alarm: alarms += 1
        case .snoozed: snoozes += 1
        case .set, .batterySet: sets += 1
        case .stopped: stops += 1
        case .chime: chimes += 1
        case .batteryEmpty: batteryEmpties += 1
        case .threshold: thresholds += 1
        case .dismissed, .batteryLevel: break
        }
    }

    public func count(_ metric: ThresholdRule.Metric) -> Int {
        switch metric {
        case .snoozes: return snoozes
        case .alarms: return alarms
        case .sets: return sets
        case .stops: return stops
        case .batteryEmpties: return batteryEmpties
        }
    }
}

// MARK: - Thresholds

/// "Each time snoozes in a day go over 4": the moment the day's count goes past the limit, a card
/// comes up (and a signal goes out).
public struct ThresholdRule: Codable, Equatable, Identifiable, Sendable {
    public enum Metric: String, Codable, CaseIterable, Sendable {
        case snoozes, alarms, sets, stops, batteryEmpties

        public var words: String {
            switch self {
            case .snoozes: return "Snoozes"
            case .alarms: return "Alarms"
            case .sets: return "Timers set"
            case .stops: return "Timers stopped"
            case .batteryEmpties: return "Batteries emptied"
            }
        }

        /// The log entries it counts.
        public var kinds: Set<LogEntry.Kind> {
            switch self {
            case .snoozes: return [.snoozed]
            case .alarms: return [.alarm]
            case .sets: return [.set, .batterySet]
            case .stops: return [.stopped]
            case .batteryEmpties: return [.batteryEmpty]
            }
        }
    }

    public var id: String
    public var enabled: Bool
    public var metric: Metric
    /// Crossed when the day's count goes over this.
    public var limit: Int

    public init(id: String = UUID().uuidString, enabled: Bool = true, metric: Metric, limit: Int) {
        self.id = id
        self.enabled = enabled
        self.metric = metric
        self.limit = limit
    }

    public var describe: String { "\(metric.words) in a day over \(limit)" }

    /// The rules a new entry crosses: those counting its kind whose limit the day's count (with it)
    /// has just gone past.
    public static func crossed(by entry: LogEntry, rules: [ThresholdRule], log: ActivityLog,
                               calendar: Calendar) -> [(rule: ThresholdRule, count: Int)] {
        guard let day = calendar.dateInterval(of: .day, for: entry.at) else { return [] }
        return rules.compactMap { rule in
            guard rule.enabled, rule.metric.kinds.contains(entry.kind) else { return nil }
            let count = log.entries.filter { rule.metric.kinds.contains($0.kind) && day.contains($0.at) }.count
            return count == rule.limit + 1 ? (rule, count) : nil
        }
    }
}

/// What the timers' log is set to do: the thresholds, and where signals go.
public struct SignalSettings: Codable, Equatable, Sendable {
    public var rules: [ThresholdRule] = [ThresholdRule(metric: .snoozes, limit: 4)]
    /// Where signals are POSTed as JSON (a Cloudflare worker, say). Empty: none are sent.
    public var url = ""
    /// Sent as "Authorization: Bearer <secret>" when it isn't empty.
    public var secret = ""
    /// What goes out: crossed thresholds, the battery's changes, and every alarm and snooze.
    public var sendThresholds = true
    public var sendBattery = true
    public var sendAlarms = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SignalSettings()
        rules = try c.decodeIfPresent([ThresholdRule].self, forKey: .rules) ?? d.rules
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? d.secret
        sendThresholds = try c.decodeIfPresent(Bool.self, forKey: .sendThresholds) ?? d.sendThresholds
        sendBattery = try c.decodeIfPresent(Bool.self, forKey: .sendBattery) ?? d.sendBattery
        sendAlarms = try c.decodeIfPresent(Bool.self, forKey: .sendAlarms) ?? d.sendAlarms
    }

    /// The address, if it's a usable http(s) one.
    public var endpoint: URL? {
        let t = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              u.host?.isEmpty == false else { return nil }
        return u
    }

    /// Whether an entry of this kind goes out as a signal.
    public func sends(_ kind: LogEntry.Kind) -> Bool {
        switch kind {
        case .threshold: return sendThresholds
        case .batterySet, .batteryLevel, .batteryEmpty: return sendBattery
        case .alarm, .snoozed: return sendAlarms
        default: return false
        }
    }
}

/// What's POSTed to the address: one JSON object per signal.
public struct Signal: Codable, Equatable, Sendable {
    public struct Threshold: Codable, Equatable, Sendable {
        public var metric: String
        public var limit: Int
        public var count: Int
        public var rule: String
    }

    /// The log entry's id, so a worker can drop one it has already seen (a retried send).
    public var id: String
    /// "threshold", "battery", "alarm", "snooze", "set", "stop", "dismiss", "chime" or "test".
    public var type: String
    public var kind: String
    public var at: Date
    /// The day it counts towards, in the Mac's time zone ("2026-10-04").
    public var day: String
    public var source: String
    public var name: String
    public var detail: String
    public var value: Double?
    public var threshold: Threshold?
    /// Which Mac sent it: always `anonymousDevice`, never the Mac's own name.
    public var device: String
    public var app = "ToolMacTool"

    public init(entry e: LogEntry, calendar: Calendar, device: String,
                threshold: (rule: ThresholdRule, count: Int)? = nil) {
        id = e.id
        switch e.kind {
        case .threshold: type = "threshold"
        case .batterySet, .batteryLevel, .batteryEmpty: type = "battery"
        case .snoozed: type = "snooze"
        case .set: type = "set"
        case .stopped: type = "stop"
        case .dismissed: type = "dismiss"
        case .chime: type = "chime"
        default: type = e.source == "test" ? "test" : "alarm"
        }
        kind = e.kind.rawValue
        at = e.at
        let c = calendar.dateComponents([.year, .month, .day], from: e.at)
        day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        source = e.source
        name = e.name
        detail = e.detail
        value = e.value
        self.threshold = threshold.map {
            Threshold(metric: $0.rule.metric.rawValue, limit: $0.rule.limit, count: $0.count, rule: $0.rule.describe)
        }
        self.device = device
    }

    /// What every signal and report says for the Mac that sent it.
    public static let anonymousDevice = "SYSTEM"

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - The battery

/// A make-believe battery: set it to a level and it drains 20% an hour, down to 0, where it stops.
public struct BatteryState: Codable, Equatable, Sendable {
    /// Which of `Battery.levels` it was last set to (nil: never).
    public var choice: Int?
    /// The level it was set to, and when.
    public var level: Double = 0
    public var start: Date?
    /// The last 10% step passed on the way down (signalled), and whether it ran out.
    public var reported: Int = 0
    public var emptied = false

    public init(choice: Int? = nil, level: Double = 0, start: Date? = nil) {
        self.choice = choice
        self.level = level
        self.start = start
        self.reported = Int(level)
        self.emptied = level <= 0
    }
}

public enum Battery {
    public static let levels: [Double] = [100, 80, 60, 40, 20, 0]
    /// Percent drained per hour.
    public static let rate = 20.0

    /// One click: the next level, starting to drain now.
    public static func cycled(_ s: BatteryState, now: Date) -> BatteryState {
        let next = s.choice.map { ($0 + 1) % levels.count } ?? 0
        return BatteryState(choice: next, level: levels[next], start: now)
    }

    public static func level(_ s: BatteryState, now: Date) -> Double {
        guard let start = s.start else { return 0 }
        return max(0, s.level - rate * max(0, now.timeIntervalSince(start)) / 3600)
    }

    public static func isDraining(_ s: BatteryState, now: Date) -> Bool { s.start != nil && level(s, now: now) > 0 }

    /// When it runs out.
    public static func emptyAt(_ s: BatteryState) -> Date? {
        guard let start = s.start, s.level > 0 else { return nil }
        return start.addingTimeInterval(s.level / rate * 3600)
    }

    /// The 10% steps still to come on the way down (the next first), and when each is reached:
    /// at 47%, 40% then 30%, 20%, 10% and 0 (empty). Empty when it isn't draining.
    public static func steps(_ s: BatteryState, now: Date) -> [(level: Int, at: Date)] {
        guard let start = s.start, isDraining(s, now: now) else { return [] }
        let l = level(s, now: now)
        var step = Int((l / 10).rounded(.up)) * 10 - 10
        var out: [(level: Int, at: Date)] = []
        while step >= 0 {
            out.append((step, start.addingTimeInterval((s.level - Double(step)) / rate * 3600)))
            step -= 10
        }
        return out
    }

    /// When it was last at 100%: the latest time the log has it set to full (or the setting now,
    /// if that's full and the log doesn't go back that far).
    public static func lastFull(_ s: BatteryState, entries: [LogEntry]) -> Date? {
        let logged = entries.last { $0.kind == .batterySet && ($0.value ?? 0) >= 100 }?.at
        let now = s.level >= 100 ? s.start : nil
        switch (logged, now) {
        case let (a?, b?): return max(a, b)
        default: return logged ?? now
        }
    }

    public enum Event: Equatable, Sendable {
        /// Passed a 10% step on the way down.
        case step(Int)
        case empty(at: Date)
    }

    /// What's happened since last time: a step passed, or it ran out.
    public static func due(_ s: BatteryState, now: Date) -> (event: Event, state: BatteryState)? {
        guard s.start != nil, !s.emptied else { return nil }
        let l = level(s, now: now)
        if l <= 0, let at = emptyAt(s) {
            var after = s
            after.emptied = true
            after.reported = 0
            return (.empty(at: at), after)
        }
        let step = Int((l / 10).rounded(.up)) * 10
        guard step < s.reported else { return nil }
        var after = s
        after.reported = step
        return (.step(step), after)
    }

    /// The level over time, from the log's battery entries: a point where each setting started and
    /// where it ran out (or was set again), for a line chart.
    public static func track(_ entries: [LogEntry], from: Date, to: Date) -> [(at: Date, level: Double)] {
        let sets = entries.filter { $0.kind == .batterySet }.sorted { $0.at < $1.at }
        var out: [(at: Date, level: Double)] = []
        for (i, e) in sets.enumerated() {
            let level = e.value ?? 0
            let end = i + 1 < sets.count ? sets[i + 1].at : to
            let empty = e.at.addingTimeInterval(level / rate * 3600)
            func at(_ t: Date) -> Double { max(0, level - rate * t.timeIntervalSince(e.at) / 3600) }
            guard end > from, e.at < to else { continue }
            let a = max(e.at, from)
            out.append((a, at(a)))
            if empty < end && empty > a {
                out.append((min(empty, to), at(min(empty, to))))
                if end > empty { out.append((min(end, to), 0)) }
            } else {
                out.append((min(end, to), at(min(end, to))))
            }
        }
        return out
    }
}
