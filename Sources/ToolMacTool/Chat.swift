import Foundation
import SwiftUI
import ToolCore

/// Talks to Ollama (http://127.0.0.1:11434 unless Glass's settings say otherwise).
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
    func chat(model: String, messages: [ChatTurn], contextTokens: Int) -> AsyncThrowingStream<OllamaChunk, Error> {
        struct Body: Encodable {
            struct Options: Encodable { let num_ctx: Int }
            let model: String
            let messages: [ChatTurn]
            let stream = true
            let options: Options
        }
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Body(model: model, messages: messages,
                                                      options: .init(num_ctx: contextTokens)))
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
}

/// The four chats: the same conversation underneath, each tuned for how you talk to it and how
/// it answers. They keep separate conversations and share the model setting and the memory.
enum ChatKind: String, CaseIterable {
    /// Type, read.
    case text
    /// Type; the reply is also spoken.
    case speaks
    /// Talk; the reply is written.
    case listens
    /// Talk, listen: no box to type in.
    case voice

    var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
    var windowID: String { self == .text ? "chat" : "chat\(number)" }
    var speaks: Bool { self == .speaks || self == .voice }
    var listens: Bool { self == .listens || self == .voice }

    /// What the model is told about how its replies reach you, or how your messages reach it.
    var note: String {
        switch self {
        case .text:
            return ""
        case .speaks:
            return "\n\nYour replies are also read aloud, so prefer plain sentences to tables, long lists and symbols."
        case .listens:
            return "\n\nThe user's messages are transcribed from speech and may contain recognition mistakes: "
                + "read them generously, and ask when something is unclear."
        case .voice:
            return "\n\nThis is a spoken conversation: the user talks (transcribed, so allow for recognition mistakes) "
                + "and your reply is read aloud. Answer like a person talking: usually one to three short sentences, "
                + "no lists, headings, tables, code or Markdown, nothing that only makes sense on screen."
        }
    }
}

/// One conversation: what's been said, what's streaming in, the model, and the memory.
@MainActor
final class ChatModel: ObservableObject {
    /// `proposal`: a fact the model suggested remembering, waiting for a yes or no.
    enum Role { case user, assistant, note, proposal }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String
        /// A reply that didn't finish: "stopped" or "failed".
        var note = ""
    }

    enum Phase { case idle, thinking, streaming }

    @Published private(set) var messages: [Message] = []
    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var models: [String] = []
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "chatModel") }
    }
    @Published private(set) var problem: String?
    /// Tokens the last reply read (the whole context sent) and wrote.
    @Published private(set) var usage: (prompt: Int, output: Int)?

    let kind: ChatKind
    let memory: MemoryStore
    let ollama: Ollama
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

    static let system = "You are Glass, an assistant running on the user's own Mac. Keep replies clear and "
        + "fairly short unless asked for more detail."
    /// The context window asked of Ollama, and how much of it is kept for the reply. The
    /// conversation gets what's left after the system message (the oldest turns drop off).
    static let contextTokens = 8192
    static let replyTokens = 2048

    init(kind: ChatKind = .text) {
        self.kind = kind
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = MemoryStore.GlassConfig.load(home: home)
        memory = MemoryStore.forCurrentUser()
        ollama = Ollama(base: URL(string: config.ollama ?? "") ?? URL(string: "http://127.0.0.1:11434")!)
        model = UserDefaults.standard.string(forKey: "chatModel") ?? config.model ?? ""
    }

    var glassFolder: URL { memory.url.deletingLastPathComponent().deletingLastPathComponent() }

    func loadModels() {
        Task {
            do {
                let names = try await ollama.models()
                models = names
                if names.isEmpty {
                    problem = "Ollama has no models yet: run ollama pull llama3.2 in Terminal"
                } else {
                    if !names.contains(model) { model = names[0] }
                    if problem?.hasPrefix("Ollama") == true { problem = nil }
                }
            } catch {
                problem = notRunning
            }
        }
    }

    private var notRunning: String {
        "Ollama isn't running (\(ollama.base.host ?? "")): open the Ollama app, or run ollama serve"
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

    private func reply() {
        let history = messages.compactMap { m -> ChatTurn? in
            switch m.role {
            case .user: return ChatTurn(role: "user", content: m.text)
            case .assistant: return m.text.isEmpty ? nil : ChatTurn(role: "assistant", content: m.text)
            case .note, .proposal: return nil
            }
        }
        let system = ChatTurn(role: "system",
                              content: Self.system + kind.note + "\n\n" + MemoryStore.prompt(memory: memory.read()))
        let budget = ChatTurn.budget(contextTokens: Self.contextTokens, system: system.content,
                                     replyTokens: Self.replyTokens)
        let turns = [system] + ChatTurn.window(history, budget: budget)

        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        phase = .thinking
        turn += 1
        onReplyStart?()
        let mine = turn
        let model = self.model
        task = Task {
            var raw = ""
            var note = ""
            do {
                for try await chunk in ollama.chat(model: model, messages: turns, contextTokens: Self.contextTokens) {
                    guard mine == turn else { break }
                    if let piece = chunk.message?.content, !piece.isEmpty {
                        raw += piece
                        phase = .streaming
                        let shown = MemoryStore.hideTags(raw)
                        update(reply.id, text: shown)
                        onReplyText?(shown)
                    }
                    if chunk.done, let p = chunk.promptTokens {
                        usage = (p, chunk.outputTokens ?? 0)
                    }
                }
                // A stopped stream just ends, without an error.
                if Task.isCancelled { note = "stopped" }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    note = "stopped"
                } else if mine == turn {
                    note = "failed"
                    let code = (error as? URLError)?.code
                    problem = code == .cannotConnectToHost || code == .cannotFindHost
                        ? notRunning : error.localizedDescription
                }
            }
            // A new chat since: this reply is gone, and the next one's state isn't ours to change.
            guard mine == turn else { return }
            finish(reply.id, raw: raw, model: model, note: note)
        }
    }

    func stop() {
        task?.cancel()
    }

    func clearProblem() {
        problem = nil
    }

    func newChat() {
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
        let (shown, facts) = MemoryStore.extract(raw)
        if shown.isEmpty && note == "stopped" {
            // Kept, empty, so it says it was stopped and offers to try again.
            messages[i].note = note
        } else if shown.isEmpty {
            messages.remove(at: i)
        } else {
            messages[i].text = shown
            messages[i].note = note
        }
        // Nothing goes into memory until you say so: a pasted page could otherwise plant
        // instructions there, and memory goes with every message from then on.
        let known = MemoryStore.facts(in: memory.read())
        var offered = Set<String>()
        for fact in facts {
            let clean = fact.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = clean.lowercased()
            if clean.isEmpty || known.contains(key) || !offered.insert(key).inserted { continue }
            messages.append(Message(role: .proposal, text: clean))
        }
        if !shown.isEmpty {
            record(who: model, text: shown, note: note)
        }
        onReplyEnd?(shown, note.isEmpty && shown.isEmpty ? "failed" : note)
    }

    /// Yes to a suggested fact: it's added to MEMORY.md.
    func accept(_ id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].role == .proposal else { return }
        let fact = messages[i].text
        do {
            if try memory.remember(fact) != nil {
                record(who: "memory", text: "_remembered: \(fact)_")
            }
            messages[i] = Message(role: .note, text: "Remembered: \(fact)")
        } catch {
            problem = "Couldn't write MEMORY.md: \(error.localizedDescription)"
        }
    }

    /// No to a suggested fact.
    func dismiss(_ id: UUID) {
        messages.removeAll { $0.id == id && $0.role == .proposal }
    }

    /// Each turn goes into a glass-chat-<time>.md in the Glass folder, like Glass's own chats.
    private func record(who: String, text: String, note: String = "") {
        if transcript == nil { transcript = Transcript(folder: glassFolder) }
        try? transcript?.append(Transcript.block(who: who, text: text, note: note))
    }
}
