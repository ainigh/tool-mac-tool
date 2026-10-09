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
        /// The notes it links to (on any board), in the order they were added.
        public var links: [NoteLink]
        /// All its buttons shown (off: only its icon, its status, the tags that are on and what
        /// holds something; the rest a click away, at its top right).
        public var controls: Bool
        /// The minute countdowns on (2, 5, 10, 15, 30, 45: any of them at once), each starting over
        /// once its alarm is stopped by a change of status.
        public var countdowns: [NoteCountdown]

        public init(text: String = "", tint: Int = 0, alarm: BoxAlarm? = nil, pinned: Bool = false, icon: String? = nil,
                    tags: [NoteTag] = [], docked: Bool = false, repeats: NoteRepeat? = nil, status: NoteStatus? = nil,
                    statusAt: Date? = nil, remindedAt: Date? = nil, across: Int = 1, down: Int = 1, links: [NoteLink] = [],
                    controls: Bool = false, countdowns: [NoteCountdown] = []) {
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
            self.links = links
            self.controls = controls
            self.countdowns = countdowns
        }

        private enum CodingKeys: String, CodingKey {
            case text, tint, alarm, pinned, icon, tags, docked, repeats, status, statusAt, remindedAt, across, down, links, controls
            case countdowns
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
            links = (try? c.decodeIfPresent([NoteLink].self, forKey: .links)) ?? []
            across = (try? c.decodeIfPresent(Int.self, forKey: .across)) ?? 1
            down = (try? c.decodeIfPresent(Int.self, forKey: .down)) ?? 1
            controls = (try? c.decodeIfPresent(Bool.self, forKey: .controls)) ?? false
            countdowns = ((try? c.decodeIfPresent([NoteCountdown].self, forKey: .countdowns)) ?? [])
                .filter { NoteCountdown.choices.contains($0.minutes) }
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

        // MARK: Its minute countdowns

        /// The countdown of this many minutes, when it's on.
        public func countdown(_ minutes: Int) -> NoteCountdown? { countdowns.first { $0.minutes == minutes } }

        /// A countdown on (counting from `now`) or off again; any others keep going.
        public mutating func toggleCountdown(_ minutes: Int, now: Date) {
            guard NoteCountdown.choices.contains(minutes) else { return }
            if let at = countdowns.firstIndex(where: { $0.minutes == minutes }) {
                countdowns.remove(at: at)
            } else {
                countdowns.append(NoteCountdown(minutes: minutes, start: now))
                countdowns.sort { $0.minutes < $1.minutes }
            }
        }

        /// One of its countdowns is at zero, ringing until the status changes.
        public var isRinging: Bool { countdowns.contains { $0.rang != nil } }

        /// The countdowns that reach zero by `now` start ringing (and wait there): their minutes.
        public mutating func ringCountdowns(now: Date) -> [Int] {
            var rung: [Int] = []
            for k in countdowns.indices where countdowns[k].rang == nil && countdowns[k].end <= now {
                countdowns[k].rang = now
                rung.append(countdowns[k].minutes)
            }
            return rung
        }

        /// The status changed after a countdown began ringing: each ringing one is quiet and counts
        /// down again from then. Returns whether it changed anything.
        public mutating func settleCountdowns() -> Bool {
            guard let statusAt else { return false }
            var changed = false
            for k in countdowns.indices {
                guard let rang = countdowns[k].rang, statusAt > rang else { continue }
                countdowns[k].rang = nil
                countdowns[k].start = statusAt
                changed = true
            }
            return changed
        }

        /// The countdown that rings next (none while they're all ringing).
        public var nextCountdown: NoteCountdown? {
            countdowns.filter { $0.rang == nil }.min { $0.end < $1.end }
        }

        public func has(_ tag: NoteTag) -> Bool { tags.contains(tag) }

        /// The tag on, or off again.
        public mutating func toggle(_ tag: NoteTag) {
            if has(tag) { tags.removeAll { $0 == tag } } else { tags = NoteTag.allCases.filter { $0 == tag || has($0) } }
        }

        /// Its first line of text, trimmed (nil when it has none): what it's called in lists. One
        /// that starts with a component is called by the component's name.
        public var title: String? {
            if text.contains(":::") { return NoteDocument(text).title }
            return text.split(whereSeparator: \.isNewline).lazy
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
    /// The rows the shown boxes are arranged in, when it's set ("in 2 rows"); nil: as many as
    /// fill the board best.
    public var rows: Int?

    public init(shown: Int = Board.defaultShown, boxes: [Box] = [], order: [Int] = []) {
        self.shown = shown
        self.boxes = boxes
        self.order = order
        self = tidied()
    }

    private enum CodingKeys: String, CodingKey { case shown, boxes, order, rows }

    // A file from before the boxes could be ordered has no order: they show as they're kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shown = try c.decodeIfPresent(Int.self, forKey: .shown) ?? Self.defaultShown
        boxes = try c.decodeIfPresent([Box].self, forKey: .boxes) ?? []
        order = (try? c.decodeIfPresent([Int].self, forKey: .order)) ?? []
        rows = (try? c.decodeIfPresent(Int.self, forKey: .rows)) ?? nil
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
        (1.00, 0.84, 0.94),   // pink
        (0.93, 0.97, 0.80),   // lime
        (0.80, 0.90, 0.98),   // ice
        (0.98, 0.93, 0.86),   // sand
        (0.90, 0.92, 0.95),   // fog
        (0.96, 0.86, 1.00),   // lilac
        (1.00, 0.86, 0.78),   // apricot
        (0.82, 0.94, 0.88),   // sage
        (1.00, 0.97, 0.88),   // cream
        (0.86, 0.88, 1.00),   // periwinkle
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
        for i in b.boxes.indices {
            var seenMinutes = Set<Int>()
            b.boxes[i].countdowns = b.boxes[i].countdowns
                .filter { NoteCountdown.choices.contains($0.minutes) && seenMinutes.insert($0.minutes).inserted }
                .sorted { $0.minutes < $1.minutes }
        }
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
    public static func rows(for count: Int, width: Double, height: Double, fixed: Int? = nil) -> [Int] {
        let n = max(count, 1)
        let w = max(width, 1), h = max(height, 1)
        var best: (rows: Int, score: Double) = (1, .infinity)
        if let fixed {
            best.rows = min(max(fixed, 1), n)
        } else {
            for rows in 1...n {
                let columns = Int((Double(n) / Double(rows)).rounded(.up))
                // A row count that leaves a row empty is the same as fewer rows.
                if (rows - 1) * columns >= n { continue }
                let aspect = (w / Double(columns)) / (h / Double(rows))
                let score = abs(log(aspect))
                if score < best.score - 1e-9 { best = (rows, score) }
            }
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

        /// Beside, above or below the other (sharing some of an edge).
        public func touches(_ o: Cell) -> Bool {
            let e = 1e-9
            let sideBySide = (abs(x + width - o.x) < e || abs(o.x + o.width - x) < e)
                && y < o.y + o.height - e && o.y < y + height - e
            let stacked = (abs(y + height - o.y) < e || abs(o.y + o.height - y) < e)
                && x < o.x + o.width - e && o.x < x + width - e
            return sideBySide || stacked
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
            let rows = Self.rows(for: ids.count, width: w, height: h, fixed: self.rows)
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
            // In fixed rows: the fewest blocks across that fit in them (or as near as it gets).
            let over = self.rows.map { Double(max(0, rows - $0)) * 100 } ?? 0
            let score = abs(log(aspect)) + empty + over
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

    /// Every box with text on the board (in the order they were, those shown first), and the empty
    /// ones hidden after them. With none, one box stays shown.
    public mutating func showWritten() {
        let written = Set(boxes.indices.filter { boxes[$0].title != nil })
        showOnly { written.contains($0) }
    }

    /// Every box that `keep`s on the board (in the order they were, those shown first), and the
    /// rest hidden after them. With none, one box stays shown.
    public mutating func showOnly(_ keep: (Int) -> Bool) {
        let kept = order.filter(keep)
        order = kept + order.filter { !keep($0) }
        shown = max(kept.count, Self.minBoxes)
    }

    /// The shown boxes in fixed rows (`count`), each one block again; nil: as many rows as fill
    /// the board best.
    public mutating func arrange(rows count: Int?) {
        rows = count
        guard count != nil else { return }
        for i in visible { (boxes[i].across, boxes[i].down) = (1, 1) }
    }

    /// The colors (not plain paper) given to the shown boxes in turn, each one different from the
    /// boxes beside it, above and below it on the board as it's laid out now.
    public mutating func colorize(width: Double, height: Double) {
        let cells = layout(width: width, height: height).cells
        let colors = Array(1..<Self.tints.count)
        var given: [Int: Int] = [:]
        for (k, cell) in cells.enumerated() {
            let near = Set(cells.filter { $0.box != cell.box && $0.touches(cell) }.compactMap { given[$0.box] })
            let start = k % colors.count
            let turn = colors[start...] + colors[..<start]
            let tint = turn.first { !near.contains($0) } ?? colors[start]
            given[cell.box] = tint
            boxes[cell.box].tint = tint
        }
    }

    /// The next color for a box (a double-click), skipping the ones the boxes around it wear, so it
    /// stands apart from them.
    public func nextTint(for box: Int, width: Double, height: Double) -> Int {
        let cells = layout(width: width, height: height).cells
        guard let cell = cells.first(where: { $0.box == box }) else { return Self.nextTint(after: boxes[box].tint) }
        let near = Set(cells.filter { $0.box != box && $0.touches(cell) }.map { boxes[$0.box].tint })
        var tint = boxes[box].tint
        for _ in Self.tints.indices {
            tint = Self.nextTint(after: tint)
            if !near.contains(tint) { return tint }
        }
        return Self.nextTint(after: boxes[box].tint)
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

/// A note on a board, linked to from another: its board's id and its box (its place in `boxes`,
/// which stays the same however the board is ordered).
public struct NoteLink: Codable, Hashable, Sendable {
    public var board: String
    public var box: Int

    public init(board: String, box: Int) {
        self.board = board
        self.box = box
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
        case .mornings: return "AMs"
        case .afternoons: return "PMs"
        case .evenings: return "Nightly"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
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

/// Where a note's got to: at most one is on. Between Pending (1%) and Completed (100%), how far
/// along it is: 10%, 30%, 40%, 50%, 70% or 90%.
public enum NoteStatus: String, Codable, CaseIterable, Sendable {
    case todo, pending
    case p10, p30, p40, p50, p70, p90
    case completed

    public var title: String {
        switch self {
        case .todo: return "To do"
        case .pending: return "Pending"
        case .completed: return "Completed"
        default: return "\(percent)%"
        }
    }

    /// How far along it is, from 0 (To do) through 1 (Pending) to 100 (Completed).
    public var percent: Int {
        switch self {
        case .todo: return 0
        case .pending: return 1
        case .p10: return 10
        case .p30: return 30
        case .p40: return 40
        case .p50: return 50
        case .p70: return 70
        case .p90: return 90
        case .completed: return 100
        }
    }

    /// The ones between Pending and Completed.
    public var isProgress: Bool { percent > 1 && percent < 100 }

    /// An SF Symbol name (nil for the percentages: they show their number).
    public var symbol: String? {
        switch self {
        case .todo: return "circle"
        case .pending: return "clock"
        case .completed: return "checkmark.circle.fill"
        default: return nil
        }
    }
}

/// One of a note's minute countdowns: it counts down from `start`, rings at zero (`rang`) and waits
/// there, ringing, until the note's status changes; then it counts down again from that moment.
public struct NoteCountdown: Codable, Equatable, Sendable {
    /// The minutes a note can count down (its left side, bottom up).
    public static let choices = [2, 5, 10, 15, 30, 45]

    public var minutes: Int
    /// When this round began.
    public var start: Date
    /// When it reached zero, while it's ringing (nil: counting).
    public var rang: Date?

    public init(minutes: Int, start: Date, rang: Date? = nil) {
        self.minutes = minutes
        self.start = start
        self.rang = rang
    }

    public var seconds: TimeInterval { Double(minutes) * 60 }
    /// When this round reaches zero.
    public var end: Date { start.addingTimeInterval(seconds) }
    /// What's left of this round at `now` (0 once it's at zero).
    public func remaining(now: Date) -> TimeInterval { rang != nil ? 0 : max(0, end.timeIntervalSince(now)) }
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
