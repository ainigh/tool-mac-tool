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
        /// Daily (or mornings, afternoons, evenings), weekly or monthly: a note reminder pops up
        /// every hour of its hours (8 AM to 10 PM, or the part of the day) until it's marked
        /// completed (nil: none).
        public var repeats: NoteRepeat?
        /// To do, pending or completed (at most one; nil: none of them).
        public var status: NoteStatus?
        /// When the status was last set.
        public var statusAt: Date?
        /// The last hour a note reminder came up for (or when the repeat was turned on).
        public var remindedAt: Date?
        /// How many blocks of the board's grid it spans, across and down (1 to `Board.maxSpan`).
        public var across: Int
        public var down: Int

        public init(text: String = "", tint: Int = 0, alarm: BoxAlarm? = nil, pinned: Bool = false, icon: String? = nil,
                    tags: [NoteTag] = [], docked: Bool = false, repeats: NoteRepeat? = nil, status: NoteStatus? = nil,
                    statusAt: Date? = nil, remindedAt: Date? = nil, across: Int = 1, down: Int = 1) {
            self.text = text
            self.tint = tint
            self.alarm = alarm
            self.pinned = pinned
            self.icon = icon
            self.tags = tags
            self.docked = docked
            self.repeats = repeats
            self.status = status
            self.statusAt = statusAt
            self.remindedAt = remindedAt
            self.across = across
            self.down = down
        }

        private enum CodingKeys: String, CodingKey {
            case text, tint, alarm, pinned, icon, tags, docked, repeats, status, statusAt, remindedAt, across, down
        }

        // A file from before timers, pins, icons, tags, the dock, repeats, statuses and sizes has none of them.
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
            repeats = (try? c.decodeIfPresent(NoteRepeat.self, forKey: .repeats)) ?? nil
            status = (try? c.decodeIfPresent(NoteStatus.self, forKey: .status)) ?? nil
            statusAt = try c.decodeIfPresent(Date.self, forKey: .statusAt)
            remindedAt = try c.decodeIfPresent(Date.self, forKey: .remindedAt)
            across = (try? c.decodeIfPresent(Int.self, forKey: .across)) ?? 1
            down = (try? c.decodeIfPresent(Int.self, forKey: .down)) ?? 1
        }

        /// The status set (or, when it's the one already on, taken off: at most one is on).
        public mutating func toggle(_ new: NoteStatus, now: Date) {
            status = status == new ? nil : new
            statusAt = now
        }

        /// The repeat turned on (it's To do from now; whatever repeat it had goes) or off.
        public mutating func setRepeat(_ new: NoteRepeat?, now: Date) {
            repeats = new
            remindedAt = new == nil ? nil : now
            if new != nil {
                status = .todo
                statusAt = now
            }
        }

        /// Completed in the period `now` is in (the day, the week, the month, each from 8 AM the
        /// day before).
        public func isDone(now: Date, calendar: Calendar) -> Bool {
            guard let repeats, status == .completed, let statusAt,
                  let period = repeats.period(containing: now, calendar: calendar) else { return false }
            return period.contains(statusAt)
        }

        /// A new period has begun since the status was set: it goes back to To do. Returns
        /// whether it changed anything.
        public mutating func rollOver(now: Date, calendar: Calendar) -> Bool {
            guard let repeats, let period = repeats.period(containing: now, calendar: calendar) else { return false }
            guard status != .todo, statusAt.map({ $0 < period.start }) ?? true else { return false }
            status = .todo
            statusAt = period.start
            return true
        }

        /// The hour a note reminder is due for at `now`, if one is: on the hour, in its hours,
        /// later than the last one (and than when the repeat was turned on), while it isn't
        /// completed for this period. Hours missed (asleep) aren't made up: only the latest comes.
        public func reminderDue(now: Date, calendar: Calendar) -> Date? {
            guard let repeats, !isDone(now: now, calendar: calendar),
                  let hour = calendar.dateInterval(of: .hour, for: now)?.start,
                  repeats.hours.contains(calendar.component(.hour, from: hour)) else { return nil }
            if let remindedAt, remindedAt >= hour { return nil }
            return hour
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

    /// The most blocks a box spans, across or down.
    public static let maxSpan = 4

    /// How many boxes are shown (the first ones in `order`).
    public var shown: Int
    /// Every box, shown or not: always `maxBoxes` of them. A box keeps its place here (what its
    /// timer, pin, cards and focus go by); `order` is where it shows.
    public var boxes: [Box]
    /// The boxes in the order they show on the board (dragged into it): every index of `boxes`
    /// once. The first `shown` of them are on the board.
    public var order: [Int]

    public init(shown: Int = Board.defaultShown, boxes: [Box] = [], order: [Int] = []) {
        self.shown = shown
        self.boxes = boxes
        self.order = order
        self = tidied()
    }

    private enum CodingKeys: String, CodingKey { case shown, boxes, order }

    // A file from before the boxes could be ordered has no order: they show as they're kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shown = try c.decodeIfPresent(Int.self, forKey: .shown) ?? Self.defaultShown
        boxes = try c.decodeIfPresent([Box].self, forKey: .boxes) ?? []
        order = (try? c.decodeIfPresent([Int].self, forKey: .order)) ?? []
    }

    /// The boxes on the board, in the order they show.
    public var visible: [Int] { Array(order.prefix(shown)) }

    /// On the board (not hidden by the arrows).
    public func isShown(_ box: Int) -> Bool { visible.contains(box) }

    /// A hidden box shown: it comes in after the last one on the board.
    public mutating func reveal(_ box: Int) {
        guard !isShown(box), let at = order.firstIndex(of: box) else { return }
        order.remove(at: at)
        order.insert(box, at: shown)
        shown = min(shown + 1, Self.maxBoxes)
    }

    /// A box dragged onto another's place: it takes it, and the boxes between move along one.
    public mutating func move(_ box: Int, to target: Int) {
        guard box != target, let from = order.firstIndex(of: box), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(box, at: to)
    }

    /// A box's size in blocks, across and down (each 1 to `maxSpan`).
    public mutating func resize(_ box: Int, across: Int, down: Int) {
        boxes[box].across = min(max(across, 1), Self.maxSpan)
        boxes[box].down = min(max(down, 1), Self.maxSpan)
    }

    /// The note focus goes to after `box` (from the first on the board when nil, counting it when
    /// `including`), going round the board in its order, then the hidden ones.
    public func nextNote(after box: Int?, including: Bool = false) -> Int? {
        let done = order.map { boxes[$0].status == .completed }
        let at = box.flatMap { order.firstIndex(of: $0) } ?? 0
        return FocusSession.nextNote(after: at, completed: done, shown: shown, including: including).map { order[$0] }
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
        for i in b.boxes.indices {
            b.boxes[i].across = min(max(b.boxes[i].across, 1), Self.maxSpan)
            b.boxes[i].down = min(max(b.boxes[i].down, 1), Self.maxSpan)
        }
        // Every box once: unknown or repeated places go, missing boxes come at the end.
        var seen = Set<Int>()
        b.order = b.order.filter { b.boxes.indices.contains($0) && seen.insert($0).inserted }
        b.order += b.boxes.indices.filter { !seen.contains($0) }
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

    /// A box's place on the board, as fractions of its width and height (0 to 1).
    public struct Cell: Equatable, Sendable {
        public var box: Int
        public var x: Double, y: Double, width: Double, height: Double

        public init(box: Int, x: Double, y: Double, width: Double, height: Double) {
            self.box = box
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public func contains(x px: Double, y py: Double) -> Bool {
            px >= x && px < x + width && py >= y && py < y + height
        }
    }

    /// Where the shown boxes go on a board this size, and the grid's blocks across and down. When
    /// every box is one block, the rows of `rows(for:)` (each row's boxes filling its width); when
    /// one is bigger, a grid, each box placed in turn at the first place it fits from where the
    /// last one went, with as many blocks across as come closest to square blocks and fewest left
    /// empty.
    public func layout(width: Double, height: Double) -> (cells: [Cell], across: Int, down: Int) {
        let ids = visible
        let w = max(width, 1), h = max(height, 1)
        if ids.allSatisfy({ boxes[$0].across == 1 && boxes[$0].down == 1 }) {
            let rows = Self.rows(for: ids.count, width: w, height: h)
            var cells: [Cell] = []
            var k = 0
            for (r, n) in rows.enumerated() {
                for c in 0..<n {
                    cells.append(Cell(box: ids[k], x: Double(c) / Double(n), y: Double(r) / Double(rows.count),
                                      width: 1 / Double(n), height: 1 / Double(rows.count)))
                    k += 1
                }
            }
            return (cells, rows.max() ?? 1, rows.count)
        }
        let spans = ids.map { (box: $0, across: boxes[$0].across, down: boxes[$0].down) }
        let widest = spans.map(\.across).max() ?? 1
        let area = spans.reduce(0) { $0 + $1.across * $1.down }
        var best: (score: Double, across: Int, down: Int, placed: [(Int, Int, Int, Int, Int)])?
        for columns in widest...max(widest, area) {
            let (placed, rows) = Self.pack(spans, columns: columns)
            let aspect = (w / Double(columns)) / (h / Double(rows))
            let empty = Double(columns * rows - area) / Double(columns * rows)
            let score = abs(log(aspect)) + empty
            if best == nil || score < best!.score - 1e-9 { best = (score, columns, rows, placed) }
        }
        guard let best else { return ([], 1, 1) }
        let cells = best.placed.map { box, x, y, a, d in
            Cell(box: box, x: Double(x) / Double(best.across), y: Double(y) / Double(best.down),
                 width: Double(a) / Double(best.across), height: Double(d) / Double(best.down))
        }
        return (cells, best.across, best.down)
    }

    /// Each box at the first place it fits, row by row, from where the last one went: (box,
    /// column, row, across, down), and how many rows that takes.
    static func pack(_ spans: [(box: Int, across: Int, down: Int)], columns: Int) -> ([(Int, Int, Int, Int, Int)], Int) {
        var taken: [[Bool]] = []
        var placed: [(Int, Int, Int, Int, Int)] = []
        var cursor = (row: 0, column: 0)
        func free(_ r: Int, _ c: Int, _ a: Int, _ d: Int) -> Bool {
            guard c + a <= columns else { return false }
            for y in r..<(r + d) where y < taken.count {
                for x in c..<(c + a) where taken[y][x] { return false }
            }
            return true
        }
        for s in spans {
            let a = min(s.across, columns)
            var r = cursor.row, c = cursor.column
            while !free(r, c, a, s.down) {
                c += 1
                if c + a > columns { c = 0; r += 1 }
            }
            while taken.count < r + s.down { taken.append(Array(repeating: false, count: columns)) }
            for y in r..<(r + s.down) { for x in c..<(c + a) { taken[y][x] = true } }
            placed.append((s.box, c, r, a, s.down))
            cursor = (r, c + a)
        }
        return (placed, max(taken.count, 1))
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

/// How often a note comes round: every day (or only its mornings, afternoons or evenings), every
/// week or every month. Each period begins at 8 AM the day before the calendar's own: a day runs
/// from 8 AM to 8 AM the next day, a week from Sunday 8 AM, a month from 8 AM on the last day of
/// the month before.
public enum NoteRepeat: String, Codable, CaseIterable, Sendable {
    case daily, mornings, afternoons, evenings, weekly, monthly

    public var title: String {
        switch self {
        case .daily: return "Daily"
        case .mornings: return "Mornings"
        case .afternoons: return "Afternoons"
        case .evenings: return "Evenings"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// An SF Symbol for the daily ones scoped to part of the day (nil: it shows its word).
    public var symbol: String? {
        switch self {
        case .mornings: return "sunrise.fill"
        case .afternoons: return "sun.max.fill"
        case .evenings: return "moon.fill"
        default: return nil
        }
    }

    /// The hour a period begins at (on the day before the calendar's day, week or month).
    public static let startHour = 8

    /// The hours of the day a reminder comes on the hour: 8 AM to 10 PM, or the part of the day
    /// it's scoped to (mornings 8 to 11 AM, afternoons 12 to 4 PM, evenings 5 to 10 PM).
    public var hours: ClosedRange<Int> {
        switch self {
        case .mornings: return 8...11
        case .afternoons: return 12...16
        case .evenings: return 17...22
        case .daily, .weekly, .monthly: return 8...22
        }
    }

    /// "8 AM to 10 PM", in words.
    public var hoursText: String {
        func name(_ h: Int) -> String { h == 12 ? "12 PM" : h < 12 ? "\(h) AM" : "\(h - 12) PM" }
        return "\(name(hours.lowerBound)) to \(name(hours.upperBound))"
    }

    /// The calendar's own day, week (Monday to Sunday) or month `date` is in.
    private func calendarPeriod(containing date: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .daily, .mornings, .afternoons, .evenings: return calendar.dateInterval(of: .day, for: date)
        case .weekly:
            var c = calendar
            c.firstWeekday = 2
            return c.dateInterval(of: .weekOfYear, for: date)
        case .monthly: return calendar.dateInterval(of: .month, for: date)
        }
    }

    /// 8 AM the day before `start`.
    private static func eve(of start: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: -1, to: start)
            .flatMap { calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: $0) }
    }

    /// The period `date` is in: the calendar's day, week or month, each begun at 8 AM the day
    /// before (so a day runs 8 AM to 8 AM, a week from Sunday 8 AM, a month from 8 AM on the last
    /// day of the month before).
    public func period(containing date: Date, calendar: Calendar) -> DateInterval? {
        guard let own = calendarPeriod(containing: date, calendar: calendar),
              let start = Self.eve(of: own.start, calendar: calendar),
              let end = Self.eve(of: own.end, calendar: calendar) else { return nil }
        if date < end { return DateInterval(start: start, end: end) }
        // From 8 AM the day before the next one: that one's begun.
        guard let next = calendarPeriod(containing: own.end, calendar: calendar),
              let nextEnd = Self.eve(of: next.end, calendar: calendar) else { return nil }
        return DateInterval(start: end, end: nextEnd)
    }

    /// The period it's done for, in words ("today", "this morning", "this week").
    public var current: String {
        switch self {
        case .daily: return "today"
        case .mornings: return "this morning"
        case .afternoons: return "this afternoon"
        case .evenings: return "this evening"
        case .weekly: return "this week"
        case .monthly: return "this month"
        }
    }

    /// When completing it lasts until, in words.
    public var until: String {
        switch self {
        case .daily: return "8 AM tomorrow"
        case .mornings: return "tomorrow morning"
        case .afternoons: return "tomorrow afternoon"
        case .evenings: return "tomorrow evening"
        case .weekly: return "8 AM next Sunday"
        case .monthly: return "8 AM on the last day of the month"
        }
    }

    /// What turning it on means, in a few sentences (the confirmation says it).
    public func meaning(note: String) -> String {
        let days: String
        let unit: String
        switch self {
        case .daily: (days, unit) = ("Every day", "day")
        case .mornings: (days, unit) = ("Every morning", "day")
        case .afternoons: (days, unit) = ("Every afternoon", "day")
        case .evenings: (days, unit) = ("Every evening", "day")
        case .weekly: (days, unit) = ("Every week, from Sunday 8 AM", "week")
        case .monthly: (days, unit) = ("Every month, from 8 AM on the last day of the month before", "month")
        }
        return "\(days), a Note reminder for \u{201C}\(note)\u{201D} pops up every hour on the hour, \(hoursText). "
            + "Pending puts it away until the next hour. Completed puts it away until \(until), and marks the note Completed. "
            + "At the start of each \(unit) (8 AM\(unit == "day" ? "" : " the day before")) the note goes back to To do. "
            + "This repeats until you turn \(title) off."
    }
}

/// Where a note's got to: at most one is on.
public enum NoteStatus: String, Codable, CaseIterable, Sendable {
    case todo, pending, completed

    public var title: String {
        switch self {
        case .todo: return "To do"
        case .pending: return "Pending"
        case .completed: return "Completed"
        }
    }

    /// An SF Symbol name.
    public var symbol: String {
        switch self {
        case .todo: return "circle"
        case .pending: return "clock"
        case .completed: return "checkmark.circle.fill"
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
