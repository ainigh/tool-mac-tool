import Foundation

/// A reply's prose (the parts outside code blocks) split into the blocks the chat draws:
/// Markdown's headings, lists, quotes and rules, read line by line. The text inside each block
/// still holds inline Markdown (**bold**, `code`, links) for the view to apply.
public struct ProseBlock: Equatable {
    public enum Kind: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `depth` counts indents of two spaces (a tab counts as two), at most 3.
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, number: String, text: String)
        case task(depth: Int, done: Bool, text: String)
        case quote(String)
        case rule
    }

    public var kind: Kind
    /// Whether it starts a new group (a blank line before it, or a change from list to text),
    /// so the view puts more room above it.
    public var spaced: Bool

    public init(_ kind: Kind, spaced: Bool = false) {
        self.kind = kind
        self.spaced = spaced
    }

    var isListItem: Bool {
        switch kind {
        case .bullet, .numbered, .task: return true
        default: return false
        }
    }

    var isHeading: Bool {
        if case .heading = kind { return true }
        return false
    }

    public static func parse(_ prose: String) -> [ProseBlock] {
        var out: [ProseBlock] = []
        var blankBefore = false
        for raw in prose.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankBefore = true
                continue
            }
            let kind = Self.kind(of: line, trimmed: trimmed)
            // Lines of one paragraph (or one quote) with no blank between them stay together.
            if !blankBefore, let last = out.last {
                switch (last.kind, kind) {
                case (.paragraph(let a), .paragraph(let b)):
                    out[out.count - 1].kind = .paragraph(a + "\n" + b)
                    continue
                case (.quote(let a), .quote(let b)):
                    out[out.count - 1].kind = .quote(a + "\n" + b)
                    continue
                default: break
                }
            }
            var block = ProseBlock(kind)
            if let last = out.last {
                block.spaced = blankBefore || block.isHeading || last.isHeading
                    || last.isListItem != block.isListItem
                // A blank line between two items of one list doesn't split it.
                if blankBefore && last.isListItem && block.isListItem { block.spaced = false }
            }
            out.append(block)
            blankBefore = false
        }
        return out
    }

    static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)(\s+#+)?\s*$"#)
    static let rulePattern = try! NSRegularExpression(pattern: #"^([-*_])(\s*\1){2,}$"#)
    static let bulletPattern = try! NSRegularExpression(pattern: #"^( *)[-*+•]\s+(.*)$"#)
    static let numberedPattern = try! NSRegularExpression(pattern: #"^( *)(\d{1,4})[.)]\s+(.*)$"#)
    static let quotePattern = try! NSRegularExpression(pattern: #"^>\s?(.*)$"#)

    static func kind(of line: String, trimmed: String) -> Kind {
        if let g = groups(headingPattern, trimmed) {
            return .heading(level: g[1].count, text: g[2])
        }
        if groups(rulePattern, trimmed) != nil { return .rule }
        if let g = groups(bulletPattern, line) {
            let depth = min(g[1].count / 2, 3)
            let text = g[2]
            for (box, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(box) {
                return .task(depth: depth, done: done, text: String(text.dropFirst(box.count)))
            }
            return .bullet(depth: depth, text: text)
        }
        if let g = groups(numberedPattern, line) {
            return .numbered(depth: min(g[1].count / 2, 3), number: g[2], text: g[3])
        }
        if let g = groups(quotePattern, trimmed) { return .quote(g[1]) }
        return .paragraph(trimmed)
    }

    /// The pattern's capture groups (0 is the whole match; a group that didn't take part is ""),
    /// or nil if it doesn't match.
    static func groups(_ pattern: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}
