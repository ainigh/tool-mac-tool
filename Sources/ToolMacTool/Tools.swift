import Foundation
import ToolCore

/// One entry in the menu. To add a tool: write its logic in ToolCore (so it can be tested), then add
/// a `Tool` here and put it in `Tools.all`.
struct Tool: Identifiable {
    let id: String
    let title: String
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

enum Tools {
    static let all: [Tool] = [unzipLatestDownload]

    static let unzipLatestDownload = Tool(
        id: "unzip-latest-download",
        title: "Unzip latest download to Desktop",
        subtitle: "Newest file in Downloads (a .zip) → into its matching Desktop folder",
        symbol: "doc.zipper",
        run: {
            let report = try ZipToDesktop.forCurrentUser().run()
            return ToolOutcome(message: report.summary, reveal: report.target)
        })
}
