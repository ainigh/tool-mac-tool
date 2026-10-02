import Foundation

/// The diagram tool: you say what you want, the model answers with Mermaid, and the app draws it
/// (as a network diagram, in the app's own look, when it's a graph). Each request carries the
/// diagram as it stands, and only the last exchange is kept, so the model always works from the
/// current picture rather than a long history.
public enum Diagram {
    public static let system = """
        You draw diagrams with Mermaid. Every reply is exactly one Mermaid diagram in a single ```mermaid code \
        block and nothing else: no explanation before or after it.

        - You're given the current diagram (it may be empty) and the user's request. Change the current diagram \
        as asked and return the whole new diagram, keeping everything the user didn't ask to change. When the \
        request is about something new, start a fresh diagram.
        - The app draws your Mermaid as a network: every node becomes a large icon picked from its label, with \
        the label under it, and the app lays it out and colors it itself. So:
        - Use a flowchart for almost everything: systems, architectures, processes, plans, ideas and how things \
        relate. Use a mindmap to break a topic down; stateDiagram-v2, classDiagram, erDiagram, sequenceDiagram \
        or timeline only when the request is about states, classes, a data model, messages between parties or \
        dates. Use gantt, pie, journey, quadrantChart, xychart or gitGraph only when asked for exactly that.
        - Give every node a short, concrete label (1 to 4 words) that names the real thing: products, services, \
        tools and languages by their names (PostgreSQL, Stripe, AWS Lambda, React, Slack), people and roles \
        plainly (Customer, Designer). The icons are picked from these words.
        - To put a short description under a node, add it after <br>: db["PostgreSQL<br>orders and users"].
        - Group related nodes in subgraphs with a title (subgraph data [Data layer] ... end). Label a \
        connection only when the label adds something, in 1 to 3 words.
        - Write valid Mermaid (version 11): simple node ids (letters, digits, underscores), labels in double \
        quotes when they contain punctuation, no HTML but <br>, no Markdown inside labels, no %%{init}%% \
        directives, and no styling (classDef, style, linkStyle): the app styles the diagram.
        - Keep it readable: about 5 to 30 nodes.
        """

    /// The user's message for one request: the diagram as it stands, then what they asked.
    public static func request(_ message: String, current: String) -> String {
        let code = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            Current diagram:
            ```mermaid
            \(code.isEmpty ? "%% empty: nothing drawn yet" : code)
            ```

            Request: \(message.trimmingCharacters(in: .whitespacesAndNewlines))
            """
    }

    /// Asked when a reply wouldn't draw: the error, so the model can fix its own diagram.
    public static func repair(_ error: String) -> String {
        "That diagram didn't draw. The problem:\(error.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
            + "Fix it and reply with the whole corrected diagram in one ```mermaid block."
    }

    /// The words a Mermaid diagram can start with.
    static let starts = ["flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram", "erDiagram",
                         "gantt", "pie", "mindmap", "timeline", "journey", "gitGraph", "quadrantChart",
                         "xychart", "sankey", "block", "requirementDiagram", "C4Context", "C4Container",
                         "C4Component", "C4Dynamic", "C4Deployment", "architecture", "packet", "kanban", "radar"]

    /// The Mermaid in a reply: its ```mermaid block, else its first ``` block, else the reply
    /// from the first line that starts a diagram. A reasoning model's <think>…</think> is skipped.
    /// Nil when there's none.
    public static func extract(_ reply: String) -> String? {
        var text = reply
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let blocks = ReplyBlock.split(text).compactMap { block -> (String, String)? in
            if case .code(let language, let body) = block { return (language.lowercased(), body) }
            return nil
        }
        if let m = blocks.first(where: { $0.0 == "mermaid" }) ?? blocks.first(where: { startsDiagram($0.1) }) {
            return clean(m.1)
        }
        let lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { startsDiagram($0) }) {
            return clean(lines[i...].joined(separator: "\n"))
        }
        return nil
    }

    static func startsDiagram(_ text: String) -> Bool {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("%%") } ?? ""
        let word = first.trimmingCharacters(in: .whitespaces).prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return starts.contains { word == $0 || word.hasPrefix($0 + "-") }
    }

    static func clean(_ code: String) -> String? {
        let s = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// The Swift on this Mac, as `swift --version` reports it. FluidAudio (the voices) needs Swift 6, so
/// building here with an older one fails while resolving packages ("incompatible tools version").
public struct SwiftToolchain: Equatable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// The oldest Swift that builds the app.
    public static let required = SwiftToolchain(major: 6, minor: 0)

    /// From "Apple Swift version 5.10 (swiftlang-…)" or "Swift version 6.1 (swift-6.1-RELEASE)".
    public static func parse(_ output: String) -> SwiftToolchain? {
        guard let r = output.range(of: #"Swift version (\d+)\.(\d+)"#, options: .regularExpression) else { return nil }
        let numbers = output[r].dropFirst("Swift version ".count).split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
        guard numbers.count >= 2 else { return nil }
        return SwiftToolchain(major: numbers[0], minor: numbers[1])
    }

    public var isNewEnough: Bool { (major, minor) >= (Self.required.major, Self.required.minor) }
    public var description: String { "\(major).\(minor)" }
}
