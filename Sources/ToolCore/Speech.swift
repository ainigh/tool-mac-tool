import Foundation

/// A reply as it should be heard rather than read: no code, no Markdown marks, link text without
/// its address, one line per thought.
public enum SpokenText {
    public static func clean(_ text: String) -> String {
        var lines: [String] = []
        for block in ReplyBlock.split(text) {
            guard case .text(let prose) = block else { continue }   // code is for reading
            for line in prose.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(cleanLine(String(line)))
            }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanLine(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }
        // A rule (---, ***, ___) says nothing.
        if s.count >= 3, Set(s.filter { !$0.isWhitespace }).count == 1, "-*_".contains(s.first!) { return "" }
        s = dropPrefix(s, pattern: #"^#{1,6}\s+"#)            // headings
        s = dropPrefix(s, pattern: #"^(>\s*)+"#)              // quotes
        s = dropPrefix(s, pattern: #"^([-*+]|\d{1,3}[.)])\s+"#) // list items
        s = dropPrefix(s, pattern: #"^\[[ xX]\]\s+"#)         // tasks
        s = replace(s, #"!?\[([^\]]*)\]\([^)]*\)"#, "$1")     // [text](url) -> text
        s = replace(s, #"https?://\S+"#, "a link")
        s = replace(s, #"(\*\*|__)(.+?)\1"#, "$2")             // bold
        s = replace(s, #"(?<![\w*])[*_](?!\s)(.+?)(?<!\s)[*_](?![\w*])"#, "$1") // italics
        s = replace(s, #"~~(.+?)~~"#, "$1")
        s = s.replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func dropPrefix(_ s: String, pattern: String) -> String {
        replace(s, pattern, "")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// Splits cleaned text into sentences: at . ! ? … followed by a space (not after a short
    /// abbreviation like "e.g." or "Dr."), and at every line break.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n") {
            var current = ""
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                current.append(c)
                if ".!?…".contains(c) {
                    // Closing quotes and brackets belong to the sentence.
                    while i + 1 < chars.count, "\"'”’)]".contains(chars[i + 1]) {
                        i += 1
                        current.append(chars[i])
                    }
                    let atEnd = i + 1 >= chars.count
                    let spaceNext = !atEnd && chars[i + 1].isWhitespace
                    if (spaceNext || atEnd) && !(c == "." && endsWithAbbreviation(current)) {
                        push(&out, current)
                        current = ""
                    }
                }
                i += 1
            }
            push(&out, current)
        }
        return out
    }

    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "etc.", "vs.", "mr.", "mrs.", "ms.", "dr.",
                                                     "st.", "no.", "approx.", "fig.", "p.m.", "a.m."]

    private static func endsWithAbbreviation(_ s: String) -> Bool {
        guard let last = s.split(whereSeparator: \.isWhitespace).last?.lowercased() else { return false }
        let word = last.trimmingCharacters(in: CharacterSet(charactersIn: "(\"'"))
        if abbreviations.contains(word) { return true }
        // A single capital and a dot ("J. Smith") is an initial.
        return word.count == 2 && word.first!.isLetter
    }

    private static func push(_ out: inout [String], _ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(where: { $0.isLetter || $0.isNumber }) { out.append(t) }
    }
}

/// Feeds a reply to the voice a sentence at a time while it streams in, so speaking starts with
/// the first sentence instead of after the whole reply. Give it the reply so far each time it
/// grows; it hands back the sentences that are now complete and haven't been given out yet.
public struct SentenceStream {
    private var given = 0

    public init() {}

    /// The sentences finished in `reply` (the whole reply so far) since the last call. The last
    /// sentence is held back, since more of it may still be coming, unless code follows it.
    public mutating func update(_ reply: String) -> [String] {
        let all = SpokenText.sentences(SpokenText.clean(reply))
        // A code block ends the sentence before it; otherwise more of the last one may come.
        var endsInCode = false
        if case .code = ReplyBlock.split(reply).last { endsInCode = true }
        let ready = endsInCode ? all.count : all.count - 1
        guard ready > given else { return [] }
        defer { given = ready }
        return Array(all[given..<ready])
    }

    /// The reply is complete: everything not given out yet.
    public mutating func finish(_ reply: String) -> [String] {
        let all = SpokenText.sentences(SpokenText.clean(reply))
        guard all.count > given else { return [] }
        defer { given = all.count }
        return Array(all[given...])
    }
}

/// A piece of a transcript: what was said, and when (seconds from the start).
public struct TimedText: Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Transcripts as files: plain text, SubRip (.srt) and WebVTT (.vtt) subtitles.
public enum Captions {
    public static func plain(_ segments: [TimedText]) -> String {
        segments.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func srt(_ segments: [TimedText]) -> String {
        segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start, comma: true)) --> \(stamp(s.end, comma: true))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ segments: [TimedText]) -> String {
        "WEBVTT\n\n" + segments.map { s in
            "\(stamp(s.start, comma: false)) --> \(stamp(s.end, comma: false))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    /// 01:02:03,456 (SRT) or 01:02:03.456 (VTT).
    public static func stamp(_ seconds: Double, comma: Bool) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, comma ? "," : ".", f)
    }

    /// 0:42, 12:05, 1:02:03: a time for people to read.
    public static func clock(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Where to cut long audio into pieces a recognizer takes one at a time: at the quietest moment
/// near the end of each piece, so a word is rarely cut in half.
public enum QuietCut {
    /// `levels` is the loudness of consecutive short frames of one piece; the cut is the quietest
    /// frame at or after `from` (the last one if several are equally quiet, so pieces stay long).
    /// With nothing to search, the piece is kept whole.
    public static func cut(levels: [Float], from: Int) -> Int {
        let start = max(0, min(from, levels.count))
        guard start < levels.count else { return levels.count }
        var best = start
        for i in start..<levels.count where levels[i] <= levels[best] { best = i }
        return best
    }
}

/// Dictated notes, kept the way Glass keeps them: one glass-dictation-<date>.md a day in the Glass
/// folder, a dated heading and one block per note, so Glass's transcript view shows them too.
public enum Dictation {
    public static func fileName(for date: Date) -> String {
        "glass-dictation-\(format(date, "yyyy-MM-dd")).md"
    }

    public static func title(for date: Date) -> String {
        "Dictation, \(format(date, "EEEE d MMMM yyyy"))"
    }

    /// Adds a note to the day's file (making it, with its heading, if it's the first) and returns
    /// where it went.
    @discardableResult
    public static func append(_ note: String, folder: URL, at date: Date = Date()) throws -> URL {
        let url = folder.appendingPathComponent(fileName(for: date))
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = Transcript.block(who: "you (dictation)", text: note, at: date)
        if !fm.fileExists(atPath: url.path) { text = "# \(title(for: date))\n\n" + text }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
