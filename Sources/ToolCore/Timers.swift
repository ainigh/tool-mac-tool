import Foundation

// The timers. Two count down once and ring until you say OK; two count down, ring softly, sit at
// zero for five minutes and start again until you stop them; a due date counts down to a day and
// time you pick (days, months or years ahead) and rings then. Those five are set per box on the
// boards, one at a time. Two more chime on the hour, one through the day and one through the
// night, from the panel. This is their logic (what's due when, and what the cards say); the app
// plays and shows it.

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
        /// Counts down to a date and time (`TimerState.until`), with reminders on the way; rings
        /// until you say OK, even if that's long after (the Mac was off when it came).
        case deadline
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

    /// A snooze rings again this much later (once per countdown, or per round).
    public static let snooze: TimeInterval = 3 * 60
    /// A reminder is shown only when it's this fresh (not when the Mac wakes long after it).
    public static let reminderGrace: TimeInterval = 15

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

    /// The four countdowns a box can run.
    public static var countdowns: [TimerSpec] { all.filter { $0.kind == .once || $0.kind == .repeating } }
    /// The two chimes, set from the panel.
    public static var chimes: [TimerSpec] { all.filter(\.isChime) }
    /// The due date: a countdown to a day and time you pick.
    public static let deadline = TimerSpec(id: "due", name: "Due date", kind: .deadline)
    /// What a box can run, one at a time: the four countdowns and a due date.
    public static var forBoxes: [TimerSpec] { countdowns + [deadline] }

    public var isChime: Bool { kind == .dayChime || kind == .nightChime }
    /// Counts down once to a moment and waits there for OK.
    public var isOneOff: Bool { kind == .once || kind == .deadline }

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

    /// A due date set for `until`, counting from now (its only choice is 0).
    public func due(until: Date, now: Date) -> TimerState {
        var s = TimerState(choice: 0, start: now)
        s.until = until
        return s
    }

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

    /// The reminders of a countdown, as the time left at each: halving what's left, rounded down
    /// to whole minutes, none under a minute. 60 min: 30, 15, 7, 3 and 1 min left.
    public static func reminders(for duration: TimeInterval) -> [TimeInterval] {
        var out: [TimeInterval] = []
        var left = duration / 2
        while left >= 60 {
            let minutes = (left / 60).rounded(.down) * 60
            if out.last != minutes { out.append(minutes) }
            left /= 2
        }
        return out
    }

    /// The marks a countdown of this kind reminds you at: a due date's are whole spans (a month, a
    /// week, a day, an hour…), the others' halve what's left.
    public func reminderMarks(for duration: TimeInterval) -> [TimeInterval] {
        kind == .deadline ? Self.deadlineReminders(for: duration) : Self.reminders(for: duration)
    }

    /// A due date's reminders, as the time left at each: the spans below that fit in nine tenths
    /// of the wait (so none comes the moment it's set). A week: 3 days, 2 days, 1 day, 12, 6, 3
    /// and 1 hours, then 30, 15, 5 and 1 minutes.
    public static func deadlineReminders(for duration: TimeInterval) -> [TimeInterval] {
        let day: TimeInterval = 86_400
        let marks: [TimeInterval] = [365 * day, 182 * day, 91 * day, 30 * day, 14 * day, 7 * day, 3 * day, 2 * day, day,
                                     12 * 3600, 6 * 3600, 3 * 3600, 3600, 30 * 60, 15 * 60, 5 * 60, 60]
        return marks.filter { $0 <= duration * 0.9 }
    }

    /// Whether its snooze can still be used now: a finished one-off countdown, or a repeating one at
    /// zero, that hasn't been snoozed yet (this round).
    public func canSnooze(_ s: TimerState, now: Date) -> Bool {
        guard s.snoozeAt == nil else { return false }
        switch phase(s, now: now) {
        case .finished: return s.snoozedRound == nil
        // Only while there's time for it before the next round starts.
        case .holding(let left, let round): return s.snoozedRound != round && left > Self.snooze
        default: return false
        }
    }

    /// Snoozed: it rings again in three minutes.
    public func snoozed(_ s: TimerState, now: Date) -> TimerState {
        guard canSnooze(s, now: now) else { return s }
        var after = s
        after.snoozeAt = now.addingTimeInterval(Self.snooze)
        if case .holding(_, let round) = phase(s, now: now) { after.snoozedRound = round } else { after.snoozedRound = 0 }
        return after
    }

    /// The countdown's length, if it's counting.
    public func duration(_ s: TimerState) -> TimeInterval? {
        if kind == .deadline {
            guard s.choice != nil, let start = s.start, let until = s.until else { return nil }
            return max(1, until.timeIntervalSince(start))
        }
        guard !isChime, let c = s.choice, presets.indices.contains(c) else { return nil }
        return presets[c]
    }

    public func phase(_ s: TimerState, now: Date) -> TimerPhase {
        guard s.choice != nil, let start = s.start else { return .off }
        if isChime { return .chiming }
        guard let d = duration(s) else { return .off }
        let elapsed = max(0, now.timeIntervalSince(start))
        if isOneOff {
            if elapsed < d { return .counting(remaining: d - elapsed, of: d, round: 0) }
            if let at = s.snoozeAt, at > now { return .snoozed(remaining: at.timeIntervalSince(now)) }
            return .finished
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
        case .once, .deadline:
            guard let d = duration(s) else { return nil }
            if let snoozed = snoozeDue(s, now: now) { return snoozed }
            let end = start.addingTimeInterval(d)
            if now < end { return reminderDue(s, remaining: end.timeIntervalSince(now), duration: d, round: 0) }
            guard s.rung == 0 else { return nil }
            // A due date still rings when it was missed: you set it to be told.
            if kind == .once, now.timeIntervalSince(end) > Self.lateness { return (nil, TimerState()) }
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
            if done > s.rung {
                var after = s
                after.rung = done
                // Rounds missed while asleep pass quietly: only the one sitting at zero now rings.
                return (holding ? .roundDone(round: done) : nil, after)
            }
            if let snoozed = snoozeDue(s, now: now) { return snoozed }
            if holding { return nil }
            let into = elapsed - Double(round) * period
            return reminderDue(s, remaining: d - into, duration: d, round: round)
        case .dayChime, .nightChime:
            guard let hour = calendar.dateInterval(of: .hour, for: now)?.start,
                  hours.contains(calendar.component(.hour, from: hour)),
                  hour > (s.lastChime ?? .distantPast) else { return nil }
            var after = s
            after.lastChime = hour
            return (now.timeIntervalSince(hour) <= Self.chimeGrace ? .chime(at: hour) : nil, after)
        }
    }

    /// A snooze that's up: it rings again (unless it's long past, when it passes quietly).
    private func snoozeDue(_ s: TimerState, now: Date) -> (event: TimerEvent?, state: TimerState)? {
        guard let at = s.snoozeAt, now >= at else { return nil }
        var after = s
        after.snoozeAt = nil
        return (now.timeIntervalSince(at) <= Self.lateness ? .snoozeOver(round: s.snoozedRound ?? 0) : nil, after)
    }

    /// The reminder for the time left now, if one has been reached and not shown yet (this round).
    private func reminderDue(_ s: TimerState, remaining: TimeInterval, duration: TimeInterval,
                             round: Int) -> (event: TimerEvent?, state: TimerState)? {
        // The smallest mark reached so far.
        guard let mark = reminderMarks(for: duration).last(where: { remaining <= $0 }) else { return nil }
        let shown = s.remindedRound == round ? s.reminded : nil
        if let shown, shown <= mark { return nil }
        var after = s
        after.reminded = mark
        after.remindedRound = round
        return (mark - remaining <= Self.reminderGrace ? .reminder(left: remaining) : nil, after)
    }

    /// When it next rings (a countdown reaching zero, a snooze running out), if it's counting
    /// towards that now; nil when it's off, at zero waiting for OK, or a chime.
    public func nextRing(_ s: TimerState, now: Date) -> Date? {
        switch phase(s, now: now) {
        case .counting(let left, _, _), .snoozed(let left):
            return now.addingTimeInterval(left)
        case .holding(let left, let round):
            if let at = s.snoozeAt, s.snoozedRound == round, at > now { return at }
            return duration(s).map { now.addingTimeInterval(left + $0) }
        case .off, .finished, .chiming:
            return nil
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
    /// A snooze: when it rings again, and which round it was used in (0 for a one-off countdown).
    public var snoozeAt: Date?
    public var snoozedRound: Int?
    /// The last reminder shown (as the time left at its mark), and in which round.
    public var reminded: TimeInterval?
    public var remindedRound: Int?
    /// What a due date counts down to.
    public var until: Date?

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
    /// A finished one-off countdown, snoozed: it rings again in `remaining`.
    case snoozed(remaining: TimeInterval)
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
    /// A reminder on the way down: this much is left.
    case reminder(left: TimeInterval)
    /// A snooze is up: it rings again.
    case snoozeOver(round: Int)
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

    /// "4:59", "1:05:00", and past a day "3d 04:12:09": a countdown that may run for months.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        let d = s / 86_400
        guard d > 0 else { return clock(seconds) }
        let h = (s % 86_400) / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%dd %02d:%02d:%02d", d, h, m, sec)
    }

    /// "2 y 30 d", "45 d 6 h", "3 d", and under a day as `left` does: a long time left.
    public static func span(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded())
        let d = s / 86_400
        guard d > 0 else { return left(seconds) }
        let y = d / 365, days = d % 365, h = (s % 86_400) / 3600
        if y > 0 { return days == 0 ? "\(y) y" : "\(y) y \(days) d" }
        return h == 0 ? "\(d) d" : "\(d) d \(h) h"
    }

    /// "30 min", "1 min 30 s", "45 s": time left, for a reminder.
    public static func left(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return m == 0 ? "\(h) h" : "\(h) h \(m) min" }
        if m == 0 { return "\(sec) s" }
        return sec == 0 || m >= 5 ? "\(m) min" : "\(m) min \(sec) s"
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
