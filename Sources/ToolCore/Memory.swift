import Foundation

/// The long-term memory: one Markdown file, the same one Glass uses (<Glass folder>/MEMORY/MEMORY.md),
/// so both remember the same things. Its text goes to the model with every message; the model
/// suggests a line by writing [[remember: the fact]] in its reply (hidden from you), and it's added
/// once you say yes.
public struct MemoryStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static let template = """
        # Memory

        What Glass remembers across conversations. Edit it freely: it's read at the start of every reply.
        Glass adds a line here when you ask it to remember something.


        """

    // MARK: - Where it is

    /// Glass's settings (~/.config/glass/config.json): its folder, Ollama's address, the model.
    public struct GlassConfig: Decodable {
        public var folder: String?
        public var ollama: String?
        public var model: String?

        public static func load(home: URL) -> GlassConfig {
            let url = home.appendingPathComponent(".config/glass/config.json")
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(GlassConfig.self, from: data) else { return GlassConfig() }
            return config
        }

        public init(folder: String? = nil, ollama: String? = nil, model: String? = nil) {
            self.folder = folder
            self.ollama = ollama
            self.model = model
        }
    }

    /// The Glass folder: its setting, else ~/Documents/Glass.
    public static func glassFolder(home: URL, config: GlassConfig) -> URL {
        if let f = config.folder, !f.isEmpty {
            let path = f.hasPrefix("~") ? home.path + f.dropFirst() : f
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent("Documents/Glass")
    }

    public static func forCurrentUser() -> MemoryStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = glassFolder(home: home, config: .load(home: home))
        return MemoryStore(url: folder.appendingPathComponent("MEMORY/MEMORY.md"))
    }

    // MARK: - Reading and writing

    /// Creates the file (with a short header) if it isn't there yet.
    public func ensure() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.template.utf8).write(to: url)
    }

    public func read() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Replaces the whole text (atomically, so Glass never reads half a file).
    public func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Adds "- fact _(date)_" at the end. Returns the line, or nil if it's empty or already there.
    @discardableResult
    public func remember(_ fact: String, today: Date = Date()) throws -> String? {
        let fact = fact.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if fact.isEmpty { return nil }
        try ensure()
        let text = read()
        if Self.facts(in: text).contains(fact.lowercased()) { return nil }
        let day = Self.day.string(from: today)
        let line = "- \(fact) _(\(day))_\n"
        try write(text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + line)
        return line
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The facts already listed ("- fact _(date)_" lines), lowercased.
    public static func facts(in text: String) -> Set<String> {
        var out = Set<String>()
        for line in text.components(separatedBy: "\n") where line.hasPrefix("- ") {
            var fact = String(line.dropFirst(2))
            if let r = fact.range(of: #"\s*_\(\d{4}-\d{2}-\d{2}\)_\s*$"#, options: .regularExpression) {
                fact.removeSubrange(r)
            }
            out.insert(fact.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased())
        }
        return out
    }

    /// A rough token count (4 characters a token), to show what the memory costs per message.
    public static func tokens(_ text: String) -> Int { (text.count + 3) / 4 }

    // MARK: - What the model is told

    /// The part of the system message about memory. Only the last 6000 characters go, so a huge
    /// file can't crowd out the conversation.
    public static func prompt(memory: String) -> String {
        let body = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            You have a long-term memory, kept in a file the user can read and edit. Here it is:

            \(body.isEmpty ? "(empty)" : String(body.suffix(maxPromptCharacters)))

            When the user asks you to remember something, or tells you a lasting fact about themselves \
            that is worth keeping, suggest adding it by putting [[remember: the fact]] anywhere in your reply \
            (one short sentence; the user is asked before it's kept). Don't repeat facts already in memory.
            """
    }

    /// How much of the memory goes with each message.
    public static let maxPromptCharacters = 6000

    static let tag = try! NSRegularExpression(pattern: #"\[\[\s*remember\s*:\s*(.+?)\s*\]\]"#,
                                              options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// The finished reply without its [[remember: …]] tags, and the facts it suggested. Tags inside
    /// code (``` blocks or `spans`) are left alone, and so is any other [[…]], like Bash's [[ -f x ]].
    public static func extract(_ reply: String) -> (shown: String, facts: [String]) {
        var facts: [String] = []
        for part in parts(reply) where !part.code {
            let ns = part.text as NSString
            for m in tag.matches(in: part.text, range: NSRange(location: 0, length: ns.length)) {
                facts.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return (hideTags(reply, streaming: false).trimmingCharacters(in: .whitespacesAndNewlines), facts)
    }

    /// The reply without its [[remember: …]] tags. While it streams in, a tag that has started but
    /// not finished yet ("[[remem") is held back too, so it never flashes on screen.
    public static func hideTags(_ text: String, streaming: Bool = true) -> String {
        let all = parts(text)
        var out = ""
        for (i, part) in all.enumerated() {
            if part.code { out += part.text; continue }
            let ns = part.text as NSString
            var s = tag.stringByReplacingMatches(in: part.text, range: NSRange(location: 0, length: ns.length),
                                                 withTemplate: "")
            if streaming && i == all.count - 1 { s = holdBackUnfinishedTag(s) }
            out += s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        }
        return out
    }

    /// Cuts a trailing "[", "[[", "[[ rem…" or "[[remember: half a fact" (no "]]" yet).
    static func holdBackUnfinishedTag(_ s: String) -> String {
        if let open = s.range(of: "[[", options: .backwards), s[open.upperBound...].range(of: "]]") == nil {
            let rest = s[open.upperBound...].drop(while: \.isWhitespace).lowercased()
            let key = "remember"
            if key.hasPrefix(rest) || rest.hasPrefix(key) { return String(s[..<open.lowerBound]) }
        }
        if s.hasSuffix("[") && !s.hasSuffix("[[") { return String(s.dropLast()) }
        return s
    }

    /// The text split into prose and code: ``` blocks (an unclosed one runs to the end) and
    /// `inline` spans on one line (a lone backtick is just a backtick).
    static func parts(_ text: String) -> [(code: Bool, text: String)] {
        var out: [(code: Bool, text: String)] = []
        var prose = ""
        var i = text.startIndex
        func flush() { if !prose.isEmpty { out.append((false, prose)); prose = "" } }
        while i < text.endIndex {
            let rest = text[i...]
            if rest.hasPrefix("```") {
                let after = text.index(i, offsetBy: 3)
                let end = text[after...].range(of: "```").map(\.upperBound) ?? text.endIndex
                flush()
                out.append((true, String(text[i..<end])))
                i = end
            } else if text[i] == "`",
                      let close = text[text.index(after: i)...].prefix(while: { $0 != "\n" }).firstIndex(of: "`") {
                flush()
                let end = text.index(after: close)
                out.append((true, String(text[i..<end])))
                i = end
            } else {
                prose.append(text[i])
                i = text.index(after: i)
            }
        }
        flush()
        return out
    }
}

/// One message in a conversation, as Ollama's /api/chat takes it.
public struct ChatTurn: Codable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    /// How many characters of conversation fit in a context of `contextTokens`, once the system
    /// message and room for the reply are taken out. It counts 3 characters a token (fewer than the
    /// usual 4), to stay safe with code and non-English text.
    public static func budget(contextTokens: Int, system: String, replyTokens: Int) -> Int {
        max(1000, (contextTokens - replyTokens) * 3 - system.count)
    }

    /// The newest turns that fit in `budget` characters (always at least the last one), so a long
    /// conversation doesn't overflow the model's context: the oldest turns drop off first.
    public static func window(_ turns: [ChatTurn], budget: Int) -> [ChatTurn] {
        var kept: [ChatTurn] = []
        var used = 0
        for t in turns.reversed() {
            if !kept.isEmpty && used + t.content.count > budget { break }
            kept.append(t)
            used += t.content.count
        }
        // Don't open with the model's words: start at a user turn.
        while kept.count > 1, kept.last?.role == "assistant" { kept.removeLast() }
        return kept.reversed()
    }
}

/// One line of Ollama's streamed /api/chat answer.
public struct OllamaChunk: Decodable, Equatable {
    public struct Message: Decodable, Equatable { public var content: String }
    public var message: Message?
    public var done: Bool
    public var error: String?
    /// Tokens read and written (on the last line).
    public var promptTokens: Int?
    public var outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case message, done, error
        case promptTokens = "prompt_eval_count"
        case outputTokens = "eval_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decodeIfPresent(Message.self, forKey: .message)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens)
    }

    public static func parse(_ line: String) -> OllamaChunk? {
        try? JSONDecoder().decode(OllamaChunk.self, from: Data(line.utf8))
    }
}

/// A conversation saved as Markdown in the Glass folder, in Glass's format, so it opens in
/// Glass's transcript view too.
public struct Transcript {
    public let url: URL

    public init(folder: URL, started: Date = Date()) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        url = folder.appendingPathComponent("glass-chat-\(f.string(from: started)).md")
    }

    /// "### 14:03:12 · who (note)\n\ntext\n\n"
    public static func block(who: String, text: String, note: String = "", at: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return "### \(f.string(from: at)) · \(who)\(note.isEmpty ? "" : " (\(note))")\n\n"
            + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
    }

    public func append(_ block: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(block.utf8))
        } else {
            try Data(block.utf8).write(to: url)
        }
    }
}
