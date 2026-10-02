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
        ToolSection(title: "Glass", tools: [chat, memory, prompts, settings]),
        // What the chat's model can do for you (it calls them as tools); each also works by itself.
        ToolSection(title: "Model tools", tools: [diagram, alarm, openLink, clipboard, shortcutTools]),
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
        subtitle: "A floating glass panel to chat with a local model (through Ollama). Type, talk, or both: pick how from its controls. It remembers what matters in MEMORY.md, uses the system prompt you pick (⌘1–⌘9), and knows the date, time and place.",
        symbol: "bubble.left.and.text.bubble.right",
        open: { model in ChatWindow.show(model.chat, link: model.chatLink) })

    static let diagram = Tool(
        id: "diagram",
        name: "Diagram",
        title: "Draw a diagram (Mermaid)",
        subtitle: "Say or type what you want drawn: the model writes it in Mermaid and the app draws it as a network on a big glass canvas, every node an icon picked from its name. Ask for changes and it redraws from the current diagram. The chat's model can open it too (draw_diagram), describing what to draw.",
        symbol: "point.3.connected.trianglepath.dotted",
        open: { model in DiagramWindow.show(model.diagram) })

    static let prompts = Tool(
        id: "prompts",
        name: "Prompts",
        title: "System prompts, memory prompt and personas",
        subtitle: "Up to nine system prompts to pick from in the chat, the prompt that tells the model how to use and keep its memory, and a persona for each voice.",
        symbol: "text.quote",
        open: { _ in PromptsWindow.show() })

    static let alarm = Tool(
        id: "alarm",
        name: "Alarm",
        title: "Alarm (a model tool)",
        subtitle: "The chat's model can sound an alarm for a number of seconds (sound_alarm). Here: turn it on or off, say when it should, and try it.",
        symbol: "alarm",
        open: { _ in ModelToolsWindow.show(.soundAlarm) })

    static let openLink = Tool(
        id: "open-link",
        name: "Open link",
        title: "Open a link (a model tool)",
        subtitle: "The chat's model can open a web page in your browser (open_url), and carry on talking.",
        symbol: "safari",
        open: { _ in ModelToolsWindow.show(.openURL) })

    static let clipboard = Tool(
        id: "clipboard",
        name: "Clipboard",
        title: "Copy to the clipboard (a model tool)",
        subtitle: "The chat's model can put text on your clipboard (copy_to_clipboard), ready to paste.",
        symbol: "doc.on.clipboard",
        open: { _ in ModelToolsWindow.show(.copyText) })

    static let shortcutTools = Tool(
        id: "tools",
        name: "Shortcuts",
        title: "Tools: shortcuts the model can run",
        subtitle: "Pick Apple Shortcuts the chat's model may call, and say when it should call each. Each takes text and gives text back (or nothing).",
        symbol: "bolt.horizontal.circle",
        open: { _ in ToolsWindow.show() })

    static let settings = Tool(
        id: "settings",
        name: "Settings",
        title: "Settings",
        subtitle: "The model and where Ollama is, how the chat starts (mode, prompt, memory), the voice, and the time zone and place the model is told about.",
        symbol: "gearshape",
        open: { _ in SettingsWindow.show() })

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
        subtitle: "View and edit MEMORY.md: what Glass knows about you, sent with every message while memory is on, and kept up to date by the model.",
        symbol: "brain",
        open: { _ in MemoryWindow.show() })
}
