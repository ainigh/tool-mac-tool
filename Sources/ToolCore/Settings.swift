import Foundation

/// One of the system prompts you pick from in the chat (up to `SystemPrompt.limit` of them).
public struct SystemPrompt: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var text: String

    public init(id: String = UUID().uuidString, name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }

    /// How many there can be: one for each of ⌘1 to ⌘9.
    public static let limit = 9

    public static let defaults: [SystemPrompt] = [
        SystemPrompt(id: "glass", name: "Glass", text: """
            You are Glass, a helpful assistant running privately on the user's own Mac. Be warm, direct and \
            accurate. Answer the question that was asked first, then add only what helps. Keep replies clear and \
            fairly short unless the user asks for depth. Use Markdown (lists, headings, code blocks) when it makes \
            a reply easier to read. If you're not sure of something, say so plainly rather than guessing.
            """),
        SystemPrompt(id: "brief", name: "Brief", text: """
            You are Glass, in brief mode. Answer in as few words as will do: one sentence or a short list is \
            usually right. No preamble, no restating the question, no closing offers of more help. Expand only \
            when the user asks for detail.
            """),
        SystemPrompt(id: "tutor", name: "Tutor", text: """
            You are Glass, a patient tutor. Explain ideas step by step, starting from what the user already \
            knows, with a concrete example for each new idea. Check understanding with a short question now and \
            then. Prefer plain words to jargon, and define any term you have to use.
            """),
        SystemPrompt(id: "coder", name: "Coder", text: """
            You are Glass, a senior software engineer pairing with the user on their Mac. Give working, idiomatic \
            code in fenced blocks with the language named, and keep explanations short and to the point. Point out \
            bugs, edge cases and security problems you notice. When a request is ambiguous, state the assumption \
            you're making and carry on.
            """),
        SystemPrompt(id: "editor", name: "Editor", text: """
            You are Glass, a careful editor. When the user gives you text, improve its clarity, flow and grammar \
            while keeping their voice and meaning. Return the revised text first, then (only if useful) a few \
            short notes on what you changed and why. Don't add facts that weren't there.
            """),
        SystemPrompt(id: "sounding-board", name: "Sounding board", text: """
            You are Glass, a thoughtful sounding board. Help the user think things through: reflect back what you \
            hear, ask one good question at a time, and offer options with their trade-offs rather than verdicts. \
            Be honest when something doesn't add up.
            """),
    ]
}

/// The character that goes with one of the voices: when a chat speaks in that voice, the model is
/// told to be this persona.
public struct Persona: Codable, Equatable, Identifiable {
    /// The voice it goes with (NeuralVoice.id).
    public var voice: String
    public var name: String
    public var text: String
    public var id: String { voice }

    public init(voice: String, name: String, text: String) {
        self.voice = voice
        self.name = name
        self.text = text
    }

    public static let defaults: [Persona] = [
        Persona(voice: "af_heart", name: "Heart", text: """
            Warm, calm and encouraging, with a gentle sense of humor. You sound like a kind friend who happens \
            to know a lot: unhurried, reassuring, never preachy.
            """),
        Persona(voice: "af_bella", name: "Bella", text: """
            Bright, upbeat and curious. You're quick and playful, enjoy a good idea, and keep the energy up \
            without gushing.
            """),
        Persona(voice: "am_michael", name: "Michael", text: """
            Steady, clear and practical, like a trusted colleague. You get to the point, use plain words, and \
            say what you'd actually do.
            """),
        Persona(voice: "am_fenrir", name: "Fenrir", text: """
            Confident and direct, with a dry wit. You give candid opinions, keep it brief, and don't sugar-coat \
            things, but you're never unkind.
            """),
    ]

    /// The persona for a voice: the one saved for it, else its default, else a plain one.
    public static func `for`(_ voice: String, in list: [Persona]) -> Persona {
        list.first { $0.voice == voice } ?? defaults.first { $0.voice == voice }
            ?? Persona(voice: voice, name: NeuralVoice.named(voice).name, text: "")
    }

    /// What the model is told about who it is when it speaks in this voice.
    public var prompt: String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return "" }
        return "You are speaking in the voice called \(name). Your persona: \(body)"
    }
}

/// Everything the Settings window sets: where the model is, which one, how the chat behaves by
/// default, the time and place the model is told about, the prompts and the personas. Saved as
/// JSON; keys missing from the file (an older version wrote it) take their defaults.
public struct AppSettings: Codable, Equatable {
    public enum Thinking: String, Codable, CaseIterable {
        /// Leave it to the model (nothing is sent).
        case auto
        /// Reasoning models think before answering (slower).
        case on
        /// Answer straight away.
        case off
    }

    public enum PersonaScope: String, Codable, CaseIterable {
        /// Only when the chat speaks its replies.
        case spoken
        /// In every chat.
        case always
        case never
    }

    public var ollama = AppSettings.defaultOllama
    public var model = ""
    /// The diagram tool's model; empty means the chat's.
    public var diagramModel = ""
    public var contextTokens = 8192
    public var temperature = 0.7
    public var thinking = Thinking.auto

    /// How a chat starts: ChatKind's raw value.
    public var mode = "text"
    public var promptID = SystemPrompt.defaults[0].id
    public var memoryOn = true
    /// Facts the model suggests go straight into memory (each can be undone), instead of asking first.
    public var autoRemember = true

    /// An IANA time zone ("Europe/London"); empty means this Mac's.
    public var timeZone = ""
    /// Where you are, in your words ("Lagos, Nigeria"); empty means a guess from the time zone.
    public var location = ""
    public var clock24 = false

    public var personaScope = PersonaScope.spoken
    /// How the model is told to use and keep the memory; `{{memory}}` is replaced by MEMORY.md.
    public var memoryPrompt = MemoryStore.defaultInstruction
    public var prompts = SystemPrompt.defaults
    public var personas = Persona.defaults
    /// Apple Shortcuts the chat's model may run, and whether it may.
    public var shortcuts: [ShortcutTool] = []
    public var toolsOn = true

    public static let defaultOllama = "http://127.0.0.1:11434"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case ollama, model, diagramModel, contextTokens, temperature, thinking, mode, promptID, memoryOn,
             autoRemember, timeZone, location, clock24, personaScope, memoryPrompt, prompts, personas,
             shortcuts, toolsOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = AppSettings()
        func take<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { into = v }
        }
        take(.ollama, &s.ollama)
        take(.model, &s.model)
        take(.diagramModel, &s.diagramModel)
        take(.contextTokens, &s.contextTokens)
        take(.temperature, &s.temperature)
        take(.thinking, &s.thinking)
        take(.mode, &s.mode)
        take(.promptID, &s.promptID)
        take(.memoryOn, &s.memoryOn)
        take(.autoRemember, &s.autoRemember)
        take(.timeZone, &s.timeZone)
        take(.location, &s.location)
        take(.clock24, &s.clock24)
        take(.personaScope, &s.personaScope)
        take(.memoryPrompt, &s.memoryPrompt)
        take(.prompts, &s.prompts)
        take(.personas, &s.personas)
        take(.shortcuts, &s.shortcuts)
        take(.toolsOn, &s.toolsOn)
        self = s.tidied()
    }

    /// Within limits: at most 9 prompts (at least one), a context window Ollama can take, a
    /// prompt picked that exists, a persona for every voice.
    public func tidied() -> AppSettings {
        var s = self
        if s.prompts.isEmpty { s.prompts = [SystemPrompt.defaults[0]] }
        if s.prompts.count > SystemPrompt.limit { s.prompts = Array(s.prompts.prefix(SystemPrompt.limit)) }
        if !s.prompts.contains(where: { $0.id == s.promptID }) { s.promptID = s.prompts[0].id }
        s.contextTokens = min(131_072, max(2048, s.contextTokens))
        s.temperature = min(2, max(0, s.temperature))
        for voice in NeuralVoice.all where !s.personas.contains(where: { $0.voice == voice.id }) {
            s.personas.append(Persona.for(voice.id, in: []))
        }
        if s.memoryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s.memoryPrompt = MemoryStore.defaultInstruction
        }
        return s
    }

    public func prompt(_ id: String?) -> SystemPrompt {
        prompts.first { $0.id == id } ?? prompts.first { $0.id == promptID } ?? prompts.first ?? SystemPrompt.defaults[0]
    }

    /// How much of the context window is kept for the reply.
    public var replyTokens: Int { min(4096, max(512, contextTokens / 4)) }

    public var zone: TimeZone { timeZone.isEmpty ? .current : TimeZone(identifier: timeZone) ?? .current }

    // MARK: - On disk

    /// ~/Library/Application Support/ToolMacTool/settings.json
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/ToolMacTool/settings.json")
    }

    /// The saved settings, or nil when there's no file yet (or it can't be read).
    public static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
