import Foundation

// Redaction: a map of every sensitive word you've met (names, mostly) to what stands in for it,
// kept on this Mac and filled in over time, and a mechanical swap of text through it. The model
// only ever lists the names it finds, one word a line (so "Ada Lovelace" is two entries); the
// swapping is done here, the same way every time: whole words, all at once (a substitute is never
// swapped again), the original's capitals kept. Restore swaps back.

public struct RedactionMap: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        /// The word as found (one word: a first or last name on its own).
        public var original: String
        /// What it becomes ("Person12" to start with; anything you like, several originals can
        /// share one).
        public var substitute: String
        /// Not redacted (the model took an ordinary word for a name: "May", "Will").
        public var keep: Bool
        /// Not looked at yet: found by the model, its substitute still the one it was given.
        public var isNew: Bool
        /// How many times it's been found.
        public var seen: Int
        public var added: Date
        public var note: String
        /// In the Critical bucket: the few words that matter most (watched closely, and checked
        /// for in every redacted text). Redacting treats both buckets as one map.
        public var critical: Bool

        public init(id: UUID = UUID(), original: String, substitute: String, keep: Bool = false, isNew: Bool = true,
                    seen: Int = 1, added: Date = Date(), note: String = "", critical: Bool = false) {
            self.id = id
            self.original = original
            self.substitute = substitute
            self.keep = keep
            self.isNew = isNew
            self.seen = seen
            self.added = added
            self.note = note
            self.critical = critical
        }

        private enum CodingKeys: String, CodingKey { case id, original, substitute, keep, isNew, seen, added, note, critical }

        // A map from before the buckets has no `critical`: everything is in the everyday one.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            original = try c.decodeIfPresent(String.self, forKey: .original) ?? ""
            substitute = try c.decodeIfPresent(String.self, forKey: .substitute) ?? ""
            keep = try c.decodeIfPresent(Bool.self, forKey: .keep) ?? false
            isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
            seen = try c.decodeIfPresent(Int.self, forKey: .seen) ?? 0
            added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            critical = try c.decodeIfPresent(Bool.self, forKey: .critical) ?? false
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// The entry for a word, matched without regard to case.
    public func entry(for word: String) -> Entry? {
        let key = Redaction.key(word)
        return entries.first { Redaction.key($0.original) == key }
    }

    /// The next free "Person<n>".
    public func nextPlaceholder(prefix: String = "Person") -> String {
        let used = Set(entries.map(\.substitute))
        var n = entries.count + 1
        // Start just past the highest one used, then step past any taken.
        let numbers = entries.compactMap { e -> Int? in
            guard e.substitute.hasPrefix(prefix) else { return nil }
            return Int(e.substitute.dropFirst(prefix.count))
        }
        if let top = numbers.max() { n = top + 1 }
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// Learns the words: each new one is added with a placeholder (and marked new), each known one
    /// counted again. Returns the ones that were new.
    @discardableResult
    public mutating func learn(_ words: [String], now: Date = Date()) -> [String] {
        var added: [String] = []
        for word in words {
            let key = Redaction.key(word)
            guard !key.isEmpty else { continue }
            if let i = entries.firstIndex(where: { Redaction.key($0.original) == key }) {
                entries[i].seen += 1
            } else {
                entries.append(Entry(original: word, substitute: nextPlaceholder(), added: now))
                added.append(word)
            }
        }
        return added
    }

    /// The pairs the swap uses: not kept, with a substitute, the original not empty.
    public var pairs: [(original: String, substitute: String)] {
        entries.filter { !$0.keep && !$0.original.isEmpty && !$0.substitute.isEmpty && $0.original != $0.substitute }
            .map { ($0.original, $0.substitute) }
    }

    /// The critical words (not kept): the ones to check every redacted text for.
    public var critical: [Entry] { entries.filter { $0.critical && !$0.keep && !$0.original.isEmpty } }

    /// Originals that share a substitute with another (fine: the swap goes one way; restoring
    /// gives back the first of them).
    public var shared: Set<String> {
        let groups = Dictionary(grouping: entries.filter { !$0.keep && !$0.substitute.isEmpty }, by: \.substitute)
        return Set(groups.filter { $0.value.count > 1 }.keys)
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/redaction-map.json")
    }

    public static func load(from url: URL) -> RedactionMap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let map = try? decoder.decode(RedactionMap.self, from: data) else {
            return RedactionMap()
        }
        return map
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum Redaction {
    /// How a word is compared: case and accents set aside.
    public static func key(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: Asking the model

    /// What the model is asked: the names, one word a line, nothing else.
    public static func prompt(_ text: String) -> String {
        """
        List the names of every person mentioned in the text below: first names, last names, middle names and \
        nicknames. Write ONE WORD PER LINE: split a full name onto separate lines ("Ada Lovelace" is two lines: Ada, \
        then Lovelace). Leave out titles (Mr, Dr), places, companies and ordinary words. No numbering, no bullets, no \
        explanation: only the words, each once. If there are none, write NONE.

        TEXT:
        \(text)
        """
    }

    public static let system = "You find people's names in text. You answer only with the names, one word per line."

    /// The words in the model's answer: every line split at spaces (so first and last names come
    /// apart), bullets, numbering, quotes and punctuation trimmed, a possessive 's taken off,
    /// "NONE" and anything in <think> tags left out, each word once (the first spelling kept).
    public static func parseNames(_ answer: String) -> [String] {
        var text = answer
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let edges = CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-'"))
        var out: [String] = []
        var seen = Set<String>()
        for token in text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))) {
            var word = token.trimmingCharacters(in: edges)
            for suffix in ["'s", "’s"] where word.lowercased().hasSuffix(suffix) { word = String(word.dropLast(2)) }
            word = word.trimmingCharacters(in: CharacterSet(charactersIn: "-'’").union(edges))
            // Numbering ("1." "2)") and stray single letters are not names.
            guard word.count >= 2, word.rangeOfCharacter(from: .letters) != nil, !word.allSatisfy(\.isNumber) else { continue }
            if word.uppercased() == "NONE" { continue }
            if ["mr", "mrs", "ms", "dr", "prof", "sir"].contains(word.lowercased()) { continue }
            let k = key(word)
            if seen.insert(k).inserted { out.append(word) }
        }
        return out
    }

    /// The text cut into pieces of at most `size` characters, at paragraph (else line, else word)
    /// breaks, for a model with a small context window.
    public static func chunks(_ text: String, size: Int = 6000) -> [String] {
        guard text.count > size else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var rest = Substring(text)
        while rest.count > size {
            let window = rest.prefix(size)
            let cut = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: "\n", options: .backwards)?.upperBound
                ?? window.range(of: " ", options: .backwards)?.upperBound
                ?? window.endIndex
            let piece = rest[..<cut]
            out.append(String(piece))
            rest = rest[cut...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    // MARK: Swapping

    /// What a swap did.
    public struct Swap: Equatable, Sendable {
        public var text: String
        /// Each pair used, in the order first met, and how many times.
        public var used: [(original: String, substitute: String, count: Int)]

        public static func == (a: Swap, b: Swap) -> Bool {
            a.text == b.text && a.used.map { "\($0.original)\u{0}\($0.substitute)\u{0}\($0.count)" }
                == b.used.map { "\($0.original)\u{0}\($0.substitute)\u{0}\($0.count)" }
        }
    }

    /// Every pair's original swapped for its substitute, in one pass: whole words only (a letter,
    /// digit or underscore on either side means it's part of another word), the longest first,
    /// case and accents set aside when matching, and the match's capitals kept (JOHN → PERSON1,
    /// john → person1). "John's" becomes "Person1's".
    public static func apply(_ text: String, pairs: [(original: String, substitute: String)]) -> Swap {
        var table: [String: (original: String, substitute: String)] = [:]
        for p in pairs {
            let k = key(p.original)
            if !k.isEmpty, table[k] == nil { table[k] = p }
        }
        guard !table.isEmpty, !text.isEmpty else { return Swap(text: text, used: []) }
        let alternatives = table.values.map(\.original).sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return Swap(text: text, used: [])
        }
        let ns = text as NSString
        var out = ""
        var last = 0
        var counts: [String: Int] = [:]
        var order: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: m.range)
            guard let pair = table[key(found)] else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += matchCase(pair.substitute, like: found)
            last = m.range.location + m.range.length
            let k = key(pair.original)
            if counts[k] == nil { order.append(k) }
            counts[k, default: 0] += 1
        }
        out += ns.substring(from: last)
        let used = order.compactMap { k in table[k].map { ($0.original, $0.substitute, counts[k] ?? 0) } }
        return Swap(text: out, used: used)
    }

    /// The map swapped the other way: each substitute back to its original (the first original,
    /// when several share it).
    public static func restore(_ text: String, map: RedactionMap) -> Swap {
        var back: [(original: String, substitute: String)] = []
        var seen = Set<String>()
        for p in map.pairs where seen.insert(key(p.substitute)).inserted {
            back.append((p.substitute, p.original))
        }
        return apply(text, pairs: back)
    }

    /// `word` written with `found`'s capitals: all caps, all lower, or as it is.
    static func matchCase(_ word: String, like found: String) -> String {
        let letters = found.filter(\.isLetter)
        guard letters.count > 1 else { return word }
        if letters == letters.uppercased() && letters != letters.lowercased() { return word.uppercased() }
        if letters == letters.lowercased() && letters != letters.uppercased() { return word.lowercased() }
        return word
    }

    // MARK: The critical check

    /// The critical words still in `text`, anywhere (not only as whole words: inside a hyphenated
    /// name, an email address, a handle), case and accents set aside. The substitutes in the text
    /// are set aside first, so a stand-in that contains a name ("Annabel" for "Ann") isn't counted.
    public static func leaks(in text: String, map: RedactionMap) -> [String] {
        let critical = map.critical
        guard !critical.isEmpty, !text.isEmpty else { return [] }
        var folded = key(text)
        for sub in Set(map.pairs.map { key($0.substitute) }).sorted(by: { $0.count > $1.count }) where !sub.isEmpty {
            folded = folded.replacingOccurrences(of: sub, with: " ")
        }
        var out: [String] = []
        var seen = Set<String>()
        for e in critical {
            let k = key(e.original)
            if !k.isEmpty, folded.contains(k), seen.insert(k).inserted { out.append(e.original) }
        }
        return out
    }

    // MARK: Front matter

    /// The redacted text with the substitutions it used at the top, as YAML front matter.
    public static func withFrontMatter(_ result: Swap, at date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        var lines = ["---", "redacted: \(f.string(from: date))", "substitutions:"]
        if result.used.isEmpty {
            lines[lines.count - 1] = "substitutions: {}"
        }
        for u in result.used {
            lines.append("  \(yaml(u.original)): \(yaml(u.substitute))")
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + result.text
    }

    /// A YAML string in double quotes.
    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
