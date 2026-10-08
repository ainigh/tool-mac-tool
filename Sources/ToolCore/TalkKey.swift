import Foundation

/// The key that dictates into any text field (Talk to type), from its presses and releases to what
/// to do: start listening, put what was said where the cursor is, or drop it.
///
///  - **Hold** it and talk; let go and what you said goes in.
///  - **Tap** it (let go within `tapLimit`) and it keeps listening hands-free; tap it again and
///    what you said goes in.
///  - Another key pressed while it's held was a shortcut with it (⌥E for é, say): nothing goes in.
///  - **Esc** drops what you said, held or hands-free.
public struct TalkKey: Equatable {
    public enum Effect: Equatable {
        case none
        /// Start listening.
        case start
        /// Stop, and put what was said where the cursor is.
        case finish
        /// Stop, and drop what was said.
        case cancel
    }

    public enum State: Equatable {
        case idle
        /// Held since then, listening.
        case held(since: Date)
        /// Tapped: listening until it's tapped again.
        case handsFree
        /// Hands-free, and pressed again: letting go finishes.
        case handsFreeDown
    }

    /// A press shorter than this is a tap.
    public static let tapLimit: TimeInterval = 0.3

    public private(set) var state = State.idle

    public init() {}

    public var listening: Bool { state != .idle }

    public mutating func down(at now: Date) -> Effect {
        switch state {
        case .idle:
            state = .held(since: now)
            return .start
        case .handsFree:
            state = .handsFreeDown
            return .none
        case .held, .handsFreeDown:
            return .none
        }
    }

    public mutating func up(at now: Date) -> Effect {
        switch state {
        case .held(let since):
            if now.timeIntervalSince(since) < Self.tapLimit {
                state = .handsFree
                return .none
            }
            state = .idle
            return .finish
        case .handsFreeDown:
            state = .idle
            return .finish
        case .idle, .handsFree:
            return .none
        }
    }

    /// Another key pressed (not Esc).
    public mutating func otherKey() -> Effect {
        guard case .held = state else { return .none }
        state = .idle
        return .cancel
    }

    public mutating func escape() -> Effect {
        guard state != .idle else { return .none }
        state = .idle
        return .cancel
    }

    /// Back to idle without a word (listening stopped some other way).
    public mutating func reset() { state = .idle }

    /// What was heard, ready to go in: trimmed of spaces and line breaks at either end (nil when
    /// nothing was said).
    public static func text(_ heard: String) -> String? {
        let t = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
