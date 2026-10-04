import Foundation

// The boards (Goals, Strategies, Entities, Notes): a big panel of boxes to type into. The arrows
// show more or fewer of them (the hidden ones keep their text), a double-click steps a box through
// light colors, and the grid fills the panel with a gutter that narrows as the boxes get more.
// This is their logic (what's kept, how the grid is laid out); the app draws it.

public struct Board: Codable, Equatable, Sendable {
    public struct Box: Codable, Equatable, Sendable {
        public var text: String
        /// Which of `Board.tints` it wears.
        public var tint: Int

        public init(text: String = "", tint: Int = 0) {
            self.text = text
            self.tint = tint
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
