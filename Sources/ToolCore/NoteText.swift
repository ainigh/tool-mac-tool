import Foundation

// How a note's text is laid out, line by line: its first line is its title (the biggest), its
// second halfway between that and the rest, a rule under the second when there's a third, and a
// line starting "- " (a point under the line above) a little smaller than the nearest line above
// it that isn't one. And what's added to the end of a note (what was said into it, or written
// down from a sound file dropped on it).

public enum NoteText {
    /// How much smaller a "- " line is than the line it's under.
    public static let pointScale = 0.88

    /// A line starting "- " (spaces before it are fine: a point under a point).
    public static func isPoint(_ line: String) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.hasPrefix("- ")
    }

    /// Each line's size, as a multiple of the note's: the first `titleScale`, the second halfway
    /// between that and 1, the rest 1; a "- " line (but the first) `pointScale` of the nearest line
    /// above it that isn't one.
    public static func scales(_ lines: [String], titleScale: Double) -> [Double] {
        var out: [Double] = []
        var above = titleScale
        for (i, line) in lines.enumerated() {
            let own = i == 0 ? titleScale : i == 1 ? (1 + titleScale) / 2 : 1
            if i > 0, isPoint(line) {
                out.append(above * pointScale)
            } else {
                out.append(own)
                above = own
            }
        }
        return out
    }

    /// The lines of a text, split at its line breaks (an empty text is one empty line).
    public static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// A rule goes under the second line: there's a third.
    public static func hasRule(_ text: String) -> Bool {
        lines(text).count >= 3
    }

    /// `addition` at the end of `text`, on a line of its own (nothing added when it's blank).
    public static func appending(_ addition: String, to text: String) -> String {
        let added = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !added.isEmpty else { return text }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return added }
        return text.hasSuffix("\n") ? text + added : text + "\n" + added
    }
}
