import Foundation

// The modes the whole app runs in: normal; test, where the clock everything is scheduled by runs
// 60 times faster (a day goes by in 24 minutes), to try the schedules, timers and reminders
// without waiting for them; and quiet, where nothing pops up, and everything held back pops up
// when it ends. Test mode ends by itself after 30 minutes, quiet mode after an hour (real ones).

public enum AppMode: String, Codable, CaseIterable, Sendable {
    case normal, test, quiet

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .test: return "Test"
        case .quiet: return "Quiet"
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .normal: return "circle.dashed"
        case .test: return "hare.fill"
        case .quiet: return "moon.zzz.fill"
        }
    }

    /// How long it lasts before it goes back to normal by itself (real seconds); nil for normal.
    public var lasts: TimeInterval? {
        switch self {
        case .normal: return nil
        case .test: return 30 * 60
        case .quiet: return 60 * 60
        }
    }

    /// What it means, in a sentence or two (said before it's turned on).
    public var meaning: String {
        switch self {
        case .normal:
            return "Everything runs on the real clock, and pop-ups come up when they're due."
        case .test:
            return "The clock the schedules, chimes, note timers, note reminders and the battery run by goes 60 times faster: "
                + "a day goes by in 24 minutes, an hour in a minute, a minute in a second. It's for trying them out. "
                + "After 30 minutes it goes back to normal by itself; then the schedules are planned again from the real time, "
                + "and timers and log entries made on the fast clock are cleared."
        case .quiet:
            return "Nothing pops up and the timers make no sound. After an hour it goes back to normal by itself, "
                + "and everything that would have popped up meanwhile pops up then, so you can catch up."
        }
    }

    /// The test clock's speed: 24 hours in 24 minutes.
    public static let testSpeed: Double = 60
}

/// A clock that runs faster than the real one from a moment on: at `real` it read `virtual`, and
/// since then it's gone `speed` times as fast.
public struct ClockWarp: Codable, Equatable, Sendable {
    public var real: Date
    public var virtual: Date
    public var speed: Double

    public init(real: Date, virtual: Date, speed: Double) {
        self.real = real
        self.virtual = virtual
        self.speed = speed
    }

    /// What it reads when the real clock reads `date`.
    public func time(at date: Date) -> Date {
        virtual.addingTimeInterval(date.timeIntervalSince(real) * speed)
    }

    /// How many real seconds `seconds` on this clock take.
    public func realSeconds(_ seconds: TimeInterval) -> TimeInterval { seconds / max(speed, 0.000_001) }
}

/// Which mode the app is in, and until when (real time).
public struct ModeState: Codable, Equatable, Sendable {
    public var mode: AppMode
    /// When it began (real time).
    public var since: Date?
    /// When it goes back to normal by itself (real time).
    public var until: Date?
    /// The test clock, while in test mode.
    public var warp: ClockWarp?

    public init(mode: AppMode = .normal, since: Date? = nil, until: Date? = nil, warp: ClockWarp? = nil) {
        self.mode = mode
        self.since = since
        self.until = until
        self.warp = warp
    }

    /// Entering `mode` at `now` (real time).
    public static func entering(_ mode: AppMode, at now: Date) -> ModeState {
        switch mode {
        case .normal: return ModeState()
        case .test:
            return ModeState(mode: .test, since: now, until: now.addingTimeInterval(mode.lasts ?? 0),
                             warp: ClockWarp(real: now, virtual: now, speed: AppMode.testSpeed))
        case .quiet:
            return ModeState(mode: .quiet, since: now, until: now.addingTimeInterval(mode.lasts ?? 0))
        }
    }

    /// Its time is up at `now` (real time): it should go back to normal.
    public func isOver(at now: Date) -> Bool {
        guard mode != .normal else { return false }
        guard let until else { return true }
        return now >= until
    }

    /// Real seconds left before it goes back to normal.
    public func remaining(at now: Date) -> TimeInterval? {
        guard mode != .normal, let until else { return nil }
        return max(0, until.timeIntervalSince(now))
    }
}

/// The time everything that's scheduled runs by: the real time, or the test clock's in test mode.
/// Safe to read from any thread.
public enum AppClock {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var warp: ClockWarp?
    }

    private static let storage = Storage()

    /// Now, on the app's clock.
    public static func now() -> Date { time(at: Date()) }

    /// The app's clock when the real clock reads `date`.
    public static func time(at date: Date) -> Date {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.warp?.time(at: date) ?? date
    }

    /// The test clock (nil: the real one).
    public static var warp: ClockWarp? {
        get {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.warp
        }
        set {
            storage.lock.lock()
            storage.warp = newValue
            storage.lock.unlock()
        }
    }

    /// How fast the app's clock runs (1 normally, 60 in test mode).
    public static var speed: Double { warp?.speed ?? 1 }
}
