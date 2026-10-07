import AppKit
import Combine
import Foundation
import SwiftUI
import ToolCore

/// Talks to Ollama (the address in Settings).
struct Ollama {
    var base: URL

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The models Ollama has pulled.
    func models() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/tags"))
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    /// The reply, streamed a piece at a time. `contextTokens` is the context window asked for:
    /// without it Ollama uses its own default, which is often smaller than what's sent, and then it
    /// cuts the start of the prompt, the system message with the memory in it.
    func chat(model: String, messages: [ChatTurn], contextTokens: Int, temperature: Double? = nil,
              thinking: AppSettings.Thinking = .auto, tools: [OllamaTool] = []) -> AsyncThrowingStream<OllamaChunk, Error> {
        struct Body: Encodable {
            struct Options: Encodable {
                let num_ctx: Int
                let temperature: Double?
            }
            let model: String
            let messages: [ChatTurn]
            let stream = true
            let options: Options
            /// Left out unless it's set: models that can't think refuse it.
            let think: Bool?
            /// Left out when there are none: models that can't call tools refuse them.
            let tools: [OllamaTool]?
        }
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let think: Bool? = thinking == .auto ? nil : thinking == .on
        req.httpBody = try? JSONEncoder().encode(Body(model: model, messages: messages,
                                                      options: .init(num_ctx: contextTokens, temperature: temperature),
                                                      think: think, tools: tools.isEmpty ? nil : tools))
        req.timeoutInterval = 600
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    for try await line in bytes.lines {
                        guard let chunk = OllamaChunk.parse(line) else { continue }
                        if let e = chunk.error { throw Problem(e) }
                        continuation.yield(chunk)
                        if chunk.done { break }
                    }
                    if status != 200 { throw Problem("Ollama answered \(status)") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole reply at once (the diagram tool doesn't show it streaming).
    func reply(model: String, messages: [ChatTurn], contextTokens: Int, temperature: Double? = nil,
               thinking: AppSettings.Thinking = .auto) async throws -> String {
        var text = ""
        for try await chunk in chat(model: model, messages: messages, contextTokens: contextTokens,
                                    temperature: temperature, thinking: thinking) {
            text += chunk.message?.content ?? ""
        }
        return text
    }

    /// What to tell you when a request failed.
    func explain(_ error: Error) -> String {
        let code = (error as? URLError)?.code
        if code == .cannotConnectToHost || code == .cannotFindHost || code == .networkConnectionLost {
            return notRunning
        }
        return error.localizedDescription
    }

    /// The error a model gives when it can't call tools.
    static func cantUseTools(_ error: Error) -> Bool {
        error.localizedDescription.contains("does not support tools")
    }

    var notRunning: String {
        "Ollama isn't running (\(base.absoluteString)): open the Ollama app, or run ollama serve"
    }
}

/// How the chat is used: the same conversation underneath, with a different way of talking to it
/// and of hearing back. Switched from the chat's controls; Settings picks the one it starts in.
enum ChatKind: String, CaseIterable {
    /// Type, read.
    case text
    /// Type; the reply is also spoken.
    case speaks
    /// Talk; the reply is written.
    case listens
    /// Talk, listen: no box to type in.
    case voice

    var speaks: Bool { self == .speaks || self == .voice }
    var listens: Bool { self == .listens || self == .voice }

    var title: String {
        switch self {
        case .text: return "Type"
        case .speaks: return "Type, hear the reply"
        case .listens: return "Talk, read the reply"
        case .voice: return "Conversation (talk and listen)"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "keyboard"
        case .speaks: return "speaker.wave.2.bubble.left"
        case .listens: return "mic.badge.plus"
        case .voice: return "waveform.and.mic"
        }
    }

    /// What the model is told about how its replies reach you, or how your messages reach it.
    var note: String {
        switch self {
        case .text:
            return ""
        case .speaks:
            return "Your replies are also read aloud, so prefer plain sentences to tables, long lists and symbols."
        case .listens:
            return "The user's messages are transcribed from speech and may contain recognition mistakes: "
                + "read them generously, and ask when something is unclear."
        case .voice:
            return "This is a spoken conversation: the user talks (transcribed, so allow for recognition mistakes) "
                + "and your reply is read aloud. Answer like a person talking: usually one to three short sentences, "
                + "no lists, headings, tables, code or Markdown, nothing that only makes sense on screen."
        }
    }
}

/// The conversation: what's been said, what's streaming in, how you're talking (the mode), the
/// system prompt it uses, and the memory.
@MainActor
final class ChatModel: ObservableObject {
    /// `proposal`: a memory change the model suggested, waiting for a yes or no (when Settings
    /// says to ask first). `note`: a memory change that was made.
    enum Role { case user, assistant, note, proposal }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String
        /// A reply that didn't finish: "stopped" or "failed".
        var note = ""
        /// For memory proposals and notes: the fact, and whether it's being forgotten.
        var fact = ""
        var forgetting = false
        /// A memory note whose change was taken back.
        var undone = false
        /// On a reply: the tool calls it made and their results, kept so later replies see them.
        var toolTurns: [ChatTurn] = []
        /// On a reply: the shortcuts it ran ("Weather", "Add Reminder (declined)").
        var ran: [String] = []
    }

    enum Phase { case idle, thinking, streaming }

    @Published private(set) var messages: [Message] = []
    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var models: [String] = []
    @Published private(set) var problem: String?
    /// Tokens the last reply read (the whole context sent) and wrote.
    @Published private(set) var usage: (prompt: Int, output: Int)?
    /// How you talk to it and hear back.
    @Published var mode: ChatKind
    /// The system prompt this chat uses (one of Settings' prompts).
    @Published var promptID: String
    /// Whether MEMORY.md goes with each message and the model may change it.
    @Published var memoryOn: Bool
    /// The window stays above others.
    @Published var pinned = true
    /// Whether the model may run the shortcuts set up in Tools.
    @Published var toolsOn: Bool
    /// What's happening while no words come ("Running Weather…").
    @Published private(set) var activity: String?

    let memory: MemoryStore
    let prefs = Preferences.shared
    /// For a voice: a reply started, grew (the text so far, tags hidden), ended (what's shown,
    /// and "stopped" or "failed" if it didn't finish), or the conversation was cleared.
    var onReplyStart: (() -> Void)?
    var onReplyText: ((String) -> Void)?
    var onReplyEnd: ((String, String) -> Void)?
    var onClear: (() -> Void)?
    private var transcript: Transcript?
    private var task: Task<Void, Never>?
    /// Counts replies, so one that was stopped by a new chat can't touch the next reply's state.
    private var turn = 0
    private var watch: AnyCancellable?
    /// Models Ollama said can't call tools: asked without them from then on.
    private var toolless = Set<String>()
    /// How many rounds of tool calls one reply may make before it has to answer.
    static let toolRounds = 4

    init() {
        let s = Preferences.shared.settings
        mode = ChatKind(rawValue: s.mode) ?? .text
        promptID = s.promptID
        memoryOn = s.memoryOn
        toolsOn = s.toolsOn
        memory = MemoryStore.forCurrentUser()
        // The model and the prompts live in Settings: when they change, this redraws.
        watch = prefs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var settings: AppSettings { prefs.settings }
    var ollama: Ollama { prefs.ollama }

    var model: String {
        get { settings.model }
        set { prefs.settings.model = newValue }
    }

    /// The system prompt in use.
    var prompt: SystemPrompt { settings.prompt(promptID) }

    var glassFolder: URL { memory.url.deletingLastPathComponent().deletingLastPathComponent() }

    /// ⌘1 to ⌘9: the system prompt in that place.
    func choosePrompt(number: Int) {
        let prompts = settings.prompts
        guard number >= 1, number <= prompts.count else { return }
        promptID = prompts[number - 1].id
    }

    func loadModels() {
        Task {
            do {
                let names = try await ollama.models()
                models = names
                if names.isEmpty {
                    problem = "Ollama has no models yet: run ollama pull llama3.2 in Terminal"
                } else {
                    if !names.contains(model) { model = names[0] }
                    // Ollama's back with models: a problem about it (or about having no model
                    // picked, which this just fixed) no longer holds.
                    if problem?.hasPrefix("Ollama") == true || problem?.hasPrefix("Pick a model") == true { problem = nil }
                }
            } catch {
                problem = ollama.notRunning
            }
        }
    }

    /// Sends what's in the box. `spoken`: it was said, not typed (the transcript says so).
    func send(spoken: Bool = false) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .idle, haveModel() else { return }
        input = ""
        problem = nil
        messages.append(Message(role: .user, text: text))
        record(who: spoken ? "you (voice)" : "you", text: text)
        reply()
    }

    /// Whether a reply can be asked for again: nothing is streaming and you've said something.
    var canRetry: Bool { phase == .idle && messages.contains { $0.role == .user } }

    /// Asks again for the reply to your last message: what came after it goes, and the
    /// conversation as it stands is sent again.
    func retry() {
        guard canRetry, haveModel(), let last = messages.lastIndex(where: { $0.role == .user }) else { return }
        messages.removeSubrange((last + 1)...)
        problem = nil
        reply()
    }

    private func haveModel() -> Bool {
        if !model.isEmpty { return true }
        problem = "Pick a model first (Ollama needs at least one: ollama pull llama3.2)"
        loadModels()
        return false
    }

    /// Everything the model is told before the conversation: the system prompt, the persona of
    /// the voice (when it speaks), how replies reach you, the memory and how to keep it, and the
    /// date, time and place (last, so the rest stays the same from one message to the next).
    func systemMessage(now: Date = Date()) -> String {
        let s = settings
        var parts = [prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)]
        let persona = Persona.for(VoiceSettings.voice.id, in: s.personas).prompt
        if !persona.isEmpty, s.personaScope == .always || (s.personaScope == .spoken && mode.speaks) {
            parts.append(persona)
        }
        if !mode.note.isEmpty { parts.append(mode.note) }
        if !tools.isEmpty {
            parts.append("You have tools that act on the user's Mac (and some of their Apple Shortcuts). Call one when "
                + "the request matches its description, then answer using what it returns; don't call tools otherwise, "
                + "and never pretend you ran one.")
        }
        if memoryOn {
            parts.append(MemoryStore.prompt(memory: memory.read(), instruction: s.memoryPrompt))
        }
        parts.append(NowContext.describe(now, zone: s.zone, location: s.location, clock24: s.clock24))
        if s.shareMacInfo { parts.append(MacFacts.describe(now: now, zone: s.zone)) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// What a tool the model calls does: one of the app's own, or a shortcut.
    enum ToolAction {
        case builtin(BuiltinTool)
        case shortcut(ShortcutTool)

        func spec(name: String) -> OllamaTool {
            switch self {
            case .builtin(let t): return t.spec()
            case .shortcut(let t): return t.spec(name: name)
            }
        }
    }

    /// The tools this reply may call, by the names the model calls them: the app's own (Model
    /// tools), then the shortcuts (Tools).
    var tools: [(name: String, action: ToolAction)] {
        guard toolsOn, settings.toolsOn, !toolless.contains(model) else { return [] }
        let builtins = settings.builtins.filter(\.enabled)
        let shortcuts = ShortcutTool.callable(settings.shortcuts, reserved: Set(builtins.map(\.name)))
        return builtins.map { ($0.name, ToolAction.builtin($0)) } + shortcuts.map { ($0.name, ToolAction.shortcut($0.tool)) }
    }

    private func reply() {
        let history = messages.flatMap { m -> [ChatTurn] in
            switch m.role {
            case .user: return [ChatTurn(role: "user", content: m.text)]
            case .assistant:
                return m.toolTurns + (m.text.isEmpty ? [] : [ChatTurn(role: "assistant", content: m.text)])
            case .note, .proposal: return []
            }
        }
        let s = settings
        let system = ChatTurn(role: "system", content: systemMessage())
        let budget = ChatTurn.budget(contextTokens: s.contextTokens, system: system.content, replyTokens: s.replyTokens)
        let start = [system] + ChatTurn.window(history, budget: budget)

        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        phase = .thinking
        turn += 1
        onReplyStart?()
        let mine = turn
        let model = self.model
        let ollama = self.ollama
        let tools = self.tools
        let offered = tools.map { $0.action.spec(name: $0.name) }
        task = Task {
            var raw = ""
            var note = ""
            var turns = start
            var toolTurns: [ChatTurn] = []
            var ran: [String] = []
            var specs = offered
            do {
                var round = 0
                rounds: while true {
                    let before = raw.isEmpty ? "" : raw + "\n\n"
                    var said = ""
                    var calls: [ToolCall] = []
                    do {
                        let offer = round < Self.toolRounds ? specs : []
                        for try await chunk in ollama.chat(model: model, messages: turns, contextTokens: s.contextTokens,
                                                           temperature: s.temperature, thinking: s.thinking, tools: offer) {
                            guard mine == turn else { break rounds }
                            if let piece = chunk.message?.content, !piece.isEmpty {
                                said += piece
                                phase = .streaming
                                let shown = MemoryStore.hideTags(before + said)
                                update(reply.id, text: shown)
                                onReplyText?(shown)
                            }
                            if let c = chunk.message?.toolCalls { calls += c }
                            if chunk.done, let p = chunk.promptTokens {
                                usage = (p, chunk.outputTokens ?? 0)
                            }
                        }
                    } catch let error where !specs.isEmpty && Ollama.cantUseTools(error) {
                        // This model can't call tools: ask again without them.
                        toolless.insert(model)
                        specs = []
                        continue rounds
                    }
                    if !said.isEmpty { raw = before + said }
                    if calls.isEmpty || Task.isCancelled || mine != turn { break }
                    round += 1
                    let asked = ChatTurn(role: "assistant", content: said, toolCalls: calls)
                    turns.append(asked)
                    toolTurns.append(asked)
                    for call in calls {
                        let (result, label) = await runTool(call, among: tools)
                        guard mine == turn, !Task.isCancelled else { break rounds }
                        ran.append(label)
                        let answer = ChatTurn(role: "tool", content: result, toolName: call.function.name)
                        turns.append(answer)
                        toolTurns.append(answer)
                    }
                    phase = .thinking
                }
                // A stopped stream just ends, without an error.
                if Task.isCancelled { note = "stopped" }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    note = "stopped"
                } else if mine == turn {
                    note = "failed"
                    problem = ollama.explain(error)
                }
            }
            // A new chat since: this reply is gone, and the next one's state isn't ours to change.
            guard mine == turn else { return }
            activity = nil
            if let i = messages.firstIndex(where: { $0.id == reply.id }) {
                messages[i].toolTurns = toolTurns
                messages[i].ran = ran
            }
            finish(reply.id, raw: raw, model: model, note: note)
        }
    }

    /// Runs the shortcut a call names (asking first if it's set to): what goes back to the model,
    /// and what the chat shows.
    private func runTool(_ call: ToolCall, among tools: [(name: String, action: ToolAction)]) async -> (String, String) {
        guard let action = tools.first(where: { $0.name == call.function.name })?.action else {
            return ("There's no tool called \(call.function.name).", call.function.name + " (not a tool)")
        }
        let tool: ShortcutTool
        switch action {
        case .builtin(let builtin):
            record(who: "tool", text: "_\(builtin.kind.title)_")
            return ModelTools.shared.run(builtin, call: call)
        case .shortcut(let shortcut):
            tool = shortcut
        }
        let input = ShortcutTool.input(from: call)
        if tool.confirm && !Self.allowed(tool, input: input) {
            return ("The user chose not to run it this time.", tool.shortcut + " (declined)")
        }
        activity = "Running \(tool.shortcut)…"
        defer { activity = nil }
        record(who: "shortcut", text: "_ran \(tool.shortcut)_" + (input.isEmpty ? "" : ": \(input)"))
        do {
            let out = try await ShortcutRunner.run(tool.shortcut, input: input, returnsText: tool.returnsText)
            if !tool.returnsText { return ("Done: the shortcut ran.", tool.shortcut) }
            return (out.isEmpty ? "The shortcut ran and gave nothing back." : out, tool.shortcut)
        } catch {
            return ("The shortcut failed: \(error.localizedDescription)", tool.shortcut + " (failed)")
        }
    }

    /// "Run Weather?" with what it'll be given.
    private static func allowed(_ tool: ShortcutTool, input: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Run the \u{201C}\(tool.shortcut)\u{201D} shortcut?"
        alert.informativeText = input.isEmpty ? "The model wants to run it, with no input."
            : "The model wants to run it with:\n\n\(input.prefix(600))"
        alert.addButton(withTitle: "Run")
        // Esc says no, like Cancel would (NSAlert only gives Esc to a button titled Cancel).
        alert.addButton(withTitle: "Don't run").keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func stop() {
        task?.cancel()
    }

    func clearProblem() {
        problem = nil
    }

    func newChat() {
        activity = nil
        task?.cancel()
        task = nil
        turn += 1
        messages = []
        transcript = nil
        usage = nil
        phase = .idle
        onClear?()
    }

    // MARK: -

    private func update(_ id: UUID, text: String) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].text = text }
    }

    private func finish(_ id: UUID, raw: String, model: String, note: String) {
        phase = .idle
        task = nil
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let (shown, remember, forget) = MemoryStore.extractAll(raw)
        if shown.isEmpty && note == "stopped" {
            // Kept, empty, so it says it was stopped and offers to try again.
            messages[i].note = note
        } else if shown.isEmpty {
            messages.remove(at: i)
        } else {
            messages[i].text = shown
            messages[i].note = note
        }
        if memoryOn { changeMemory(remember: remember, forget: forget) }
        if !shown.isEmpty {
            record(who: model, text: shown, note: note)
        }
        onReplyEnd?(shown, note.isEmpty && shown.isEmpty ? "failed" : note)
    }

    // MARK: - Memory

    /// What the model asked to remember and forget: done straight away (each can be undone), or
    /// offered for a yes first, as Settings says.
    private func changeMemory(remember: [String], forget: [String]) {
        let known = MemoryStore.facts(in: memory.read())
        var seen = Set<String>()
        func tidy(_ fact: String) -> String? {
            let clean = fact.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return clean.isEmpty || !seen.insert(clean.lowercased()).inserted ? nil : clean
        }
        let drops = forget.compactMap(tidy)
        let adds = remember.compactMap(tidy).filter { !known.contains($0.lowercased()) }
        if settings.autoRemember {
            for fact in drops { apply(fact, forgetting: true) }
            for fact in adds { apply(fact, forgetting: false) }
        } else {
            for fact in drops { messages.append(Message(role: .proposal, text: fact, fact: fact, forgetting: true)) }
            for fact in adds { messages.append(Message(role: .proposal, text: fact, fact: fact)) }
        }
    }

    /// Makes one change to MEMORY.md and notes it in the conversation. Returns whether it changed.
    @discardableResult
    private func apply(_ fact: String, forgetting: Bool, replacing id: UUID? = nil) -> Bool {
        do {
            var changed: String?
            if forgetting {
                changed = try memory.forget(fact).first
            } else if try memory.remember(fact) != nil {
                changed = fact
            }
            guard let changed else {
                if let id { messages.removeAll { $0.id == id } }
                return false
            }
            record(who: "memory", text: forgetting ? "_forgot: \(changed)_" : "_remembered: \(changed)_")
            let note = Message(role: .note, text: (forgetting ? "Forgot: " : "Remembered: ") + changed,
                               fact: changed, forgetting: forgetting)
            if let id, let i = messages.firstIndex(where: { $0.id == id }) {
                messages[i] = note
            } else {
                messages.append(note)
            }
            return true
        } catch {
            problem = "Couldn't write MEMORY.md: \(error.localizedDescription)"
            return false
        }
    }

    /// Yes to a suggested change.
    func accept(_ id: UUID) {
        guard let m = messages.first(where: { $0.id == id }), m.role == .proposal else { return }
        apply(m.fact, forgetting: m.forgetting, replacing: id)
    }

    /// No to a suggested change.
    func dismiss(_ id: UUID) {
        messages.removeAll { $0.id == id && $0.role == .proposal }
    }

    /// Takes back a change that was made: forgets what was remembered, or remembers it again.
    func undo(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].role == .note, !messages[i].undone else { return }
        let m = messages[i]
        do {
            if m.forgetting { try memory.remember(m.fact) } else { try memory.forget(m.fact) }
            messages[i].undone = true
            messages[i].text = (m.forgetting ? "Kept: " : "Not remembered: ") + m.fact
            record(who: "memory", text: m.forgetting ? "_kept: \(m.fact)_" : "_unremembered: \(m.fact)_")
        } catch {
            problem = "Couldn't write MEMORY.md: \(error.localizedDescription)"
        }
    }

    /// Each turn goes into a glass-chat-<time>.md in the Glass folder, like Glass's own chats.
    private func record(who: String, text: String, note: String = "") {
        if transcript == nil { transcript = Transcript(folder: glassFolder) }
        try? transcript?.append(Transcript.block(who: who, text: text, note: note))
    }
}
