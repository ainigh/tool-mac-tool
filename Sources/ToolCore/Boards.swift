import Foundation

// The boards (Goals, Strategies, Entities, Notes, People, Ideas, Dreams, Projects, Health,
// Communication): a big panel of boxes (notes) to type into. The arrows show more or fewer of them
// (the hidden ones keep their text), a double-click steps a box through light colors, and the grid
// fills the panel with a gutter that narrows as the boxes get more. Each box can run one timer (a
// countdown, a repeating one or a due date), be pinned to float on the screen by itself, be docked
// in the menu bar panel, wear an icon of its own, and have tags (Important, Urgent, Delegate,
// Think), each of which has a board gathering its notes. This is their logic (what's kept, how the
// grid is laid out); the app draws it.

public struct Board: Codable, Equatable, Sendable {
    public struct Box: Codable, Equatable, Sendable {
        public var text: String
        /// Which of `Board.tints` it wears.
        public var tint: Int
        /// The one timer it runs, if any.
        public var alarm: BoxAlarm?
        /// Floating on the screen in a window of its own.
        public var pinned: Bool
        /// Its icon (an SF Symbol name); nil wears its board's.
        public var icon: String?
        /// The tags it has (Important, Urgent, Delegate, Think), in `NoteTag` order.
        public var tags: [NoteTag]
        /// Docked in the row along the bottom of the menu bar panel.
        public var docked: Bool

        public init(text: String = "", tint: Int = 0, alarm: BoxAlarm? = nil, pinned: Bool = false, icon: String? = nil,
                    tags: [NoteTag] = [], docked: Bool = false) {
            self.text = text
            self.tint = tint
            self.alarm = alarm
            self.pinned = pinned
            self.icon = icon
            self.tags = tags
            self.docked = docked
        }

        private enum CodingKeys: String, CodingKey { case text, tint, alarm, pinned, icon, tags, docked }

        // A file from before timers, pins, icons, tags and the dock has none of them.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            tint = try c.decodeIfPresent(Int.self, forKey: .tint) ?? 0
            alarm = try c.decodeIfPresent(BoxAlarm.self, forKey: .alarm)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            // A tag this version doesn't know is dropped, not the whole board.
            let names = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil
            tags = NoteTag.allCases.filter { (names ?? []).contains($0.rawValue) }
            docked = try c.decodeIfPresent(Bool.self, forKey: .docked) ?? false
        }

        public func has(_ tag: NoteTag) -> Bool { tags.contains(tag) }

        /// The tag on, or off again.
        public mutating func toggle(_ tag: NoteTag) {
            if has(tag) { tags.removeAll { $0 == tag } } else { tags = NoteTag.allCases.filter { $0 == tag || has($0) } }
        }

        /// Its first line of text, trimmed (nil when it has none): what it's called in lists.
        public var title: String? {
            text.split(whereSeparator: \.isNewline).lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
    }

    public static let minBoxes = 1
    public static let maxBoxes = 36
    public static let defaultShown = 4

    /// How many boxes are shown (the first ones).
    public var shown: Int
    /// Every box, shown or not: always `maxBoxes` of them.
    public var boxes: [Box]

    public init(shown: Int = Board.defaultShown, boxes: [Box] = []) {
        self.shown = shown
        self.boxes = boxes
        self = tidied()
    }

    /// The light colors a double-click steps through, as red, green and blue from 0 to 1.
    public static let tints: [(red: Double, green: Double, blue: Double)] = [
        (0.98, 0.98, 0.97),   // paper
        (1.00, 0.96, 0.76),   // butter
        (0.84, 0.93, 1.00),   // sky
        (0.85, 0.96, 0.85),   // mint
        (1.00, 0.88, 0.89),   // rose
        (0.92, 0.88, 1.00),   // lavender
        (1.00, 0.91, 0.80),   // peach
        (0.84, 0.96, 0.95),   // aqua
    ]

    public static func nextTint(after tint: Int) -> Int { (tint + 1) % tints.count }

    /// One more box shown (up to `maxBoxes`).
    public mutating func more() { shown = min(shown + 1, Self.maxBoxes) }
    /// One fewer box shown (down to `minBoxes`); its text stays for when it's shown again.
    public mutating func fewer() { shown = max(shown - 1, Self.minBoxes) }

    /// In range, with exactly `maxBoxes` boxes and tints that exist (an older or edited file).
    public func tidied() -> Board {
        var b = self
        b.shown = min(max(b.shown, Self.minBoxes), Self.maxBoxes)
        if b.boxes.count > Self.maxBoxes { b.boxes = Array(b.boxes.prefix(Self.maxBoxes)) }
        b.boxes += Array(repeating: Box(), count: Self.maxBoxes - b.boxes.count)
        for i in b.boxes.indices where !Self.tints.indices.contains(b.boxes[i].tint) { b.boxes[i].tint = 0 }
        for i in b.boxes.indices where b.boxes[i].alarm?.timer == nil || b.boxes[i].alarm?.state.isOn != true {
            b.boxes[i].alarm = nil
        }
        return b
    }

    /// The space between boxes, in points: wide with a few, narrow with many.
    public static func gutter(for count: Int) -> Double {
        max(2, 14 - 2 * Double(max(count, 1)).squareRoot())
    }

    /// How many boxes go in each row, top to bottom, to fill a panel of this size: the layout
    /// whose boxes come closest to square, with no row more than one box shorter than the others.
    public static func rows(for count: Int, width: Double, height: Double) -> [Int] {
        let n = max(count, 1)
        let w = max(width, 1), h = max(height, 1)
        var best: (rows: Int, score: Double) = (1, .infinity)
        for rows in 1...n {
            let columns = Int((Double(n) / Double(rows)).rounded(.up))
            // A row count that leaves a row empty is the same as fewer rows.
            if (rows - 1) * columns >= n { continue }
            let aspect = (w / Double(columns)) / (h / Double(rows))
            let score = abs(log(aspect))
            if score < best.score - 1e-9 { best = (rows, score) }
        }
        // Spread the boxes over the rows, the longer rows first.
        let base = n / best.rows, extra = n % best.rows
        return (0..<best.rows).map { $0 < extra ? base + 1 : base }
    }

    /// Where a board is kept: ~/Library/Application Support/ToolMacTool/boards/<id>.json.
    public static func url(for id: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/boards/\(id).json")
    }

    /// The saved board, or a new one when there's no file yet (or it can't be read).
    public static func load(from url: URL) -> Board {
        guard let data = try? Data(contentsOf: url),
              let b = try? JSONDecoder().decode(Board.self, from: data) else { return Board() }
        return b.tidied()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The tags a note can have: each toggled on its note, and each with a board that gathers every
/// note that has it, from all the boards.
public enum NoteTag: String, Codable, CaseIterable, Sendable {
    case important, urgent, delegate, think

    public var title: String {
        switch self {
        case .important: return "Important"
        case .urgent: return "Urgent"
        case .delegate: return "Delegate"
        case .think: return "Think"
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .important: return "star.fill"
        case .urgent: return "flame.fill"
        case .delegate: return "arrowshape.turn.up.right.fill"
        case .think: return "brain.head.profile"
        }
    }
}

/// The timer a box runs: which one (a `TimerSpec.forBoxes` id) and where it's got to.
public struct BoxAlarm: Codable, Equatable, Sendable {
    public var spec: String
    public var state: TimerState

    public init(spec: String, state: TimerState) {
        self.spec = spec
        self.state = state
    }

    /// Its timer (nil for an id that isn't one a box runs).
    public var timer: TimerSpec? { TimerSpec.forBoxes.first { $0.id == spec } }

    /// When it next rings, if it's counting towards that.
    public func nextRing(now: Date) -> Date? { timer?.nextRing(state, now: now) }
}
