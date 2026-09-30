import Foundation

/// The long-term memory: one Markdown file, the same one Glass uses (<Glass folder>/MEMORY/MEMORY.md),
/// so both remember the same things. Its whole text goes to the model with every message; the model
/// adds a line by writing [[remember: the fact]] in its reply (hidden from you).
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

            \(body.isEmpty ? "(empty)" : String(body.suffix(6000)))

            When the user asks you to remember something, or tells you a lasting fact about themselves \
            that is worth keeping, add it by putting [[remember: the fact]] anywhere in your reply \
            (one short sentence; it is hidden from the user). Don't repeat facts already in memory.
            """
    }

    /// The reply without its [[...]] tags, and the facts it asked to remember.
    public static func extract(_ reply: String) -> (shown: String, facts: [String]) {
        var facts: [String] = []
        let re = try! NSRegularExpression(pattern: #"\[\[\s*remember\s*:\s*(.+?)\s*\]\]"#,
                                          options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = reply as NSString
        for m in re.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            facts.append(ns.substring(with: m.range(at: 1)))
        }
        return (hideTags(reply).trimmingCharacters(in: .whitespacesAndNewlines), facts)
    }

    /// For showing a reply while it streams in: complete [[...]] tags removed, and an unfinished
    /// one at the end held back until it's done.
    public static func hideTags(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
        if let open = s.range(of: "[[", options: .backwards), s[open.upperBound...].range(of: "]]") == nil {
            s = String(s[..<open.lowerBound])
        } else if s.hasSuffix("[") {
            s.removeLast()
        }
        return s.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
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
            h.seekToEndOfFile()
            h.write(Data(block.utf8))
        } else {
            try Data(block.utf8).write(to: url)
        }
    }
}
