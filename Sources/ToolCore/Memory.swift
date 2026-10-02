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

    /// Takes a fact out: the "- fact" line that says it (case and spacing don't matter, nor the
    /// date). When no line says exactly that, a single line that contains it goes instead. Returns
    /// the facts removed (as written), none if nothing matched or it was ambiguous.
    @discardableResult
    public func forget(_ fact: String) throws -> [String] {
        let key = Self.normalized(fact)
        if key.isEmpty { return [] }
        let lines = read().components(separatedBy: "\n")
        var exact: [Int] = [], partial: [Int] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("- ") {
            let have = Self.fact(of: line)
            let known = Self.normalized(have)
            if known == key {
                exact.append(i)
            } else if known.contains(key) || (known.count > 8 && key.contains(known)) {
                partial.append(i)
            }
        }
        let drop = !exact.isEmpty ? exact : partial.count == 1 ? partial : []
        if drop.isEmpty { return [] }
        let removed = drop.map { Self.fact(of: lines[$0]) }
        let kept = lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        try write(kept.joined(separator: "\n"))
        return removed
    }

    /// "- Likes tea _(2026-09-30)_" → "Likes tea".
    static func fact(of line: String) -> String {
        var fact = String(line.dropFirst(2))
        if let r = fact.range(of: #"\s*_\(\d{4}-\d{2}-\d{2}\)_\s*$"#, options: .regularExpression) {
            fact.removeSubrange(r)
        }
        return fact.trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased, spaces squeezed, a final full stop dropped.
    static func normalized(_ text: String) -> String {
        var s = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        while s.hasSuffix(".") { s.removeLast() }
        return s
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

    /// The memory prompt everyone starts with: how the model uses the memory and keeps it up to
    /// date. `{{memory}}` is where MEMORY.md goes.
    public static let defaultInstruction = """
        You have a long-term memory: a Markdown file the user can read and edit, kept across all your \
        conversations. Here it is:

        <memory>
        {{memory}}
        </memory>

        Use it. Treat what's in it as things you already know about the user, and let it shape your answers \
        (their name, where they are, what they're working on, how they like replies) without announcing that \
        you remembered. Never invent memories.

        Keep it up to date, with tags anywhere in your reply (they're hidden from the user):
        - [[remember: one short, self-contained sentence]] when the user asks you to remember something, or \
        tells you a lasting fact worth keeping: who they are, people and pets in their life, where they live \
        and work, ongoing projects, preferences, how they like you to answer.
        - [[forget: the fact as it's written in memory]] when something in memory is wrong, outdated or the \
        user asks you to forget it. To correct a fact, forget the old one and remember the new one.
        Don't save small talk, one-off details, secrets (passwords, keys, card numbers) or anything already \
        in memory. Don't mention the tags.
        """

    /// The part of the system message about memory: `instruction` with the memory in place of
    /// `{{memory}}` (or after it, if it has no placeholder). Only the last 6000 characters of the
    /// memory go, so a huge file can't crowd out the conversation.
    public static func prompt(memory: String, instruction: String = defaultInstruction) -> String {
        let body = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = body.isEmpty ? "(empty)" : String(body.suffix(maxPromptCharacters))
        if instruction.contains(placeholder) {
            return instruction.replacingOccurrences(of: placeholder, with: shown)
        }
        return instruction.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\nYour memory:\n\n" + shown
    }

    public static let placeholder = "{{memory}}"

    /// How much of the memory goes with each message.
    public static let maxPromptCharacters = 6000

    static let tag = try! NSRegularExpression(pattern: #"\[\[\s*(remember|forget)\s*:\s*(.+?)\s*\]\]"#,
                                              options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// The finished reply without its [[remember: …]] tags, and the facts it suggested.
    public static func extract(_ reply: String) -> (shown: String, facts: [String]) {
        let all = extractAll(reply)
        return (all.shown, all.remember)
    }

    /// The finished reply without its [[remember: …]] and [[forget: …]] tags, the facts to add and
    /// the facts to drop. Tags inside code (``` blocks or `spans`) are left alone, and so is any
    /// other [[…]], like Bash's [[ -f x ]].
    public static func extractAll(_ reply: String) -> (shown: String, remember: [String], forget: [String]) {
        var remember: [String] = [], forget: [String] = []
        for part in parts(reply) where !part.code {
            let ns = part.text as NSString
            for m in tag.matches(in: part.text, range: NSRange(location: 0, length: ns.length)) {
                let fact = ns.substring(with: m.range(at: 2))
                if ns.substring(with: m.range(at: 1)).lowercased() == "forget" {
                    forget.append(fact)
                } else {
                    remember.append(fact)
                }
            }
        }
        return (hideTags(reply, streaming: false).trimmingCharacters(in: .whitespacesAndNewlines), remember, forget)
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

    /// Cuts a trailing "[", "[[", "[[ rem…" or "[[remember: half a fact" (no "]]" yet), and the
    /// same for "[[forget: …".
    static func holdBackUnfinishedTag(_ s: String) -> String {
        if let open = s.range(of: "[[", options: .backwards), s[open.upperBound...].range(of: "]]") == nil {
            let rest = s[open.upperBound...].drop(while: \.isWhitespace).lowercased()
            for key in ["remember", "forget"] where key.hasPrefix(rest) || rest.hasPrefix(key) {
                return String(s[..<open.lowerBound])
            }
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
    /// The tools an assistant turn asked to run.
    public var toolCalls: [ToolCall]?
    /// On a "tool" turn: which tool this is the result of.
    public var toolName: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolName = "tool_name"
    }

    public init(role: String, content: String, toolCalls: [ToolCall]? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolName = toolName
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
        // Don't open with the model's words (or a tool's result): start at a user turn.
        while kept.count > 1, kept.last?.role != "user" { kept.removeLast() }
        return kept.reversed()
    }
}

/// One line of Ollama's streamed /api/chat answer.
public struct OllamaChunk: Decodable, Equatable {
    public struct Message: Decodable, Equatable {
        public var content: String
        /// The tools the model wants run (they can come before, after or instead of text).
        public var toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
            toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        }
    }
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

/// A reply split into prose and ``` code blocks, for showing it (code gets its own box).
public enum ReplyBlock: Equatable {
    case text(String)
    /// `language` is what follows the opening ``` ("" if nothing). A block still streaming in
    /// (no closing ``` yet) is shown as code already.
    case code(language: String, body: String)

    public static func split(_ text: String) -> [ReplyBlock] {
        var out: [ReplyBlock] = []
        var prose: [Substring] = []
        var code: [Substring]?
        var language = ""
        func flushProse() {
            let t = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(.text(t)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let body = code {
                if trimmed.hasPrefix("```") {
                    out.append(.code(language: language, body: body.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(line)
                }
            } else if trimmed.hasPrefix("```") {
                flushProse()
                language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = []
            } else {
                prose.append(line)
            }
        }
        if let body = code { out.append(.code(language: language, body: body.joined(separator: "\n"))) }
        flushProse()
        return out
    }
}
