import Foundation

// The boards themselves: what each is called, its icon, the line under its name (its
// description) and its own color. The ten it comes with (Goals, Strategies, Entities, Notes,
// People, Ideas, Dreams, Projects, Health, Communication) are the first of `slots` places on the
// Boards grid; the rest are blank boards, there to be named and filled. The Daily plan is a board
// of its own, never on the grid, that opens itself at 6 AM, 9 AM and noon. Kept in
// ~/Library/Application Support/ToolMacTool/board-catalog.json (each board's notes are kept in
// boards/<id>.json, as before).

public struct BoardInfo: Codable, Equatable, Sendable {
    public var id: String
    /// What it's called (empty: not named yet, so it's "Board 12").
    public var name: String
    /// Its icon (an SF Symbol name).
    public var symbol: String
    /// The icon it comes with.
    public var defaultSymbol: String
    /// The line under its name.
    public var detail: String
    /// Its own color, a darker shade (red, green and blue from 0 to 1).
    public var red: Double
    public var green: Double
    public var blue: Double
    /// One of the boards that come with the app.
    public var builtin: Bool

    public init(id: String, name: String, symbol: String, detail: String = "", red: Double, green: Double, blue: Double,
                builtin: Bool = false) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.defaultSymbol = symbol
        self.detail = detail
        self.red = red
        self.green = green
        self.blue = blue
        self.builtin = builtin
    }
}

public struct BoardCatalog: Codable, Equatable, Sendable {
    /// The places on the Boards grid (as many as a board has notes).
    public static let slots = Board.maxBoxes
    public static let dailyPlanID = "daily-plan"
    /// The Boards grid's own id (its arrangement is kept as a board: boards/boards.json).
    public static let gridID = "boards"

    /// The ten boards the app comes with, in their places at the start of the grid.
    public static let defaults: [BoardInfo] = [
        BoardInfo(id: "goals", name: "Goals", symbol: "target", detail: "Where I'm going",
                  red: 0.72, green: 0.16, blue: 0.22, builtin: true),
        BoardInfo(id: "strategies", name: "Strategies", symbol: "map", detail: "How I'll get there",
                  red: 0.80, green: 0.38, blue: 0.08, builtin: true),
        BoardInfo(id: "entities", name: "Entities", symbol: "circle.hexagongrid", detail: "Companies, groups and things",
                  red: 0.62, green: 0.50, blue: 0.05, builtin: true),
        BoardInfo(id: "notes", name: "Notes", symbol: "note.text", detail: "Anything worth keeping",
                  red: 0.14, green: 0.52, blue: 0.24, builtin: true),
        BoardInfo(id: "people", name: "People", symbol: "person.2.fill", detail: "Who's who",
                  red: 0.04, green: 0.48, blue: 0.50, builtin: true),
        BoardInfo(id: "ideas", name: "Ideas", symbol: "lightbulb.fill", detail: "To try some day",
                  red: 0.13, green: 0.33, blue: 0.76, builtin: true),
        BoardInfo(id: "dreams", name: "Dreams", symbol: "moon.stars.fill", detail: "The big ones",
                  red: 0.34, green: 0.22, blue: 0.70, builtin: true),
        BoardInfo(id: "projects", name: "Projects", symbol: "hammer.fill", detail: "What I'm making",
                  red: 0.55, green: 0.17, blue: 0.62, builtin: true),
        BoardInfo(id: "health", name: "Health", symbol: "heart.fill", detail: "Body and mind",
                  red: 0.74, green: 0.14, blue: 0.46, builtin: true),
        BoardInfo(id: "communication", name: "Communication", symbol: "bubble.left.and.bubble.right.fill",
                  detail: "Calls, emails and messages", red: 0.42, green: 0.31, blue: 0.22, builtin: true),
    ]

    /// The Daily plan: a board like the others, never on the grid.
    public static let dailyPlanDefault = BoardInfo(id: dailyPlanID, name: "Daily plan", symbol: "sun.horizon.fill",
                                                   detail: "Today, from the top", red: 0.86, green: 0.47, blue: 0.10,
                                                   builtin: true)

    /// The colors the blank boards take in turn.
    public static let blankColors: [(red: Double, green: Double, blue: Double)] = [
        (0.20, 0.42, 0.62), (0.58, 0.26, 0.20), (0.26, 0.50, 0.38), (0.48, 0.30, 0.58), (0.66, 0.44, 0.12),
        (0.16, 0.44, 0.48), (0.62, 0.20, 0.36), (0.34, 0.38, 0.66), (0.40, 0.46, 0.18), (0.50, 0.36, 0.30),
    ]

    /// A blank board for place `i` on the grid.
    public static func blank(_ i: Int) -> BoardInfo {
        let c = blankColors[i % blankColors.count]
        return BoardInfo(id: "custom-\(i + 1)", name: "", symbol: "square.stack.fill", red: c.red, green: c.green, blue: c.blue)
    }

    /// Every board on the grid, in its place: always `slots` of them.
    public var boards: [BoardInfo]
    public var dailyPlan: BoardInfo

    public init(boards: [BoardInfo] = BoardCatalog.defaults, dailyPlan: BoardInfo = BoardCatalog.dailyPlanDefault) {
        self.boards = boards
        self.dailyPlan = dailyPlan
        self = tidied()
    }

    private enum CodingKeys: String, CodingKey { case boards, dailyPlan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boards = (try? c.decodeIfPresent([BoardInfo].self, forKey: .boards)) ?? []
        dailyPlan = (try? c.decodeIfPresent(BoardInfo.self, forKey: .dailyPlan)) ?? Self.dailyPlanDefault
    }

    /// Every board, the Daily plan first.
    public var all: [BoardInfo] { [dailyPlan] + boards }

    public func info(_ id: String) -> BoardInfo? { all.first { $0.id == id } }

    /// Its place on the grid (nil: the Daily plan, or no such board).
    public func slot(_ id: String) -> Int? { boards.firstIndex { $0.id == id } }

    /// What it's called: its name, or "Board 12" while it has none.
    public func title(_ id: String) -> String {
        guard let b = info(id) else { return id }
        let name = b.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return slot(id).map { "Board \($0 + 1)" } ?? "Board"
    }

    /// Exactly `slots` boards, each id once, the ones the app comes with always there (put back
    /// in their own place when missing), the Daily plan as itself.
    public func tidied() -> BoardCatalog {
        var c = self
        var seen = Set<String>([Self.dailyPlanID, Self.gridID])
        c.boards = c.boards.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        for (i, d) in Self.defaults.enumerated() where !seen.contains(d.id) {
            c.boards.insert(d, at: min(i, c.boards.count))
            seen.insert(d.id)
        }
        if c.boards.count > Self.slots { c.boards = Array(c.boards.prefix(Self.slots)) }
        // Blank boards fill the rest, each with an id not taken.
        var n = 1
        while c.boards.count < Self.slots {
            let id = "custom-\(n)"
            n += 1
            guard seen.insert(id).inserted else { continue }
            var b = Self.blank(c.boards.count)
            b.id = id
            c.boards.append(b)
        }
        c.dailyPlan.id = Self.dailyPlanID
        c.dailyPlan.builtin = true
        if c.dailyPlan.name.trimmingCharacters(in: .whitespaces).isEmpty { c.dailyPlan.name = Self.dailyPlanDefault.name }
        for i in c.boards.indices where c.boards[i].symbol.isEmpty { c.boards[i].symbol = c.boards[i].defaultSymbol }
        return c
    }

    /// Where it's kept: ~/Library/Application Support/ToolMacTool/board-catalog.json.
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/board-catalog.json")
    }

    /// The saved boards, or the ones the app comes with (`icons`: icons picked for them before
    /// they were kept here, by id).
    public static func load(from url: URL, icons: [String: String] = [:]) -> BoardCatalog {
        if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(BoardCatalog.self, from: data) {
            return c.tidied()
        }
        var c = BoardCatalog()
        for i in c.boards.indices { if let s = icons[c.boards[i].id] { c.boards[i].symbol = s } }
        return c
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// When the Daily plan opens by itself: at 6 AM, 9 AM and noon, once each (and up to an hour
/// late, when the Mac was asleep at the time; later than that it waits for the next).
public enum DailyPlan {
    public static let hours = [6, 9, 12]
    /// How late it still opens for a time it missed.
    public static let grace: TimeInterval = 3600

    /// The time it's due to open for at `now` (nil: none), given when it last opened by itself.
    public static func due(now: Date, last: Date?, calendar: Calendar) -> Date? {
        let times = hours.compactMap { calendar.date(bySettingHour: $0, minute: 0, second: 0, of: now) }
        guard let time = times.filter({ $0 <= now }).max(), now.timeIntervalSince(time) < grace else { return nil }
        if let last, last >= time { return nil }
        return time
    }

    /// "6 AM, 9 AM and 12 PM".
    public static var hoursText: String {
        let names = hours.map { h in h == 12 ? "12 PM" : h < 12 ? "\(h) AM" : "\(h - 12) PM" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}
