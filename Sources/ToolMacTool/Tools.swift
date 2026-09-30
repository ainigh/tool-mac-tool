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
        ToolSection(title: "Glass", tools: [chat, memory]),
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
        subtitle: "A floating glass panel to chat with a local model (through Ollama). It remembers what you ask it to, in MEMORY.md.",
        symbol: "bubble.left.and.text.bubble.right",
        open: { model in ChatWindow.show(model.chat) })

    static let memory = Tool(
        id: "memory",
        name: "Memory",
        title: "Glass's memory",
        subtitle: "View and edit MEMORY.md: what Glass knows about you, sent with every message.",
        symbol: "brain",
        open: { _ in MemoryWindow.show() })
}
