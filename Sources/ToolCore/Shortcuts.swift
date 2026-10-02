import Foundation

/// One of your Apple Shortcuts, offered to the model as a tool. Each takes a string and returns
/// a string (or nothing, when it's one way). The description says when the model should call it.
public struct ShortcutTool: Codable, Equatable, Identifiable {
    public var id: String
    /// The shortcut's name, as the Shortcuts app shows it.
    public var shortcut: String
    /// When to call it, in your words: what the model reads to decide.
    public var description: String
    /// What to pass it (the one string it takes).
    public var input: String
    /// It hands back text; otherwise it's one way and the model is just told it ran.
    public var returnsText: Bool
    /// Ask before each run.
    public var confirm: Bool
    public var enabled: Bool

    public init(id: String = UUID().uuidString, shortcut: String, description: String = "", input: String = "",
                returnsText: Bool = true, confirm: Bool = false, enabled: Bool = true) {
        self.id = id
        self.shortcut = shortcut
        self.description = description
        self.input = input
        self.returnsText = returnsText
        self.confirm = confirm
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, shortcut, description, input, returnsText, confirm, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        returnsText = try c.decodeIfPresent(Bool.self, forKey: .returnsText) ?? true
        confirm = try c.decodeIfPresent(Bool.self, forKey: .confirm) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// "Get Weather (UK)" → "get_weather_uk": a name a model can call.
    public static func functionName(_ shortcut: String) -> String {
        var out = ""
        var gap = false
        for ch in shortcut.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII {
                if gap && !out.isEmpty { out += "_" }
                out.unicodeScalars.append(ch)
                gap = false
            } else {
                gap = true
            }
        }
        if out.isEmpty { out = "shortcut" }
        if let first = out.first, first.isNumber { out = "run_" + out }
        return String(out.prefix(60))
    }

    /// The enabled tools by the name the model calls them (a second "get_weather" becomes
    /// "get_weather_2"), in order.
    public static func callable(_ tools: [ShortcutTool]) -> [(name: String, tool: ShortcutTool)] {
        var used = Set<String>()
        var out: [(String, ShortcutTool)] = []
        for t in tools where t.enabled && !t.shortcut.isEmpty {
            let base = functionName(t.shortcut)
            var name = base
            var n = 2
            while used.contains(name) { name = "\(base)_\(n)"; n += 1 }
            used.insert(name)
            out.append((name, t))
        }
        return out
    }

    /// The tool as Ollama's /api/chat takes it.
    public func spec(name: String) -> OllamaTool {
        var about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if about.isEmpty { about = "Runs the user's \"\(shortcut)\" shortcut." }
        if !returnsText { about += " It returns nothing: you're only told that it ran." }
        let hint = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return OllamaTool(function: .init(
            name: name, description: about,
            parameters: .init(properties: ["input": .init(type: "string",
                                                          description: hint.isEmpty ? "The text to give the shortcut." : hint)],
                              required: ["input"])))
    }

    /// The string to pass, from a call's arguments: "input", else the only argument there is.
    public static func input(from call: ToolCall) -> String {
        let args = call.function.arguments
        return args["input"] ?? (args.count == 1 ? args.values.first! : "")
    }
}

/// A tool definition as Ollama's /api/chat takes it.
public struct OllamaTool: Encodable, Equatable {
    public struct Function: Encodable, Equatable {
        public var name: String
        public var description: String
        public var parameters: Parameters
    }

    public struct Parameters: Encodable, Equatable {
        public struct Property: Encodable, Equatable {
            public var type: String
            public var description: String
        }
        public var type = "object"
        public var properties: [String: Property]
        public var required: [String]

        public init(properties: [String: Property], required: [String]) {
            self.properties = properties
            self.required = required
        }
    }

    public var type = "function"
    public var function: Function

    public init(function: Function) { self.function = function }
}

/// A tool the model asked to run, as Ollama hands it over (and as it's sent back in the history).
/// Arguments that aren't strings (numbers, true/false) are kept as their text.
public struct ToolCall: Codable, Equatable {
    public struct Function: Codable, Equatable {
        public var name: String
        public var arguments: [String: String]

        public init(name: String, arguments: [String: String]) {
            self.name = name
            self.arguments = arguments
        }

        enum CodingKeys: String, CodingKey { case name, arguments }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            if let object = try? c.decode([String: Loose].self, forKey: .arguments) {
                arguments = object.mapValues(\.text)
            } else if let text = try? c.decode(String.self, forKey: .arguments),
                      let object = try? JSONDecoder().decode([String: Loose].self, from: Data(text.utf8)) {
                arguments = object.mapValues(\.text)
            } else {
                arguments = [:]
            }
        }
    }

    /// Any JSON value, as text.
    struct Loose: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { text = s }
            else if let i = try? c.decode(Int.self) { text = String(i) }
            else if let d = try? c.decode(Double.self) { text = String(d) }
            else if let b = try? c.decode(Bool.self) { text = String(b) }
            else { text = "" }
        }
    }

    public var function: Function

    public init(name: String, arguments: [String: String]) {
        function = Function(name: name, arguments: arguments)
    }
}
