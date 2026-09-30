import Foundation
import ToolCore

/// One tile in the panel. To add a tool: write its logic in ToolCore (so it can be tested), then
/// add a `Tool` below and put it in a section of `Tools.sections`.
struct Tool: Identifiable {
    let id: String
    /// The tile's label: a word or two.
    let name: String
    /// The full name, shown when you hover and in the result card.
    let title: String
    /// What it does, shown when you hover.
    let subtitle: String
    /// An SF Symbol name (see the SF Symbols app).
    let symbol: String
    /// Does the work, off the main thread. Throw to report a problem; the message is shown as is.
    let run: @Sendable () throws -> ToolOutcome
}

struct ToolOutcome {
    var message: String
    /// Shown by the "Show in Finder" button.
    var reveal: URL?
}

struct ToolSection: Identifiable {
    let title: String
    let tools: [Tool]
    var id: String { title }
}

enum Tools {
    /// The panel, top to bottom: each section is a titled grid of tiles.
    static let sections: [ToolSection] = [
        ToolSection(title: "Files", tools: [unzipLatestDownload]),
    ]

    static var all: [Tool] { sections.flatMap(\.tools) }

    static let unzipLatestDownload = Tool(
        id: "unzip-latest-download",
        name: "Unzip to Desktop",
        title: "Unzip latest download to Desktop",
        subtitle: "Takes the newest file in Downloads (it must be a .zip) and moves what's in it into the matching Desktop folder",
        symbol: "doc.zipper",
        run: {
            let report = try ZipToDesktop.forCurrentUser().run()
            return ToolOutcome(message: report.summary, reveal: report.target)
        })
}
