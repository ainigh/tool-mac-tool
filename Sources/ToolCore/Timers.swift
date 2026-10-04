import Foundation

// The timers: six tiles, each set by clicking it to step through its choices. Two count down once
// and ring until you say OK; two count down, ring softly, sit at zero for five minutes and start
// again until you stop them; two chime on the hour, one through the day and one through the night.
// This is their logic (what's due when, and what the cards say); the app plays and shows it.

public struct TimerSpec: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Counts down once, then rings until you say OK.
        case once
        /// Counts down, rings softly, stays at zero for `hold`, then starts again.
        case repeating
        /// Chimes every hour from 6 AM to 10 PM.
        case dayChime
        /// Chimes every hour from 11 PM to 5 AM.
        case nightChime
    }

    public let id: String
    public let name: String
    public let kind: Kind
    /// The countdowns a click steps through, in seconds (empty for the chimes, which are on or off).
    public let presets: [TimeInterval]

    public init(id: String, name: String, kind: Kind, presets: [TimeInterval] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.presets = presets
    }

    /// How long a repeating timer stays at zero before it starts again.
    public static let hold: TimeInterval = 5 * 60
    /// A countdown that ended longer ago than this (the app was closed, the Mac asleep) is
    /// switched off quietly rather than ringing late; a chime missed by more than `chimeGrace` is skipped.
    public static let lateness: TimeInterval = 60 * 60
    public static let chimeGrace: TimeInterval = 5 * 60

    public static let dayHours = Array(6...22)
    public static let nightHours = [23, 0, 1, 2, 3, 4, 5]

    public static let all: [TimerSpec] = [
        TimerSpec(id: "timer-1", name: "Timer 1", kind: .once, presets: [1, 3, 5, 10, 15].map { $0 * 60 }),
        TimerSpec(id: "timer-2", name: "Timer 2", kind: .once, presets: [20, 30, 45, 60, 90, 120].map { $0 * 60 }),
        TimerSpec(id: "repeat-1", name: "Repeat 1", kind: .repeating, presets: [15, 20, 25, 30].map { $0 * 60 }),
        TimerSpec(id: "repeat-2", name: "Repeat 2", kind: .repeating, presets: [45, 50, 60, 90].map { $0 * 60 }),
        TimerSpec(id: "day-chime", name: "Day chime", kind: .dayChime),
        TimerSpec(id: "night-chime", name: "Night watch", kind: .nightChime),
    ]

    public var isChime: Bool { kind == .dayChime || kind == .nightChime }

    /// The hours it chimes at.
    public var hours: [Int] {
        switch kind {
        case .dayChime: return Self.dayHours
        case .nightChime: return Self.nightHours
        default: return []
        }
    }

    /// The choices a click steps through, then back to off: "5 min", "1 h 30 min"; "On" for a chime.
    public var choices: [String] { isChime ? ["On"] : presets.map(TimerText.duration) }

    /// One click: the next choice, started now (past the last, it's off).
    public func cycled(_ s: TimerState, now: Date) -> TimerState {
        let count = isChime ? 1 : presets.count
        let next = s.choice.map { $0 + 1 } ?? 0
        return next < count ? chose(next, now: now) : TimerState()
    }

    /// A choice picked straight away (from the tile's menu), started now.
    public func chose(_ choice: Int, now: Date) -> TimerState {
        // A chime turned on mid-hour waits for the next hour rather than chiming for this one.
        isChime ? TimerState(choice: 0, start: now, lastChime: now) : TimerState(choice: choice, start: now)
    }

    /// The countdown's length, if it's counting.
    public func duration(_ s: TimerState) -> TimeInterval? {
        guard !isChime, let c = s.choice, presets.indices.contains(c) else { return nil }
        return presets[c]
    }

    public func phase(_ s: TimerState, now: Date) -> TimerPhase {
        guard s.choice != nil, let start = s.start else { return .off }
        if isChime { return .chiming }
        guard let d = duration(s) else { return .off }
        let elapsed = max(0, now.timeIntervalSince(start))
        if kind == .once {
            return elapsed < d ? .counting(remaining: d - elapsed, of: d, round: 0) : .finished
        }
        let period = d + Self.hold
        let round = Int(elapsed / period)
        let into = elapsed - Double(round) * period
        return into < d ? .counting(remaining: d - into, of: d, round: round)
            : .holding(remaining: period - into, round: round)
    }

    /// What should happen now, given what has already happened (`s.rung`, `s.lastChime`), and the
    /// state to keep afterwards. Nil when there's nothing to do.
    public func due(_ s: TimerState, now: Date, calendar: Calendar) -> (event: TimerEvent?, state: TimerState)? {
        guard s.choice != nil, let start = s.start else { return nil }
        switch kind {
        case .once:
            guard let d = duration(s), s.rung == 0, now.timeIntervalSince(start) >= d else { return nil }
            let end = start.addingTimeInterval(d)
            if now.timeIntervalSince(end) > Self.lateness { return (nil, TimerState()) }
            var after = s
            after.rung = 1
            return (.finished(at: end), after)
        case .repeating:
            guard let d = duration(s) else { return nil }
            let period = d + Self.hold
            let elapsed = max(0, now.timeIntervalSince(start))
            let round = Int(elapsed / period)
            let holding = elapsed - Double(round) * period >= d
            // Rounds whose countdown has reached zero so far.
            let done = round + (holding ? 1 : 0)
            guard done > s.rung else { return nil }
            var after = s
            after.rung = done
            // Rounds missed while asleep pass quietly: only the one sitting at zero now rings.
            return (holding ? .roundDone(round: done) : nil, after)
        case .dayChime, .nightChime:
            guard let hour = calendar.dateInterval(of: .hour, for: now)?.start,
                  hours.contains(calendar.component(.hour, from: hour)),
                  hour > (s.lastChime ?? .distantPast) else { return nil }
            var after = s
            after.lastChime = hour
            return (now.timeIntervalSince(hour) <= Self.chimeGrace ? .chime(at: hour) : nil, after)
        }
    }

    /// The next time a chime sounds, after `now`.
    public func nextChime(after now: Date, calendar: Calendar) -> Date? {
        guard isChime, var hour = calendar.dateInterval(of: .hour, for: now)?.start else { return nil }
        for _ in 0..<48 {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { return nil }
            hour = next
            if hours.contains(calendar.component(.hour, from: hour)) { return hour }
        }
        return nil
    }
}

/// What a timer is set to (kept between launches).
public struct TimerState: Codable, Equatable, Sendable {
    /// Which of its presets (0 for a chime that's on); nil when it's off.
    public var choice: Int?
    /// When the countdown (or the first round, or the chime) started.
    public var start: Date?
    /// Once: 1 after it rang. Repeating: the rounds that have reached zero.
    public var rung = 0
    /// The hour a chime last sounded for.
    public var lastChime: Date?

    public init(choice: Int? = nil, start: Date? = nil, rung: Int = 0, lastChime: Date? = nil) {
        self.choice = choice
        self.start = start
        self.rung = rung
        self.lastChime = lastChime
    }

    public var isOn: Bool { choice != nil }
}

public enum TimerPhase: Equatable, Sendable {
    case off
    /// Counting down: what's left, out of how long, and which round (from 0) it's on.
    case counting(remaining: TimeInterval, of: TimeInterval, round: Int)
    /// A one-off countdown at zero, waiting for OK.
    case finished
    /// A repeating countdown at zero; it starts again in `remaining`.
    case holding(remaining: TimeInterval, round: Int)
    /// A chime that's on.
    case chiming
}

public enum TimerEvent: Equatable, Sendable {
    /// A one-off countdown reached zero (at that time).
    case finished(at: Date)
    /// A repeating countdown reached zero for the nth time.
    case roundDone(round: Int)
    /// The chime for that hour.
    case chime(at: Date)
}

/// The words on the tiles and the cards.
public enum TimerText {
    /// "9:59", "1:05:00": what's left, rounded up so it reads 10:00 at the start and 0:01 at the end.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// "45 s", "5 min", "2 h", "1 h 30 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        let h = s / 3600, m = (s % 3600) / 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "1 hour", "5 hours".
    public static func hours(_ n: Int) -> String { n == 1 ? "1 hour" : "\(n) hours" }

    /// "Monday 2 PM".
    public static func label(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEEE h a"
        return f.string(from: date)
    }

    /// "2 PM".
    public static func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    /// The day chime's card: hours since 6 AM, hours to 10 PM, and how far through the day that is.
    public static func day(_ date: Date, calendar: Calendar) -> (title: String, since: String, left: String, progress: Double) {
        let hour = calendar.component(.hour, from: date)
        let since = min(16, max(0, hour - 6)), left = min(16, max(0, 22 - hour))
        return (label(date, calendar: calendar),
                since == 0 ? "The day starts" : "\(hours(since)) since 6 AM",
                left == 0 ? "It's 10 PM: the day is done" : "\(hours(left)) to 10 PM",
                Double(since) / 16)
    }

    /// The night watch's card: how many hours are left before 6 AM.
    public static func night(_ date: Date, calendar: Calendar) -> (title: String, left: String) {
        let hour = calendar.component(.hour, from: date)
        let left = hour >= 6 ? 24 - hour + 6 : 6 - hour
        return (label(date, calendar: calendar), "\(hours(left)) left before 6 AM")
    }
}
