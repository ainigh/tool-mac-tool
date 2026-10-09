import Foundation

/// The timers' sounds, made from sine waves (so each is its own and nothing needs shipping): two
/// loud alarms, two soft rounds-done chimes, a bright day ding and a deep, insistent night ding;
/// a note's minute countdown rings the day ding again every 3 seconds, and sending to a web address
/// has a quick tick before, and after it a bright pair (sent) or a low falling buzz (it failed).
public enum Tone: String, CaseIterable, Sendable {
    /// Timer 1: three quick, bright beeps a second, looped.
    case triple
    /// Timer 2: a siren sweeping up and down, looped.
    case siren
    /// Repeat 1: two soft marimba notes falling.
    case marimba
    /// Repeat 2: three soft notes rising.
    case rising
    /// Day chime: one bright bell.
    case ding
    /// Night watch: a low ding-dong, twice.
    case dingDong
    /// A note's minute countdown at zero: the day chime's ding, again every 3 seconds, looped.
    case noteChime
    /// About to send to a web address: one quick, soft tick (then quiet, so it's never cut off).
    case sendStart
    /// Sent: two quick notes, rising.
    case sendDone
    /// Couldn't send: two low, buzzy notes, falling.
    case sendFailed

    public static let rate = 44_100.0

    /// Whether it plays over and over until stopped (the alarms) or once.
    public var loops: Bool { self == .triple || self == .siren || self == .noteChime }

    /// How far apart a note countdown's dings are.
    public static let noteChimeEvery = 3.0

    /// How loud it plays, from 0 to 1.
    public var volume: Float {
        switch self {
        case .triple, .siren: return 0.9
        case .marimba, .rising: return 0.4
        case .ding, .noteChime: return 0.65
        case .dingDong: return 0.85
        case .sendStart: return 0.35
        case .sendDone: return 0.45
        case .sendFailed: return 0.6
        }
    }

    /// One pass of the sound, mono, at `rate`, between -1 and 1.
    public func samples() -> [Float] {
        switch self {
        case .triple:
            var s = Self.silence(1.0)
            for start in [0.0, 0.13, 0.26] {
                Self.add(&s, freq: 1568, start: start, length: 0.09, attack: 0.005, decay: 0, partials: [(1, 0.55), (3, 0.18), (5, 0.07)])
            }
            return s
        case .siren:
            let length = 1.2, count = Int(length * Self.rate)
            var s = [Float](repeating: 0, count: count)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / Self.rate
                // Up for the first half, down for the second.
                let x = t < length / 2 ? t / (length / 2) : (length - t) / (length / 2)
                let freq = 650 + 650 * x
                phase += 2 * .pi * freq / Self.rate
                let edge = min(1, t / 0.02) * min(1, (length - t) / 0.02)
                s[i] = Float((sin(phase) * 0.55 + sin(3 * phase) * 0.12) * edge)
            }
            return s
        case .marimba:
            var s = Self.silence(1.4)
            Self.add(&s, freq: 784, start: 0, length: 0.7, attack: 0.004, decay: 7, partials: [(1, 0.6), (4, 0.12)])
            Self.add(&s, freq: 659.3, start: 0.32, length: 1.0, attack: 0.004, decay: 6, partials: [(1, 0.6), (4, 0.12)])
            return s
        case .rising:
            var s = Self.silence(1.6)
            for (i, freq) in [523.3, 659.3, 784].enumerated() {
                Self.add(&s, freq: freq, start: Double(i) * 0.2, length: 1.0, attack: 0.01, decay: 4.5,
                         partials: [(1, 0.5), (2, 0.12), (3, 0.05)])
            }
            return s
        case .ding:
            var s = Self.silence(2.2)
            Self.addDing(&s)
            return s
        case .noteChime:
            // The day chime's ding, then quiet up to 3 seconds: looped, a ding every 3 seconds.
            var s = Self.silence(Self.noteChimeEvery)
            Self.addDing(&s)
            return s
        case .sendStart:
            var s = Self.silence(0.55)
            Self.add(&s, freq: 1760, start: 0, length: 0.07, attack: 0.003, decay: 30, partials: [(1, 0.5), (2, 0.1)])
            return s
        case .sendDone:
            var s = Self.silence(0.55)
            Self.add(&s, freq: 1046.5, start: 0, length: 0.14, attack: 0.003, decay: 14, partials: [(1, 0.5), (2, 0.12)])
            Self.add(&s, freq: 1568, start: 0.11, length: 0.26, attack: 0.003, decay: 10, partials: [(1, 0.5), (2, 0.12)])
            return s
        case .sendFailed:
            var s = Self.silence(0.7)
            Self.add(&s, freq: 392, start: 0, length: 0.26, attack: 0.005, decay: 0,
                     partials: [(1, 0.45), (2, 0.2), (3, 0.14), (5, 0.08)])
            Self.add(&s, freq: 261.6, start: 0.3, length: 0.36, attack: 0.005, decay: 0,
                     partials: [(1, 0.45), (2, 0.2), (3, 0.14), (5, 0.08)])
            return s
        case .dingDong:
            var s = Self.silence(3.4)
            for start in [0.0, 1.5] {
                Self.add(&s, freq: 659.3, start: start, length: 1.9, attack: 0.002, decay: 2.2,
                         partials: [(1, 0.5), (2.0, 0.2), (2.76, 0.14), (5.4, 0.05)])
                Self.add(&s, freq: 440, start: start + 0.55, length: 1.9, attack: 0.002, decay: 1.8,
                         partials: [(1, 0.55), (2.0, 0.22), (2.76, 0.14), (5.4, 0.05)])
            }
            return s
        }
    }

    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * rate)) }

    /// The day chime's bell, from the start (2.2 seconds of it).
    static func addDing(_ s: inout [Float]) {
        add(&s, freq: 1318.5, start: 0, length: 2.2, attack: 0.002, decay: 2.2,
            partials: [(1, 0.5), (2.0, 0.18), (2.76, 0.12), (5.4, 0.05)])
    }

    /// Adds a note: its partials (a multiple of `freq` and how loud), a quick fade in, then an
    /// exponential fade out at `decay` per second (0: held, with a short fade at the end).
    static func add(_ s: inout [Float], freq: Double, start: Double, length: Double, attack: Double, decay: Double,
                    partials: [(Double, Double)]) {
        let first = Int(start * rate), count = Int(length * rate)
        for j in 0..<count where first + j < s.count {
            let t = Double(j) / rate
            var env = min(1, t / attack)
            env *= decay > 0 ? exp(-decay * t) : 1
            env *= min(1, (length - t) / 0.01)
            var v = 0.0
            for (ratio, amp) in partials { v += sin(2 * .pi * freq * ratio * t) * amp }
            s[first + j] = max(-1, min(1, s[first + j] + Float(v * env)))
        }
    }
}
