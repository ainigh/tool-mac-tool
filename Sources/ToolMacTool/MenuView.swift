import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon: a titled grid of tiles per section, the last
/// result, and a bar at the bottom for updates, open at login and quit.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    static let columns = Array(repeating: GridItem(.fixed(76), spacing: 6), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(Tools.sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { Divider().padding(.vertical, 8) }
                    SectionHeader(title: section.title)
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 6) {
                        ForEach(section.tools) { tool in
                            ToolTile(tool: tool, running: model.running.contains(tool.id),
                                     result: model.results[tool.id]) { model.run(tool) }
                        }
                    }
                }
            }
            .padding(12)

            if let last = model.lastResult {
                ResultStrip(tool: last.tool, result: last.result)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Divider()
            BottomBar(model: model, updater: updater)
        }
        .frame(width: 12 + 4 * 76 + 3 * 6 + 12)
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .padding(.bottom, 6)
    }
}

/// A square tile: the tool's icon, its name under it, a spinner while it runs and a small badge
/// for how it last went. Hover for the full name and what it does.
struct ToolTile: View {
    let tool: Tool
    let running: Bool
    let result: AppModel.Result?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.gradient)
                        if running {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: tool.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 40, height: 40)
                    if let result, !running {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, result.ok ? Color.green : Color.orange)
                            .offset(x: 5, y: -5)
                    }
                }
                Text(tool.name)
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .top)
            }
            .frame(width: 76, height: 84)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .onHover { hover = $0 }
        .help("\(tool.title)\n\n\(tool.subtitle)")
    }
}

/// How the most recent run went, under the grid.
struct ResultStrip: View {
    let tool: Tool
    let result: AppModel.Result

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.caption).fontWeight(.semibold)
                Text(result.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let reveal = result.reveal {
                IconButton(symbol: "folder", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([reveal])
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// Updates on the left; open at login and quit on the right.
struct BottomBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(spacing: 4) {
            update
            Spacer(minLength: 8)
            IconButton(symbol: model.openAtLogin ? "sunrise.fill" : "sunrise",
                       help: model.openAtLogin ? "Opens at login (click to stop)" : "Open at login",
                       tint: model.openAtLogin ? .accentColor : .secondary) {
                model.setOpenAtLogin(!model.openAtLogin)
            }
            IconButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var update: some View {
        let version = "v\(Updater.currentVersion)" + (Updater.currentCommit.map { " · \($0.prefix(7))" } ?? "")
        switch updater.state {
        case .available(let u):
            Button {
                updater.install()
            } label: {
                Label(u.release.map { "Update to \($0.tag)" } ?? "Update (build here)", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("\(u.commit.short): \(u.commit.title)"
                  + (u.release == nil ? "\n\nGitHub hasn't built it, so it's built here (a minute or two)." : ""))
        case .installing(let step):
            ProgressView().controlSize(.mini)
            Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .checking:
            ProgressView().controlSize(.mini)
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            IconButton(symbol: "exclamationmark.arrow.circlepath", help: "Check for updates\n\n\(why)", tint: .orange) {
                updater.check(userInitiated: true)
            }
            Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(why)
        case .upToDate, .idle:
            IconButton(symbol: "arrow.clockwise", help: "Check for updates") { updater.check(userInitiated: true) }
            Text(updater.state == .upToDate ? "Up to date · \(version)" : version)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
        }
    }
}

/// A small borderless icon button with a hover highlight and a tooltip.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}
