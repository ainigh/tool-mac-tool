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

    /// The reply, streamed a piece at a time.
    func chat(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<OllamaChunk, Error> {
        struct Body: Encodable {
            let model: String
            let messages: [ChatTurn]
            let stream = true
        }
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Body(model: model, messages: messages))
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

/// One conversation: what's been said, what's streaming in, the model, and the memory.
@MainActor
final class ChatModel: ObservableObject {
    enum Role { case user, assistant, note }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        var role: Role
        var text: String
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

    let memory: MemoryStore
    let ollama: Ollama
    private var transcript: Transcript?
    private var task: Task<Void, Never>?

    static let system = "You are Glass, an assistant running on the user's own Mac. Keep replies clear and "
        + "fairly short unless asked for more detail."
    /// How much of the conversation goes with each message (characters; the oldest turns drop off).
    static let historyBudget = 16_000

    init() {
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
                problem = "Ollama isn't running (\(ollama.base.host ?? "")): open the Ollama app, or run ollama serve"
            }
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .idle else { return }
        guard !model.isEmpty else {
            problem = "Pick a model first (Ollama needs at least one: ollama pull llama3.2)"
            loadModels()
            return
        }
        input = ""
        problem = nil
        messages.append(Message(role: .user, text: text))
        record(who: "you", text: text)

        let history = messages.compactMap { m -> ChatTurn? in
            switch m.role {
            case .user: return ChatTurn(role: "user", content: m.text)
            case .assistant: return m.text.isEmpty ? nil : ChatTurn(role: "assistant", content: m.text)
            case .note: return nil
            }
        }
        let system = ChatTurn(role: "system", content: Self.system + "\n\n" + MemoryStore.prompt(memory: memory.read()))
        let turns = [system] + ChatTurn.window(history, budget: Self.historyBudget)

        let reply = Message(role: .assistant, text: "")
        messages.append(reply)
        phase = .thinking
        let model = self.model
        task = Task {
            var raw = ""
            var note = ""
            do {
                for try await chunk in ollama.chat(model: model, messages: turns) {
                    if let piece = chunk.message?.content, !piece.isEmpty {
                        raw += piece
                        phase = .streaming
                        update(reply.id, text: MemoryStore.hideTags(raw))
                    }
                    if chunk.done, let p = chunk.promptTokens {
                        usage = (p, chunk.outputTokens ?? 0)
                    }
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    note = "stopped"
                } else {
                    note = "failed"
                    problem = error.localizedDescription
                }
            }
            finish(reply.id, raw: raw, model: model, note: note)
        }
    }

    func stop() {
        task?.cancel()
    }

    func newChat() {
        task?.cancel()
        task = nil
        messages = []
        transcript = nil
        usage = nil
        phase = .idle
    }

    // MARK: -

    private func update(_ id: UUID, text: String) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].text = text }
    }

    private func finish(_ id: UUID, raw: String, model: String, note: String) {
        phase = .idle
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }     // a new chat since
        let (shown, facts) = MemoryStore.extract(raw)
        if shown.isEmpty {
            messages.remove(at: i)
        } else {
            messages[i].text = shown
        }
        var remembered: [String] = []
        for fact in facts {
            // nil: already remembered, or it couldn't be written
            if (try? memory.remember(fact)) != nil { remembered.append(fact) }
        }
        for fact in remembered {
            messages.append(Message(role: .note, text: "Remembered: \(fact)"))
        }
        if !shown.isEmpty {
            let extra = remembered.map { "\n\n_remembered: \($0)_" }.joined()
            record(who: model, text: shown + extra, note: note)
        }
    }

    /// Each turn goes into a glass-chat-<time>.md in the Glass folder, like Glass's own chats.
    private func record(who: String, text: String, note: String = "") {
        if transcript == nil { transcript = Transcript(folder: glassFolder) }
        try? transcript?.append(Transcript.block(who: who, text: text, note: note))
    }
}
