import Foundation

// Focus on a board: its notes one at a time, each pinned on the screen while you work on it, in
// rounds of a focus interval (10 minutes to start) and a 3-minute rest. On the way down, reminders
// halve what's left (as a countdown's do). At time's up: Snooze (once a round, 3 minutes),
// Pending (rest, then the same note again) or Completed (the note is done: the next one is pinned
// and the rest starts, even before the interval is up). A note must have some text before it can
// be completed. The battery is set to 100% when it starts, and focus goes on round after round
// until the battery is empty. One board at a time. Strict focus can't be stopped from the app at
// all: only by quitting it from outside (Force Quit) or restarting the Mac. This is its logic; the
// app pins, rings and shows it.

public struct FocusSession: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// Working on the note, the interval counting down.
        case focus
        /// The interval is up: waiting for Snooze, Pending or Completed.
        case ringing
        /// Snoozed: it rings again when the snooze is up.
        case snoozed
        /// Resting before the next round.
        case rest
    }

    /// What happened, for the app to show and sound.
    public enum Event: Equatable, Sendable {
        /// On the way down: this much is left.
        case reminder(left: TimeInterval)
        /// The interval is up.
        case timeUp
        /// The snooze is up: it rings again.
        case snoozeOver
        /// The rest is over: a new round on the note.
        case focusStarted
    }

    /// The board's id.
    public var board: String
    /// Strict: nothing in the app stops it.
    public var strict: Bool
    /// The focus interval, in seconds.
    public var interval: TimeInterval
    /// The note being worked on (or, while resting, the one coming up).
    public var note: Int
    public var phase: Phase
    /// When this phase began.
    public var since: Date
    /// When the session began.
    public var started: Date
    /// Rounds begun so far (the first is 1).
    public var round: Int
    /// The snooze is used up this round.
    public var snoozeUsed: Bool
    /// The smallest reminder mark shown this round (time left).
    public var reminded: TimeInterval?
    /// Notes completed in this session.
    public var completed: Int
    /// Started on test mode's fast clock (it ends with test mode).
    public var onTestClock: Bool

    public static let defaultInterval: TimeInterval = 10 * 60
    /// The focus intervals to pick from.
    public static let intervals: [TimeInterval] = [5, 10, 15, 20, 25, 30, 45, 60].map { $0 * 60 }
    /// The rest between rounds: always 3 minutes.
    public static let rest: TimeInterval = 3 * 60
    /// A snooze: 3 minutes, once a round.
    public static let snooze: TimeInterval = 3 * 60
    /// A reminder is shown only when it's this fresh (not when the Mac wakes long after it).
    public static let reminderGrace: TimeInterval = 15

    public init(board: String, strict: Bool, interval: TimeInterval = FocusSession.defaultInterval, note: Int,
                now: Date, onTestClock: Bool = false) {
        self.board = board
        self.strict = strict
        self.interval = max(60, interval)
        self.note = note
        phase = .focus
        since = now
        started = now
        round = 1
        snoozeUsed = false
        reminded = nil
        completed = 0
        self.onTestClock = onTestClock
    }

    /// When the current phase ends (nil while ringing: it waits for you).
    public var ends: Date? {
        switch phase {
        case .focus: return since.addingTimeInterval(interval)
        case .snoozed: return since.addingTimeInterval(Self.snooze)
        case .rest: return since.addingTimeInterval(Self.rest)
        case .ringing: return nil
        }
    }

    /// Time left in the current phase.
    public func remaining(now: Date) -> TimeInterval? { ends.map { max(0, $0.timeIntervalSince(now)) } }

    /// The reminders of the focus interval, as the time left at each: halving what's left, in
    /// whole minutes (10 minutes: 5, 2 and 1 minute left), as a countdown's.
    public var reminderMarks: [TimeInterval] { TimerSpec.reminders(for: interval) }

    /// What's due now, moving on to the next phase when one is over.
    public mutating func step(now: Date) -> Event? {
        switch phase {
        case .focus:
            let end = since.addingTimeInterval(interval)
            if now >= end {
                phase = .ringing
                since = end
                return .timeUp
            }
            let left = end.timeIntervalSince(now)
            guard let mark = reminderMarks.last(where: { left <= $0 }) else { return nil }
            if let shown = reminded, shown <= mark { return nil }
            reminded = mark
            return mark - left <= Self.reminderGrace ? .reminder(left: left) : nil
        case .snoozed:
            let end = since.addingTimeInterval(Self.snooze)
            guard now >= end else { return nil }
            phase = .ringing
            since = end
            return .snoozeOver
        case .rest:
            guard now >= since.addingTimeInterval(Self.rest) else { return nil }
            // A new round from now (after a sleep, not from when the rest ended).
            phase = .focus
            since = now
            round += 1
            snoozeUsed = false
            reminded = nil
            return .focusStarted
        case .ringing:
            return nil
        }
    }

    public var canSnooze: Bool { phase == .ringing && !snoozeUsed }

    /// Quiet for 3 minutes, then it rings again (once a round).
    public mutating func snooze(now: Date) {
        guard canSnooze else { return }
        phase = .snoozed
        since = now
        snoozeUsed = true
    }

    /// Not done yet: rest, then the same note again.
    public mutating func pending(now: Date) {
        phase = .rest
        since = now
    }

    /// The note is done: `next` is pinned and the rest starts now (even before the interval is up).
    public mutating func complete(next: Int, now: Date) {
        completed += 1
        note = next
        phase = .rest
        since = now
    }

    /// Can it be completed now (while working on it, at time's up or snoozed; not while resting,
    /// when the pinned note is the next one).
    public var canComplete: Bool { phase != .rest }

    /// The note to focus on after `current`: the first not completed among the shown ones, going
    /// round from just after it; when every shown one is completed, the next hidden box (which is
    /// shown for it). Nil when all of them are completed. `from` itself counts only when
    /// `including` (to start a session on the first note).
    public static func nextNote(after current: Int, completed: [Bool], shown: Int, including: Bool = false) -> Int? {
        let count = completed.count
        guard count > 0 else { return nil }
        let shown = min(max(shown, 1), count)
        let start = including ? current : current + 1
        for k in 0..<shown {
            let i = ((start + k) % shown + shown) % shown
            if !completed[i] { return i }
        }
        return completed.indices.first { $0 >= shown && !completed[$0] }
    }

    /// The note's text is something (not only spaces): it can be completed.
    public static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The clock jumped back (test mode ended): times that are now ahead come back to `now`.
    public mutating func rebase(now: Date) {
        if since > now { since = now }
        if started > now { started = now }
    }
}
