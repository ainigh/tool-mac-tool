import Foundation

// Actions: what a schedule does, kept apart from when it runs. An action is a name, the
// arguments it takes (each with a value it has when nothing is given), and its steps, run in
// turn: ask the model, remind, say it, run a model tool or a shortcut, call a web address, chime,
// add to a note, wait a while, or run another action (with arguments of its own). A step can be
// turned off (skipped) without taking it away. A step's text can use {{name}} for an
// argument, and {{last}} for what the step before it gave back. A schedule picks an action and
// gives its arguments; the Actions window makes and runs them by hand.

/// A name and a value: one of an action's arguments (with the value it has when none is given),
/// or a value given for one.
public struct ActionArgument: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String = "") {
        self.name = name
        self.value = value
    }

    /// What goes between the braces: lower case letters, digits and _ (a space becomes _).
    public static func clean(_ name: String) -> String {
        let lowered = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_")
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }.map(Character.init))
    }

    /// "{{name}}".
    public var token: String { "{{\(name)}}" }
}

/// One step of an action.
public struct ActionStep: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// The text is a prompt: the model answers it, and may call tools while it does.
        case askModel
        /// The text is shown on a card that stays until you close it.
        case remind
        /// The text is read out in the voice from Read aloud.
        case speak
        /// The text is what one of the model tools is given (`target`: its name, e.g. sound_alarm).
        case tool
        /// The text is a shortcut's input (`target`: the shortcut's name).
        case shortcut
        /// The text is POSTed to a web address (`target`); empty, what happened goes as JSON.
        case webhook
        /// A chime and its card (`target`: "day" for the day chime's, "night" for the night watch's).
        case chime
        /// Another action (`target`: its id), given `arguments`; what it gives back is this step's.
        case runAction
        /// The text is added at the end of a note (`target`: "<board id>#<box>", `ActionStep.note`).
        case addToNote
        /// Waits a while (`target`: how many seconds) before the next step; {{last}} goes on through it.
        case wait

        public var title: String {
            switch self {
            case .askModel: return "Ask the model"
            case .remind: return "Remind me"
            case .speak: return "Say it"
            case .tool: return "Model tool"
            case .shortcut: return "Shortcut"
            case .webhook: return "Call a web address"
            case .chime: return "Chime"
            case .runAction: return "Run an action"
            case .addToNote: return "Add to a note"
            case .wait: return "Wait"
            }
        }

        public var symbol: String {
            switch self {
            case .askModel: return "sparkles"
            case .remind: return "bell"
            case .speak: return "speaker.wave.2"
            case .tool: return "wrench.and.screwdriver"
            case .shortcut: return "bolt.horizontal.circle"
            case .webhook: return "paperplane"
            case .chime: return "bell.and.waves.left.and.right"
            case .runAction: return "arrow.turn.down.right"
            case .addToNote: return "note.text.badge.plus"
            case .wait: return "hourglass"
            }
        }

        /// It gives back text worth showing or saying (a reminder is already shown, a spoken line
        /// said; another action's depends on its last step).
        public var hasResult: Bool { self == .askModel || self == .shortcut || self == .webhook }

        /// It has text of its own (a chime doesn't; another action is given arguments instead).
        public var hasText: Bool { self != .chime && self != .runAction && self != .wait }

        /// What the step before gave back goes on through it, as {{last}} and as the action's result.
        public var passesLast: Bool { self == .wait }
    }

    public var id: String
    public var kind: Kind
    /// The model (Ask the model: "" is the chat's), the tool's or shortcut's name, the web
    /// address, the chime ("day" or "night"), or the action it runs (its id).
    public var target: String
    /// The prompt, the reminder, what to say, or what the tool, shortcut or address is given.
    public var text: String
    /// Ask the model: it may call the model tools and your shortcuts.
    public var useTools: Bool
    /// Call a web address: sent as "Authorization: Bearer <secret>" when it isn't empty.
    public var secret: String
    /// Run an action: the values it gives that action's arguments (they can hold {{…}} too).
    public var arguments: [ActionArgument]
    /// Turned off: skipped when the action runs (kept, to turn on again).
    public var off: Bool

    public init(id: String = UUID().uuidString, kind: Kind = .remind, target: String = "", text: String = "",
                useTools: Bool = true, secret: String = "", arguments: [ActionArgument] = [], off: Bool = false) {
        self.id = id
        self.kind = kind
        self.target = target
        self.text = text
        self.useTools = useTools
        self.secret = secret
        self.arguments = arguments
        self.off = off
    }

    enum CodingKeys: String, CodingKey { case id, kind, target, text, useTools, secret, arguments, off }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .remind
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        useTools = try c.decodeIfPresent(Bool.self, forKey: .useTools) ?? true
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        arguments = (try? c.decodeIfPresent([ActionArgument].self, forKey: .arguments)) ?? []
        off = try c.decodeIfPresent(Bool.self, forKey: .off) ?? false
    }

    /// Wait: how many seconds (1 to an hour; 5 when it isn't a number).
    public var seconds: Int { min(3600, max(1, Int(target.trimmingCharacters(in: .whitespaces)) ?? 5)) }

    /// Add to a note: the note it adds to.
    public var note: NoteLink? {
        guard let hash = target.lastIndex(of: "#"), let box = Int(target[target.index(after: hash)...]), box >= 0 else { return nil }
        let board = String(target[..<hash])
        return board.isEmpty ? nil : NoteLink(board: board, box: box)
    }

    /// The target that adds to `note`.
    public static func target(_ note: NoteLink) -> String { "\(note.board)#\(note.box)" }

    /// What it does, in a few words, for a confirmation ("say its text out loud").
    public func doing(actionName: (String) -> String?) -> String {
        switch kind {
        case .askModel: return "ask the model its prompt"
        case .remind: return "show a reminder on a card that stays until you close it"
        case .speak: return "say its text out loud"
        case .tool: return "run the model tool \(target.isEmpty ? "it's set to" : target)"
        case .shortcut: return "run the shortcut \(target.isEmpty ? "it's set to" : "\u{201C}\(target)\u{201D}")"
        case .webhook: return "call \(URL(string: target)?.host ?? "its web address")"
        case .chime: return target == "night" ? "ding and show the night watch's warning card" : "ding and show the day chime's card"
        case .runAction: return "run \(actionName(target).map { "\u{201C}\($0)\u{201D}" } ?? "another action")"
        case .addToNote: return "add its text to a note"
        case .wait: return "wait \(Self.span(seconds))"
        }
    }

    /// "5 seconds", "2 minutes", "1 minute 30 seconds".
    public static func span(_ seconds: Int) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let m = seconds / 60, s = seconds % 60
        if m == 0 { return unit(s, "second") }
        return s == 0 ? unit(m, "minute") : unit(m, "minute") + " " + unit(s, "second")
    }
}

/// An action: its name, the arguments it takes, and its steps.
public struct SavedAction: Codable, Equatable, Identifiable, Sendable {
    /// The built-in actions (the built-in schedules run them): kept, as they are.
    public enum Builtin: String, CaseIterable, Sendable {
        case dayChime = "day-chime"
        case nightWatch = "night-chime"

        public var id: String { "action-\(rawValue)" }

        public var action: SavedAction {
            switch self {
            case .dayChime:
                return SavedAction(id: id, name: "Day chime", steps: [ActionStep(id: "\(id)-step", kind: .chime, target: "day")],
                                   builtin: rawValue)
            case .nightWatch:
                return SavedAction(id: id, name: "Night watch", steps: [ActionStep(id: "\(id)-step", kind: .chime, target: "night")],
                                   builtin: rawValue)
            }
        }
    }

    public var id: String
    public var name: String
    /// The arguments it takes, each with the value it has when none is given.
    public var parameters: [ActionArgument]
    public var steps: [ActionStep]
    /// Which built-in action this is, if it's one: it can't be changed or deleted.
    public var builtin: String?

    public var isBuiltin: Bool { builtin != nil }

    public init(id: String = UUID().uuidString, name: String = "New action", parameters: [ActionArgument] = [],
                steps: [ActionStep] = [], builtin: String? = nil) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.steps = steps
        self.builtin = builtin
    }

    enum CodingKeys: String, CodingKey { case id, name, parameters, steps, builtin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Action"
        parameters = (try? c.decodeIfPresent([ActionArgument].self, forKey: .parameters)) ?? []
        steps = (try? c.decodeIfPresent([ActionStep].self, forKey: .steps)) ?? []
        builtin = try c.decodeIfPresent(String.self, forKey: .builtin)
    }

    /// The steps that run (the ones turned off are skipped).
    public var live: [ActionStep] { steps.filter { !$0.off } }

    /// Its icon: its one step's, or a stack for several.
    public var symbol: String {
        live.count == 1 ? live[0].kind.symbol : live.isEmpty ? "bolt.slash" : "square.stack.3d.down.right"
    }

    /// Its steps, in a few words ("Ask the model, then Say it"; the ones turned off left out).
    public var summary: String {
        if steps.isEmpty { return "No steps yet" }
        if live.isEmpty { return "Every step is turned off" }
        let off = steps.count - live.count
        return live.map(\.kind.title).joined(separator: ", then ") + (off > 0 ? " (\(off) off)" : "")
    }

    /// The only step is a chime (a chime missed while the Mac slept waits for the next hour, and
    /// isn't kept in the history).
    public var isChime: Bool { steps.count == 1 && steps[0].kind == .chime }

    /// The values its arguments have when it's given these: each one given (and not empty),
    /// else its own. Given names it doesn't take are left out.
    public func values(given: [ActionArgument]) -> [String: String] {
        var out: [String: String] = [:]
        for p in parameters where !p.name.isEmpty {
            let v = given.last { $0.name == p.name }?.value ?? ""
            out[p.name] = v.isEmpty ? p.value : v
        }
        return out
    }

    /// The arguments to give it, filled in from what was given before (for its names now): what a
    /// schedule or step shows to fill in.
    public func arguments(keeping given: [ActionArgument]) -> [ActionArgument] {
        parameters.filter { !$0.name.isEmpty }.map { p in
            ActionArgument(name: p.name, value: given.last { $0.name == p.name }?.value ?? "")
        }
    }
}

/// Every action, in ~/Library/Application Support/ToolMacTool/actions.json.
public struct ActionBook: Codable, Equatable, Sendable {
    public var actions: [SavedAction] = []

    public init(actions: [SavedAction] = []) { self.actions = actions }

    public func action(_ id: String?) -> SavedAction? { actions.first { $0.id == id } }

    /// The built-in actions are all there (one that's missing comes back, as it was); they go first.
    public mutating func ensureBuiltins() {
        actions.removeAll { $0.isBuiltin || SavedAction.Builtin.allCases.map(\.id).contains($0.id) }
        actions.insert(contentsOf: SavedAction.Builtin.allCases.map(\.action), at: 0)
    }

    /// The actions that run this one (in one of their steps), by name.
    public func callers(of id: String) -> [String] {
        actions.filter { a in a.id != id && a.steps.contains { $0.kind == .runAction && $0.target == id } }.map(\.name)
    }

    /// If running `id` would come back round to an action already running, the names along the
    /// way ("A", "B", "A"); nil when it doesn't.
    public func loop(from id: String) -> [String]? {
        func walk(_ id: String, _ path: [String]) -> [String]? {
            if path.contains(id) { return path + [id] }
            guard let a = action(id) else { return nil }
            for s in a.steps where s.kind == .runAction {
                if let found = walk(s.target, path + [id]) { return found }
            }
            return nil
        }
        return walk(id, []).map { $0.map { action($0)?.name ?? "?" } }
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/actions.json")
    }

    public static func load(from url: URL) -> ActionBook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ActionBook.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// One to start from: an action with an argument, and one that runs it.
    public static var examples: [SavedAction] {
        let say = SavedAction(name: "Remind and say", parameters: [ActionArgument(name: "message", value: "Time for a break.")],
                              steps: [ActionStep(kind: .remind, text: "{{message}}"), ActionStep(kind: .speak, text: "{{message}}")])
        let water = SavedAction(name: "Drink some water", steps: [
            ActionStep(kind: .runAction, target: say.id, arguments: [ActionArgument(name: "message", value: "Drink some water ({{time}}).")]),
        ])
        return [say, water]
    }
}

/// Running an action: its steps in turn, each one's text filled in (its arguments, {{last}} for
/// what the step before gave back, and whatever else the caller knows), stopping at the first that
/// fails. What it gives back is its last step's. A step that runs another action runs it the same
/// way, with the arguments it gives (filled in first); an action that would come round to itself,
/// or actions calling each other more than `maxDepth` deep, fail instead.
public enum ActionRunner {
    public struct Outcome: Equatable, Sendable {
        public var ok: Bool
        public var output: String
        /// The tools, shortcuts and addresses it used.
        public var tools: [String]
        /// Its result is worth showing or saying (it wasn't shown or said already).
        public var fresh: Bool

        public init(ok: Bool, output: String, tools: [String] = [], fresh: Bool = false) {
            self.ok = ok
            self.output = output
            self.tools = tools
            self.fresh = fresh
        }

        public static func failed(_ why: String) -> Outcome { Outcome(ok: false, output: why) }
    }

    public static let maxDepth = 8

    /// Runs action `id`. `arguments`: the values given (already filled in); `context`: what every
    /// step can use besides the arguments (the time, the schedule, what happened); `last`: what
    /// {{last}} is for the first step. `fill` fills a text in from values and a {{last}}; `step`
    /// does one step (never Run an action: that's done here) with its filled-in text.
    @MainActor
    public static func run(_ id: String, arguments: [ActionArgument], context: [String: String], last: String?,
                           book: ActionBook, stack: [String] = [],
                           fill: (String, String?, [String: String]) -> String,
                           step: (ActionStep, String, [String: String]) async -> Outcome) async -> Outcome {
        guard let action = book.action(id) else {
            return .failed(stack.isEmpty ? "The action it runs is gone: pick another." : "An action it runs is gone: pick another in Actions.")
        }
        if stack.contains(id) {
            let names = (stack + [id]).map { book.action($0)?.name ?? "?" }
            return .failed("\u{201C}\(action.name)\u{201D} comes round to itself: \(names.joined(separator: " → ")).")
        }
        guard stack.count < maxDepth else {
            return .failed("Actions run each other more than \(maxDepth) deep (at \u{201C}\(action.name)\u{201D}).")
        }
        guard !action.steps.isEmpty else { return .failed("\u{201C}\(action.name)\u{201D} has no steps yet: add one in Actions.") }
        guard !action.live.isEmpty else { return .failed("Every step of \u{201C}\(action.name)\u{201D} is turned off: turn one on in Actions.") }
        var values = context
        values.merge(action.values(given: arguments)) { $1 }
        var previous = last
        var tools: [String] = []
        var result = Outcome(ok: true, output: "")
        for (n, s) in action.steps.enumerated() where !s.off {
            let outcome: Outcome
            if s.kind == .runAction {
                let given = s.arguments.map { ActionArgument(name: $0.name, value: fill($0.value, previous, values)) }
                outcome = await run(s.target, arguments: given, context: context, last: previous, book: book,
                                    stack: stack + [id], fill: fill, step: step)
            } else {
                outcome = await step(s, fill(s.text, previous, values), values)
            }
            tools += outcome.tools
            guard outcome.ok else {
                let at = action.steps.count > 1 ? "\(action.name), step \(n + 1) (\(s.kind.title)): " : ""
                return Outcome(ok: false, output: at + outcome.output, tools: tools)
            }
            // A wait gives back nothing of its own: what came before goes on through it.
            if !s.kind.passesLast {
                result = outcome
                previous = outcome.output
            }
        }
        return Outcome(ok: true, output: result.output, tools: tools, fresh: result.fresh)
    }
}
