import Foundation

// Note components: blocks put inline in a note's text (type "/" in a note to pick one), each
// drawn by the note as something to use (a checklist to tick, a table to fill in, a contact with
// its fields, a countdown, a button that runs an action…) and kept as plain, readable text:
//
//     ::: checklist Groceries
//     [x] Milk
//     [ ] Bread
//     :::
//
// The first line opens it (its kind, then whatever it's given: a title, a language, a style),
// the lines after are its body, in a form of its own that reads fine as it is, and ":::" closes
// it. Whatever isn't in a block is the note's text as ever (its first line still its title).
// A block of a kind this version doesn't know is kept as it is, and shown as its text.

/// The kinds of component.
public enum NoteComponentType: String, CaseIterable, Sendable {
    case checklist, table, kanban, proscons
    case contact, properties
    case progress, counter, rating, countdown, habit, calc
    case callout, quote, code, toggle, divider
    case bookmark, image, snippet
    case action, shortcut

    public enum Group: String, CaseIterable, Sendable {
        case lists = "Lists & tables"
        case records = "Records"
        case tracking = "Tracking"
        case text = "Text & layout"
        case media = "Links & media"
        case run = "Runs things"
    }

    public var group: Group {
        switch self {
        case .checklist, .table, .kanban, .proscons: return .lists
        case .contact, .properties: return .records
        case .progress, .counter, .rating, .countdown, .habit, .calc: return .tracking
        case .callout, .quote, .code, .toggle, .divider: return .text
        case .bookmark, .image, .snippet: return .media
        case .action, .shortcut: return .run
        }
    }

    public var title: String {
        switch self {
        case .checklist: return "Checklist"
        case .table: return "Table"
        case .kanban: return "Kanban board"
        case .proscons: return "Pros & cons"
        case .contact: return "Contact"
        case .properties: return "Properties"
        case .progress: return "Progress"
        case .counter: return "Counter"
        case .rating: return "Rating"
        case .countdown: return "Countdown"
        case .habit: return "Habit tracker"
        case .calc: return "Calculator"
        case .callout: return "Callout"
        case .quote: return "Quote"
        case .code: return "Code"
        case .toggle: return "Toggle"
        case .divider: return "Divider"
        case .bookmark: return "Bookmark"
        case .image: return "Image"
        case .snippet: return "Snippet"
        case .action: return "Action button"
        case .shortcut: return "Shortcut button"
        }
    }

    /// An SF Symbol.
    public var symbol: String {
        switch self {
        case .checklist: return "checklist"
        case .table: return "tablecells"
        case .kanban: return "rectangle.split.3x1"
        case .proscons: return "plusminus"
        case .contact: return "person.crop.rectangle"
        case .properties: return "list.bullet.rectangle"
        case .progress: return "chart.bar.fill"
        case .counter: return "plusminus.circle"
        case .rating: return "star.leadinghalf.filled"
        case .countdown: return "calendar.badge.clock"
        case .habit: return "flame"
        case .calc: return "function"
        case .callout: return "lightbulb"
        case .quote: return "quote.opening"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .toggle: return "chevron.right.circle"
        case .divider: return "minus"
        case .bookmark: return "bookmark"
        case .image: return "photo"
        case .snippet: return "doc.on.clipboard"
        case .action: return "bolt.circle"
        case .shortcut: return "bolt.horizontal.circle"
        }
    }

    /// What it's for, in a sentence (the Components window, and the "/" menu's second line).
    public var summary: String {
        switch self {
        case .checklist: return "Items to tick off, with how many are done. Add, untick, reorder or clear the done ones."
        case .table: return "Rows and columns to fill in, with a header row; a total under each column of numbers."
        case .kanban: return "Cards in columns (To do, Doing, Done…): move a card along with a click."
        case .proscons: return "Two lists side by side, for and against, with a tally of each."
        case .contact: return "A person's name, phone, email, company and more: call, email, copy or map them in a click."
        case .properties: return "Named values (Status: Active, Owner: Sam…) laid out as a little record."
        case .progress: return "How far along something is, as a bar: step it on as you go."
        case .counter: return "A number to count up or down: glasses of water, pages read, push-ups."
        case .rating: return "Stars out of five (or ten): for a book, a place, how a day went."
        case .countdown: return "Days, hours and minutes to a date (or since it), kept up to date."
        case .habit: return "The last weeks as a grid of days: tick today, see your streak."
        case .calc: return "Sums worked out line by line: name a line (rent = 1200) and use it below; total adds up the rest."
        case .callout: return "A note to stand out: info, a tip, a warning or a success, on its own color."
        case .quote: return "Something someone said, and who said it."
        case .code: return "Code or any fixed-width text, with its language, and a button to copy it."
        case .toggle: return "A heading that opens to show the text under it, and closes it away again."
        case .divider: return "A line across, to split the note into parts."
        case .bookmark: return "A web page as a card: its icon, title and site. A click opens it."
        case .image: return "A picture from a file on this Mac or a web address, with a caption."
        case .snippet: return "Text kept to paste again and again: a click copies it."
        case .action: return "A button that runs one of your Actions (from the Actions window), right from the note."
        case .shortcut: return "A button that runs one of your Apple Shortcuts, with the text it's given, and shows what it gave back."
        }
    }

    /// More words it's found by in the "/" menu.
    public var keywords: [String] {
        switch self {
        case .checklist: return ["todo", "tasks", "check", "list"]
        case .table: return ["grid", "spreadsheet", "rows", "columns"]
        case .kanban: return ["board", "columns", "cards", "trello"]
        case .proscons: return ["decision", "for", "against", "compare"]
        case .contact: return ["person", "people", "phone", "email", "address", "card"]
        case .properties: return ["fields", "key", "value", "meta", "record"]
        case .progress: return ["bar", "percent", "goal"]
        case .counter: return ["count", "tally", "number"]
        case .rating: return ["stars", "score", "review"]
        case .countdown: return ["date", "deadline", "days", "until", "event"]
        case .habit: return ["streak", "daily", "tracker"]
        case .calc: return ["math", "sum", "budget", "numbers", "total"]
        case .callout: return ["info", "warning", "tip", "note", "alert"]
        case .quote: return ["citation", "said"]
        case .code: return ["snippet", "monospace", "program"]
        case .toggle: return ["collapse", "details", "fold", "hide"]
        case .divider: return ["line", "rule", "separator", "hr"]
        case .bookmark: return ["link", "url", "web", "page"]
        case .image: return ["picture", "photo", "screenshot"]
        case .snippet: return ["copy", "clipboard", "template", "paste"]
        case .action: return ["run", "button", "automate"]
        case .shortcut: return ["run", "button", "apple shortcuts"]
        }
    }

    /// What it's given on its first line when it's new (a title, a style, a language…).
    public var defaultArgs: String {
        switch self {
        case .checklist: return "To do"
        case .table, .kanban, .proscons, .properties, .contact, .habit, .calc, .divider, .bookmark, .image, .rating: return ""
        case .progress: return "Progress"
        case .counter: return "Count"
        case .countdown: return "Launch"
        case .callout: return "info"
        case .quote: return ""
        case .code: return "swift"
        case .toggle: return "More"
        case .snippet: return "Snippet"
        case .action: return ""
        case .shortcut: return ""
        }
    }

    /// Its body when it's new.
    public func defaultBody(now: Date = Date(), calendar: Calendar = .current) -> [String] {
        switch self {
        case .checklist: return ["[ ] "]
        case .table: return ["| Item | Amount |", "|  |  |"]
        case .kanban: return ["# To do", "- ", "# Doing", "# Done"]
        case .proscons: return ["+ ", "- "]
        case .contact: return ContactField.allCases.prefix(4).map { "\($0.rawValue): " }
        case .properties: return ["Status: ", "Owner: "]
        case .progress: return ["value: 0", "total: 10"]
        case .counter: return ["count: 0", "step: 1"]
        case .rating: return ["rating: 0", "of: 5"]
        case .countdown:
            let week = calendar.date(byAdding: .day, value: 7, to: now) ?? now
            return ["date: " + NoteComponents.dateString(week, calendar: calendar, time: false)]
        case .habit: return []
        case .calc: return ["rent = 1200", "food = 400", "total"]
        case .callout: return [""]
        case .quote: return ["", "— "]
        case .code: return [""]
        case .toggle: return [""]
        case .divider: return []
        case .bookmark: return ["https://"]
        case .image: return [""]
        case .snippet: return [""]
        case .action: return []
        case .shortcut: return [""]
        }
    }

    /// A filled-in example, for the Components window.
    public func sample(now: Date = Date(), calendar: Calendar = .current) -> NoteComponent {
        func make(_ args: String, _ body: [String]) -> NoteComponent { NoteComponent(kind: rawValue, args: args, body: body) }
        switch self {
        case .checklist: return make("Groceries", ["[x] Milk", "[ ] Bread", "[ ] Coffee beans"])
        case .table: return make("Trip budget", ["| Item | Cost |", "| Flights | 420 |", "| Hotel | 380 |", "| Food | 150 |"])
        case .kanban: return make("Launch", ["# To do", "- Write the post", "# Doing", "- Record the demo", "# Done", "- Pick a date"])
        case .proscons: return make("Move to Lisbon?", ["+ Sunshine", "+ Lower rent", "- Far from family"])
        case .contact: return make("", ["Name: Ada Lovelace", "Phone: +44 20 7946 0000", "Email: ada@example.com", "Company: Analytical Engines",
                                        "Birthday: 1815-12-10"])
        case .properties: return make("", ["Status: In progress", "Owner: Sam", "Due: Friday"])
        case .progress: return make("Book chapters", ["value: 7", "total: 12"])
        case .counter: return make("Glasses of water", ["count: 5", "step: 1"])
        case .rating: return make("Dune", ["rating: 4", "of: 5"])
        case .countdown:
            let later = calendar.date(byAdding: .day, value: 12, to: now) ?? now
            return make("Holiday", ["date: " + NoteComponents.dateString(later, calendar: calendar, time: false)])
        case .habit:
            let days = [0, 1, 2, 4, 5].compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
            return make("Walk", days.map { NoteComponents.dateString($0, calendar: calendar, time: false) })
        case .calc: return make("Month", ["rent = 1200", "food = 400", "travel = 90 * 2", "total"])
        case .callout: return make("idea", ["Ask for feedback before Friday."])
        case .quote: return make("", ["Simplicity is prerequisite for reliability.", "— Edsger Dijkstra"])
        case .code: return make("swift", ["let total = items.map(\\.cost).reduce(0, +)"])
        case .toggle: return make("Meeting notes", ["Agreed the plan; Sam sends the deck."])
        case .divider: return make("", [])
        case .bookmark: return make("", ["https://www.apple.com"])
        case .image: return make("The view", ["https://images.unsplash.com/photo-1501785888041-af3ef285b470?w=640"])
        case .snippet: return make("Address", ["1 Infinite Loop, Cupertino, CA 95014"])
        case .action: return make("Drink some water", [])
        case .shortcut: return make("", [""])
        }
    }

    /// A new one, as text to put in a note.
    public func template(now: Date = Date(), calendar: Calendar = .current) -> String {
        NoteComponent(kind: rawValue, args: defaultArgs, body: defaultBody(now: now, calendar: calendar)).text
    }

    /// The "/" menu's match: by name, kind and keywords (empty matches everything), best first.
    public static func matching(_ query: String) -> [NoteComponentType] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return allCases }
        func score(_ t: NoteComponentType) -> Int? {
            let title = t.title.lowercased()
            if title.hasPrefix(q) || t.rawValue.hasPrefix(q) { return 0 }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
            if t.keywords.contains(where: { $0.hasPrefix(q) }) { return 2 }
            if title.contains(q) || t.keywords.contains(where: { $0.contains(q) }) { return 3 }
            return nil
        }
        return allCases.compactMap { t in score(t).map { (t, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }
}

/// One component in a note: its kind, what it's given on its first line, and its body.
public struct NoteComponent: Equatable, Sendable {
    /// Its kind, as written (one this version doesn't know is kept as it is).
    public var kind: String { didSet { openLine = nil } }
    /// The rest of its first line: a title, a style, a language.
    public var args: String { didSet { openLine = nil } }
    public var body: [String]
    /// Its first and last lines as they were written (kept until it's changed, so a note reads
    /// back exactly as it was).
    var openLine: String?
    var closeLine: String?

    public init(kind: String, args: String = "", body: [String] = []) {
        self.kind = kind
        self.args = args.trimmingCharacters(in: .whitespaces)
        self.body = body
    }

    public var type: NoteComponentType? { NoteComponentType(rawValue: kind) }

    /// What it's called: its title (its first line's words), else its kind's name.
    public var name: String {
        switch type {
        case .callout, .code: return type?.title ?? kind
        default: return args.isEmpty ? (type?.title ?? kind) : args
        }
    }

    /// Its lines, as they go in the note.
    public var lines: [String] {
        [openLine ?? ("::: " + kind + (args.isEmpty ? "" : " " + args))] + body + [closeLine ?? NoteDocument.close]
    }

    public var text: String { lines.joined(separator: "\n") }

    /// Its body as one text (line breaks between the lines).
    public var bodyText: String {
        get { body.joined(separator: "\n") }
        set { body = newValue.isEmpty ? [] : newValue.components(separatedBy: "\n") }
    }
}

/// A note's text, split into its runs of text and its components.
public struct NoteDocument: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case text([String])
        case component(NoteComponent)

        public var lines: [String] {
            switch self {
            case .text(let lines): return lines
            case .component(let c): return c.lines
            }
        }

        public var component: NoteComponent? {
            if case .component(let c) = self { return c }
            return nil
        }
    }

    public static let close = ":::"

    public var segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    /// The text split into its runs and components. A block that's never closed is text.
    public init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        var out: [Segment] = []
        var run: [String] = []
        var i = 0
        while i < lines.count {
            if let (kind, args) = Self.opening(lines[i]),
               let end = lines[(i + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.close }) {
                if !run.isEmpty { out.append(.text(run)) }
                run = []
                var c = NoteComponent(kind: kind, args: args, body: Array(lines[(i + 1)..<end]))
                c.openLine = lines[i]
                c.closeLine = lines[end]
                out.append(.component(c))
                i = end + 1
            } else {
                run.append(lines[i])
                i += 1
            }
        }
        if !run.isEmpty || out.isEmpty { out.append(.text(run)) }
        segments = out
    }

    /// "::: checklist Groceries" → ("checklist", "Groceries").
    static func opening(_ line: String) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(":::") else { return nil }
        let rest = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard let first = rest.first, first.isLetter, first.isASCII else { return nil }
        let kind = rest.prefix { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") && $0.isASCII }
        let after = rest.dropFirst(kind.count)
        guard after.isEmpty || after.first == " " else { return nil }
        return (kind.lowercased(), after.trimmingCharacters(in: .whitespaces))
    }

    /// Whether a text has a component (quick: no ":::" at all, none).
    public static func hasComponents(_ text: String) -> Bool {
        text.contains(":::") && NoteDocument(text).components.count > 0
    }

    public var text: String { segments.flatMap(\.lines).joined(separator: "\n") }

    public var components: [NoteComponent] { segments.compactMap(\.component) }

    /// The text outside the components.
    public var plainText: String {
        segments.compactMap { if case .text(let l) = $0 { return l.joined(separator: "\n") } else { return nil } }
            .joined(separator: "\n")
    }

    /// What a note is called: its first line of text, else its first component's name.
    public var title: String? {
        for s in segments {
            switch s {
            case .text(let lines):
                if let line = lines.lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) { return line }
            case .component(let c):
                return c.name
            }
        }
        return nil
    }

    /// Component `index` (counting only the components) changed.
    public mutating func setComponent(_ index: Int, _ new: NoteComponent) {
        guard let s = segmentIndex(ofComponent: index) else { return }
        segments[s] = .component(new)
    }

    /// Component `index` taken out (and the text around it kept).
    public mutating func removeComponent(_ index: Int) {
        guard let s = segmentIndex(ofComponent: index) else { return }
        segments.remove(at: s)
        if segments.isEmpty { segments = [.text([""])] }
    }

    /// Component `index` moved past the component (and the text between) before (-1) or after (+1) it.
    public mutating func moveComponent(_ index: Int, by step: Int) {
        guard let s = segmentIndex(ofComponent: index), let t = segmentIndex(ofComponent: index + step) else { return }
        segments.swapAt(s, t)
    }

    /// A copy of component `index`, right after it.
    public mutating func duplicateComponent(_ index: Int) {
        guard let s = segmentIndex(ofComponent: index), case .component(var c) = segments[s] else { return }
        c.openLine = nil
        c.closeLine = nil
        segments.insert(.component(c), at: s + 1)
    }

    func segmentIndex(ofComponent index: Int) -> Int? {
        var n = -1
        for (i, s) in segments.enumerated() where s.component != nil {
            n += 1
            if n == index { return i }
        }
        return nil
    }
}

// MARK: - The bodies

/// The fields a contact can have, in order.
public enum ContactField: String, CaseIterable, Sendable {
    case name = "Name", phone = "Phone", email = "Email", company = "Company", role = "Role", address = "Address",
         website = "Website", birthday = "Birthday", notes = "Notes"

    public var symbol: String {
        switch self {
        case .name: return "person"
        case .phone: return "phone"
        case .email: return "envelope"
        case .company: return "building.2"
        case .role: return "briefcase"
        case .address: return "mappin.and.ellipse"
        case .website: return "globe"
        case .birthday: return "gift"
        case .notes: return "text.alignleft"
        }
    }
}

public enum NoteComponents {
    // MARK: Checklist

    public struct Item: Equatable, Sendable {
        public var done: Bool
        public var text: String
        public init(done: Bool = false, text: String) {
            self.done = done
            self.text = text
        }
    }

    /// "[x] Milk", "- [ ] Bread"; any other line is an item not done.
    public static func checklist(_ body: [String]) -> [Item] {
        body.map { line in
            var t = Substring(line.trimmingCharacters(in: .whitespaces))
            if t.hasPrefix("- ") || t.hasPrefix("* ") { t = t.dropFirst(2) }
            for (mark, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where t.hasPrefix(mark) {
                return Item(done: done, text: String(t.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces))
            }
            return Item(text: String(t))
        }
    }

    public static func checklistBody(_ items: [Item]) -> [String] {
        items.map { ($0.done ? "[x] " : "[ ] ") + $0.text }
    }

    // MARK: Table

    /// "| a | b |" rows (a "|---|" row skipped; "\|" is a | in a cell). Every row as wide as the widest.
    public static func table(_ body: [String]) -> [[String]] {
        var rows: [[String]] = []
        for line in body {
            var t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
            var cells: [String] = []
            var cell = ""
            var escaped = false
            for ch in t {
                if escaped {
                    cell.append(ch == "|" ? "|" : "\\" + String(ch))
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "|" {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                } else {
                    cell.append(ch)
                }
            }
            if escaped { cell.append("\\") }
            cells.append(cell.trimmingCharacters(in: .whitespaces))
            if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
            rows.append(cells)
        }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    public static func tableBody(_ rows: [[String]]) -> [String] {
        rows.map { row in
            "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " | ") + " |"
        }
    }

    /// Each column's total (nil when it isn't a column of numbers), the header row left out.
    public static func totals(_ rows: [[String]]) -> [Double?] {
        guard let width = rows.first?.count else { return [] }
        let data = rows.dropFirst()
        return (0..<width).map { c in
            let cells = data.map { $0.indices.contains(c) ? $0[c] : "" }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !cells.isEmpty else { return nil }
            let numbers = cells.compactMap(number)
            return numbers.count == cells.count ? numbers.reduce(0, +) : nil
        }
    }

    /// "1,200", "$42.50", "-3", "12%" as a number.
    public static func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "$€£¥%"))
        guard !t.isEmpty else { return nil }
        return Double(t)
    }

    /// 1200 → "1,200"; 3.5 → "3.5".
    public static func format(_ n: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    // MARK: Fields

    public struct Field: Equatable, Sendable {
        public var key: String
        public var value: String
        public init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }
    }

    /// "Key: value" lines (a line with no ": " is a value with no key).
    public static func fields(_ body: [String]) -> [Field] {
        body.compactMap { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            if let r = line.range(of: ":") {
                return Field(line[..<r.lowerBound].trimmingCharacters(in: .whitespaces),
                             line[r.upperBound...].trimmingCharacters(in: .whitespaces))
            }
            return Field("", line.trimmingCharacters(in: .whitespaces))
        }
    }

    public static func fieldsBody(_ fields: [Field]) -> [String] {
        fields.map { $0.key.isEmpty ? $0.value : "\($0.key): \($0.value)" }
    }

    /// The value of the first field named `key` (any case).
    public static func value(_ key: String, in body: [String]) -> String? {
        fields(body).first { $0.key.lowercased() == key.lowercased() }?.value
    }

    /// The body with field `key` set to `value` (added at the end when it isn't there).
    public static func setting(_ key: String, _ value: String, in body: [String]) -> [String] {
        var f = fields(body)
        if let i = f.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) { f[i].value = value } else { f.append(Field(key, value)) }
        return fieldsBody(f)
    }

    /// A field's number (`fallback` when it isn't one).
    public static func number(_ key: String, in body: [String], fallback: Double) -> Double {
        value(key, in: body).flatMap(number) ?? fallback
    }

    // MARK: Kanban

    public struct Column: Equatable, Sendable {
        public var title: String
        public var cards: [String]
        public init(_ title: String, _ cards: [String] = []) {
            self.title = title
            self.cards = cards
        }
    }

    /// "# Column" lines, each followed by its "- card" lines (cards before any column go in "To do").
    public static func kanban(_ body: [String]) -> [Column] {
        var out: [Column] = []
        for line in body {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                out.append(Column(t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if !t.isEmpty {
                let card = t.hasPrefix("- ") || t.hasPrefix("* ") ? String(t.dropFirst(2)) : (t == "-" ? "" : t)
                if out.isEmpty { out.append(Column("To do")) }
                out[out.count - 1].cards.append(card)
            }
        }
        return out
    }

    public static func kanbanBody(_ columns: [Column]) -> [String] {
        columns.flatMap { ["# " + $0.title] + $0.cards.map { "- " + $0 } }
    }

    // MARK: Pros & cons

    /// "+ pro" and "- con" lines.
    public static func prosCons(_ body: [String]) -> (pros: [String], cons: [String]) {
        var pros: [String] = [], cons: [String] = []
        for line in body {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("+") { pros.append(t.dropFirst().trimmingCharacters(in: .whitespaces)) }
            else if t.hasPrefix("-") { cons.append(t.dropFirst().trimmingCharacters(in: .whitespaces)) }
            else if !t.isEmpty { pros.append(t) }
        }
        return (pros, cons)
    }

    public static func prosConsBody(pros: [String], cons: [String]) -> [String] {
        pros.map { "+ " + $0 } + cons.map { "- " + $0 }
    }

    // MARK: Quote

    /// The quote's lines, and who said it (a last line starting "— " or "-- ").
    public static func quote(_ body: [String]) -> (text: String, author: String) {
        var lines = body
        var author = ""
        if let last = lines.last?.trimmingCharacters(in: .whitespaces) {
            for dash in ["— ", "-- ", "—", "--"] where last.hasPrefix(dash) {
                author = String(last.dropFirst(dash.count)).trimmingCharacters(in: .whitespaces)
                lines.removeLast()
                break
            }
        }
        return (lines.joined(separator: "\n"), author)
    }

    public static func quoteBody(text: String, author: String) -> [String] {
        (text.isEmpty ? [""] : text.components(separatedBy: "\n")) + ["— " + author]
    }

    // MARK: Dates

    /// "2026-12-25" or "2026-12-25 09:30".
    public static func dateString(_ date: Date, calendar: Calendar, time: Bool) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return time ? day + String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0) : day
    }

    /// "2026-12-25" (the start of that day) or "2026-12-25 09:30" (or with a T).
    public static func date(_ text: String, calendar: Calendar) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        let parts = t.split(separator: " ")
        guard let first = parts.first else { return nil }
        let d = first.split(separator: "-").compactMap { Int($0) }
        guard d.count == 3, (1...12).contains(d[1]), (1...31).contains(d[2]) else { return nil }
        var c = DateComponents(year: d[0], month: d[1], day: d[2], hour: 0, minute: 0)
        if parts.count > 1 {
            let tm = parts[1].split(separator: ":").compactMap { Int($0) }
            guard tm.count >= 2, (0...23).contains(tm[0]), (0...59).contains(tm[1]) else { return nil }
            c.hour = tm[0]
            c.minute = tm[1]
        }
        return calendar.date(from: c)
    }

    /// "12 days 3 h", "5 h 20 min", "4 min", "now"; with `past` true when it's gone by.
    public static func span(from now: Date, to date: Date) -> (text: String, past: Bool) {
        let s = Int(date.timeIntervalSince(now))
        let past = s < 0
        let a = abs(s)
        let d = a / 86_400, h = (a % 86_400) / 3600, m = (a % 3600) / 60
        let text: String
        if a < 60 { text = "now" }
        else if d > 0 { text = "\(d) day\(d == 1 ? "" : "s")" + (d < 10 && h > 0 ? " \(h) h" : "") }
        else if h > 0 { text = "\(h) h" + (m > 0 ? " \(m) min" : "") }
        else { text = "\(m) min" }
        return (text, past && a >= 60)
    }

    // MARK: Habit

    /// The days ticked ("2026-10-08" lines), as day strings.
    public static func habitDays(_ body: [String]) -> Set<String> {
        Set(body.map { String($0.trimmingCharacters(in: .whitespaces).prefix(10)) }.filter { $0.count == 10 })
    }

    public static func habitBody(_ days: Set<String>) -> [String] { days.sorted() }

    /// Days in a row ticked, up to today (or up to yesterday, while today isn't ticked yet).
    public static func streak(_ days: Set<String>, now: Date, calendar: Calendar) -> Int {
        var day = calendar.startOfDay(for: now)
        if !days.contains(dateString(day, calendar: calendar, time: false)) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = y
        }
        var n = 0
        while days.contains(dateString(day, calendar: calendar, time: false)) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    // MARK: Calculator

    public struct CalcLine: Equatable, Sendable {
        /// The name it's given ("rent = 1200"), if any.
        public var name: String?
        /// What it works out to; nil for a blank line, or one that isn't a sum (`error` says why).
        public var value: Double?
        public var error: String?
    }

    /// Each line worked out: "rent = 1200" names a line, a name is its value below it, "total"
    /// (or "sum") alone adds up the lines above it since the last total; a line starting "#" or
    /// "//" is a comment.
    public static func calc(_ body: [String]) -> [CalcLine] {
        var vars: [String: Double] = [:]
        var run: [Double] = []
        return body.map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { return CalcLine() }
            var name: String?
            var expr = line
            if let eq = line.firstIndex(of: "="), let n = Optional(line[..<eq].trimmingCharacters(in: .whitespaces)),
               !n.isEmpty, n.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == " " }), n.first?.isLetter == true {
                name = n.lowercased().replacingOccurrences(of: " ", with: "_")
                expr = String(line[line.index(after: eq)...])
            }
            let key = expr.trimmingCharacters(in: .whitespaces).lowercased()
            if key == "total" || key == "sum" {
                let total = run.reduce(0, +)
                run = []
                if let name { vars[name] = total }
                return CalcLine(name: name, value: total)
            }
            do {
                var p = Arithmetic(expr, vars: vars)
                let v = try p.parse()
                if let name { vars[name] = v }
                run.append(v)
                return CalcLine(name: name, value: v)
            } catch let e as Arithmetic.Failure {
                return CalcLine(name: name, error: e.why)
            } catch {
                return CalcLine(name: name, error: "Not a sum")
            }
        }
    }
}

/// + - * / % ^, brackets, numbers (1,200 · 3.5 · 20%) and names. Never crashes on what it's given.
struct Arithmetic {
    struct Failure: Error { let why: String }

    private let chars: [Character]
    private var i = 0
    private let vars: [String: Double]
    private var depth = 0

    init(_ text: String, vars: [String: Double]) {
        chars = Array(text)
        self.vars = vars
    }

    mutating func parse() throws -> Double {
        let v = try sum()
        skip()
        guard i == chars.count else { throw Failure(why: "Can't read \u{201C}\(String(chars[i...]).prefix(12))\u{201D}") }
        guard v.isFinite else { throw Failure(why: "Too big, or divided by 0") }
        return v
    }

    private mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }

    private mutating func sum() throws -> Double {
        var v = try product()
        while true {
            skip()
            guard i < chars.count, chars[i] == "+" || chars[i] == "-" || chars[i] == "−" else { return v }
            let op = chars[i]
            i += 1
            let r = try product()
            v = op == "+" ? v + r : v - r
        }
    }

    private mutating func product() throws -> Double {
        var v = try power()
        while true {
            skip()
            guard i < chars.count, "*/×÷x".contains(chars[i]) else { return v }
            // "x" is a times only between numbers (not the start of a name).
            if chars[i] == "x", i + 1 < chars.count, chars[i + 1].isLetter { return v }
            let op = chars[i]
            i += 1
            let r = try power()
            v = (op == "/" || op == "÷") ? v / r : v * r
        }
    }

    private mutating func power() throws -> Double {
        let base = try unary()
        skip()
        if i < chars.count, chars[i] == "^" {
            i += 1
            return pow(base, try power())
        }
        return base
    }

    private mutating func unary() throws -> Double {
        skip()
        if i < chars.count, chars[i] == "-" || chars[i] == "−" {
            i += 1
            return -(try unary())
        }
        if i < chars.count, chars[i] == "+" {
            i += 1
            return try unary()
        }
        return try atom()
    }

    private mutating func atom() throws -> Double {
        skip()
        guard i < chars.count else { throw Failure(why: "Something's missing at the end") }
        let c = chars[i]
        if c == "(" {
            depth += 1
            guard depth < 64 else { throw Failure(why: "Too many brackets") }
            i += 1
            let v = try sum()
            skip()
            guard i < chars.count, chars[i] == ")" else { throw Failure(why: "A bracket isn't closed") }
            i += 1
            depth -= 1
            return v
        }
        if c.isNumber || c == "." || c == "$" || c == "€" || c == "£" {
            if "$€£".contains(c) { i += 1 }
            var s = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "," {
                if chars[i] != "," { s.append(chars[i]) }
                i += 1
            }
            guard var v = Double(s) else { throw Failure(why: "\u{201C}\(s)\u{201D} isn't a number") }
            if i < chars.count, chars[i] == "%" {
                i += 1
                v /= 100
            }
            return v
        }
        if c.isLetter || c == "_" {
            var s = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                s.append(chars[i])
                i += 1
            }
            let key = s.lowercased()
            if let v = vars[key] { return v }
            if key == "pi" { return Double.pi }
            throw Failure(why: "\u{201C}\(s)\u{201D} isn't named above")
        }
        throw Failure(why: "Can't read \u{201C}\(c)\u{201D}")
    }
}

// MARK: - Typing "/" in a note

public enum NoteSlash {
    /// The "/query" being typed just before `caret` (in UTF-16 units): a "/" at the start of a line
    /// or after a space, then letters (and spaces) up to the caret. Nil otherwise (a web address's
    /// "//", a date's "1/2", a selection).
    public static func query(in text: String, caret: Int) -> (location: Int, length: Int, query: String)? {
        let s = text as NSString
        guard caret >= 0, caret <= s.length else { return nil }
        var i = caret - 1
        while i >= 0 {
            let c = s.character(at: i)
            if c == 0x2F { break }
            if c == 0x0A { return nil }
            guard let u = UnicodeScalar(c), CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) || c == 0x20 else {
                return nil
            }
            i -= 1
        }
        guard i >= 0 else { return nil }
        if i > 0 {
            let before = s.character(at: i - 1)
            guard before == 0x20 || before == 0x0A || before == 0x09 else { return nil }
        }
        let q = s.substring(with: NSRange(location: i + 1, length: caret - i - 1))
        guard q.count <= 24, !q.hasPrefix(" "), !q.hasSuffix("  ") else { return nil }
        return (i, caret - i, q)
    }

    /// What replaces the "/query" (`location`, `length`) when a component is picked: the
    /// component on lines of its own (a line break before it when there's text before it on its
    /// line, and after it when there's text after it).
    public static func replacement(_ block: String, in text: String, location: Int, length: Int) -> String {
        let s = text as NSString
        let line = s.lineRange(for: NSRange(location: location, length: 0))
        let before = s.substring(with: NSRange(location: line.location, length: location - line.location))
        let end = location + length
        var after = ""
        if end < s.length {
            let rest = s.lineRange(for: NSRange(location: end, length: 0))
            after = s.substring(with: NSRange(location: end, length: rest.location + rest.length - end))
        }
        let pre = before.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\n"
        let post = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        return pre + block + post
    }
}

extension NoteDocument {
    /// Component `index` swapped for what `text` reads as (it may be text, one component or more).
    public mutating func replaceComponent(_ index: Int, withText text: String) {
        guard let s = segmentIndex(ofComponent: index) else { return }
        segments.replaceSubrange(s...s, with: NoteDocument(text).segments)
    }
}
