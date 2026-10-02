import AppKit

/// One tile in the panel. Clicking it opens the tool's window. To add a tool: write its logic in
/// ToolCore (so it can be tested), give it a view, then add a `Tool` below and put it in a section
/// of `Tools.sections`.
struct Tool: Identifiable {
    let id: String
    /// The tile's label: a word or two.
    let name: String
    /// The full name, shown when you hover.
    let title: String
    /// What it does, shown when you hover.
    let subtitle: String
    /// An SF Symbol name (see the SF Symbols app).
    let symbol: String
    /// What clicking the tile does (usually: open its window).
    let open: @MainActor (AppModel) -> Void
}

struct ToolSection: Identifiable {
    enum Extra { case recentZips }

    let title: String
    let tools: [Tool]
    /// Something shown under the tiles, for quick use without opening a window.
    var extra: Extra? = nil
    var id: String { title }
}

enum Tools {
    /// The panel, top to bottom: each section is a titled grid of tiles.
    static let sections: [ToolSection] = [
        ToolSection(title: "Files", tools: [unzip], extra: .recentZips),
        ToolSection(title: "Voice", tools: [readAloud, dictate, transcribe]),
        ToolSection(title: "Glass", tools: [chat, chat2, chat3, chat4, memory]),
    ]

    static var all: [Tool] { sections.flatMap(\.tools) }

    static let unzip = Tool(
        id: "unzip-to-desktop",
        name: "Unzip to Desktop",
        title: "Unzip downloads to Desktop",
        subtitle: "Zips downloaded in the last 10 minutes are listed under the tiles: click one to move what's in it into its matching Desktop folder. The tile opens the full list.",
        symbol: "doc.zipper",
        open: { model in
            Windows.show("zips", title: "Recent zips", size: NSSize(width: 620, height: 460)) {
                ZipWindow(zips: model.zips)
            }
        })

    static let chat = Tool(
        id: "chat",
        name: "Chat",
        title: "Chat with Glass",
        subtitle: "A floating glass panel to chat with a local model (through Ollama), by typing. It remembers what you ask it to, in MEMORY.md, which all four chats share.",
        symbol: "bubble.left.and.text.bubble.right",
        open: { model in ChatWindow.show(model.chat) })

    static let chat2 = Tool(
        id: "chat2",
        name: "Chat 2",
        title: "Chat 2: it talks back",
        subtitle: "Type, and the reply is read aloud as it comes in, a sentence at a time. Mute it from the speaker button.",
        symbol: "speaker.wave.2.bubble.left",
        open: { model in openChat(.speaks, model) })

    static let chat3 = Tool(
        id: "chat3",
        name: "Chat 3",
        title: "Chat 3: it listens",
        subtitle: "Press the mic and talk instead of typing: your words fill the box and are sent when you pause. Replies are written.",
        symbol: "mic.badge.plus",
        open: { model in openChat(.listens, model) })

    static let chat4 = Tool(
        id: "chat4",
        name: "Chat 4",
        title: "Chat 4: talk and listen",
        subtitle: "A spoken conversation with nothing to type in: it listens, answers out loud in a few sentences, and listens again. Click or press space to interrupt.",
        symbol: "waveform.and.mic",
        open: { model in
            let (chat, link) = model.conversation(.voice)
            if let link { VoiceChatWindow.show(chat, link: link) }
        })

    @MainActor
    static func openChat(_ kind: ChatKind, _ model: AppModel) {
        let (chat, link) = model.conversation(kind)
        ChatWindow.show(chat, link: link)
    }

    static let readAloud = Tool(
        id: "read-aloud",
        name: "Read aloud",
        title: "Read aloud (text to speech)",
        subtitle: "Paste or type text and it's read out, the word being said lit up. Pick the voice and speed, or save it as audio.",
        symbol: "text.bubble",
        open: { model in ReadAloudWindow.show(model.speaker) })

    static let dictate = Tool(
        id: "dictate",
        name: "Dictate",
        title: "Dictate notes (speech to text)",
        subtitle: "Talk and it's written down, as long as you like. Edit, copy, or keep it with Glass's dictations (glass-dictation-<date>.md).",
        symbol: "mic",
        open: { model in DictateWindow.show(model.listener) })

    static let transcribe = Tool(
        id: "transcribe",
        name: "Transcribe",
        title: "Transcribe an audio file",
        subtitle: "Drop an audio file (mp3, m4a, wav…) to get its transcript, timed. Copy it, or save it as text or subtitles (.srt, .vtt).",
        symbol: "waveform",
        open: { model in TranscribeWindow.show(model.transcriber) })

    static let memory = Tool(
        id: "memory",
        name: "Memory",
        title: "Glass's memory",
        subtitle: "View and edit MEMORY.md: what Glass knows about you, sent with every message.",
        symbol: "brain",
        open: { _ in MemoryWindow.show() })
}
