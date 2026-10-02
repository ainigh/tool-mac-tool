import Foundation

/// The tools built into the app that the chat's model can call: draw a diagram, sound an alarm,
/// open a link, copy text, close the window. All one way: the model is only told it was done.
/// Each can be turned off, and its description (when to call it) rewritten.
public struct BuiltinTool: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable {
        case drawDiagram = "draw_diagram"
        case soundAlarm = "sound_alarm"
        case openURL = "open_url"
        case copyText = "copy_to_clipboard"
        case closeWindow = "close_window"

        public var title: String {
            switch self {
            case .drawDiagram: return "Draw a diagram"
            case .soundAlarm: return "Sound an alarm"
            case .openURL: return "Open a link"
            case .copyText: return "Copy to the clipboard"
            case .closeWindow: return "Close the chat"
            }
        }

        public var symbol: String {
            switch self {
            case .drawDiagram: return "point.3.connected.trianglepath.dotted"
            case .soundAlarm: return "alarm"
            case .openURL: return "safari"
            case .copyText: return "doc.on.clipboard"
            case .closeWindow: return "xmark.circle"
            }
        }

        /// The one argument it takes: its name, JSON type and what to put in it.
        var argument: (name: String, type: String, about: String)? {
            switch self {
            case .drawDiagram:
                return ("description", "string", "What to draw, in detail: the things in it, how they connect, and the kind of diagram if it matters.")
            case .soundAlarm:
                return ("seconds", "integer", "How long the alarm sounds, in seconds (1 to 600).")
            case .openURL:
                return ("url", "string", "The full web address to open, starting with https://.")
            case .copyText:
                return ("text", "string", "Exactly the text to put on the clipboard.")
            case .closeWindow:
                return nil
            }
        }

        public var defaultDescription: String {
            switch self {
            case .drawDiagram:
                return "Shows the user a diagram in a large window on their screen (another model draws it from your "
                    + "description; you won't see it). Call it when the user asks to draw, sketch, map out, visualize or "
                    + "diagram something, or when a picture of a process, structure or plan would clearly help. After "
                    + "calling it, just say it's on screen."
            case .soundAlarm:
                return "Sounds an alarm on the Mac for a number of seconds. Call it when the user asks for an alarm, a "
                    + "loud alert or to be woken or alerted now. For an alarm later, explain that you can only sound it now."
            case .openURL:
                return "Opens a web page in the user's default browser so they can see it. Call it when the user asks to "
                    + "open, show or go to a website or link. Only open addresses the user gave or that you're sure of."
            case .copyText:
                return "Puts text on the user's clipboard so they can paste it anywhere. Call it when the user asks to "
                    + "copy something (a reply, a snippet, an address)."
            case .closeWindow:
                return "Closes this chat window. Call it when the user says they're done, says goodbye, or asks to "
                    + "close, exit, quit or hide the chat."
            }
        }
    }

    public var kind: Kind
    public var enabled: Bool
    /// When to call it: what the model reads to decide.
    public var description: String
    public var id: String { kind.rawValue }

    public init(kind: Kind, enabled: Bool = true, description: String? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.description = description ?? kind.defaultDescription
    }

    public static var defaults: [BuiltinTool] { Kind.allCases.map { BuiltinTool(kind: $0) } }

    /// The list with one of each kind, in order (a kind the file didn't have gets its default).
    public static func complete(_ list: [BuiltinTool]) -> [BuiltinTool] {
        Kind.allCases.map { kind in list.first { $0.kind == kind } ?? BuiltinTool(kind: kind) }
    }

    public var name: String { kind.rawValue }

    public func spec() -> OllamaTool {
        var about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if about.isEmpty { about = kind.defaultDescription }
        var properties: [String: OllamaTool.Parameters.Property] = [:]
        var required: [String] = []
        if let arg = kind.argument {
            properties[arg.name] = .init(type: arg.type, description: arg.about)
            required = [arg.name]
        }
        return OllamaTool(function: .init(name: name, description: about,
                                          parameters: .init(properties: properties, required: required)))
    }

    /// The argument a call gave (by its name, else the only one there is).
    public static func argument(_ call: ToolCall, _ kind: Kind) -> String {
        let args = call.function.arguments
        if let name = kind.argument?.name, let v = args[name] { return v }
        return args.count == 1 ? args.values.first! : ""
    }

    /// Seconds for the alarm: what was asked, kept between 1 and 600 (10 when it can't be read).
    public static func seconds(_ text: String) -> Int {
        let digits = text.trimmingCharacters(in: .whitespaces)
        let value = Int(digits) ?? Double(digits).map { Int($0.rounded()) } ?? 10
        return min(600, max(1, value))
    }

    /// A web address to open: http or https only ("example.com" becomes https://example.com).
    public static func webURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
        if s.isEmpty || s.contains(" ") { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }
}

/// Short things said to the window itself, recognised without asking the model.
public enum VoiceCommand: Equatable {
    case close

    static let fillers: Set<String> = ["please", "ok", "okay", "now", "hey", "glass", "the", "this", "that", "thanks",
                                       "thank", "you", "just", "it", "window", "chat", "app", "and", "so", "um", "uh"]
    static let closers: Set<String> = ["close", "exit", "quit", "dismiss", "hide", "bye", "goodbye", "byebye"]

    /// "Close.", "Exit please", "Close the window", "OK, bye", "Go away": a close. Anything with
    /// more to it ("close the door when you leave") isn't.
    public static func parse(_ said: String) -> VoiceCommand? {
        let words = said.lowercased()
            .replacingOccurrences(of: "good bye", with: "goodbye")
            .replacingOccurrences(of: "bye bye", with: "byebye")
            .replacingOccurrences(of: "go away", with: "dismiss")
            .replacingOccurrences(of: "shut down", with: "close")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let rest = words.filter { !fillers.contains($0) }
        guard !rest.isEmpty, rest.allSatisfy({ closers.contains($0) }) else { return nil }
        return .close
    }
}

/// A short description of this Mac and how long it's been on, for the system message.
public enum MacInfo {
    /// "3 days, 4 hours", "2 hours, 5 minutes", "12 minutes".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if d > 0 { return h > 0 ? "\(unit(d, "day")), \(unit(h, "hour"))" : unit(d, "day") }
        if h > 0 { return m > 0 ? "\(unit(h, "hour")), \(unit(m, "minute"))" : unit(h, "hour") }
        return unit(m, "minute")
    }

    /// "This Mac: MacBook Pro, Apple M3 Pro, 18 GB of memory, 12 cores, macOS 14.6.1. It has been
    /// on for 3 days, 4 hours (since it started up on Monday 29 September at 9:12 AM)."
    public static func describe(model: String, chip: String, memoryGB: Int, cores: Int, system: String,
                                bootedAt: Date?, now: Date = Date(), zone: TimeZone = .current) -> String {
        let parts = [model, chip, memoryGB > 0 ? "\(memoryGB) GB of memory" : "", cores > 0 ? "\(cores) cores" : "", system]
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var text = "This Mac: " + parts.joined(separator: ", ") + "."
        if let bootedAt {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "EEEE d MMMM 'at' h:mm a"
            text += " It has been on for \(duration(now.timeIntervalSince(bootedAt))) (since it started up on \(f.string(from: bootedAt)))."
        }
        return text
    }
}
