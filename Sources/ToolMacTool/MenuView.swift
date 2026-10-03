import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon: a titled grid of tiles per section, the last
/// result, and a bar at the bottom for updates, open at login and quit.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    static let tile: CGFloat = 76
    static let gap: CGFloat = 6
    static let perRow = 4
    static let columns = Array(repeating: GridItem(.fixed(tile), spacing: gap), count: perRow)
    static let width: CGFloat = 12 + tile * CGFloat(perRow) + gap * CGFloat(perRow - 1) + 12

    var body: some View {
        VStack(spacing: 0) {
            ToolGrid(model: model).padding(12)
            Divider()
            BottomBar(model: model, updater: updater)
        }
        .frame(width: Self.width)
    }
}

/// Every section: its title, its tiles, and a divider before the next one.
struct ToolGrid: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Tools.sections) { section in
                if section.id != Tools.sections.first?.id {
                    Divider().padding(.vertical, 8)
                }
                SectionGrid(section: section, model: model)
            }
        }
    }
}

struct SectionGrid: View {
    let section: ToolSection
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: section.title, color: section.color)
            LazyVGrid(columns: MenuView.columns, alignment: .leading, spacing: MenuView.gap) {
                ForEach(section.tools) { tool in
                    ToolTile(tool: tool, color: section.color) { model.open(tool) }
                }
            }
            if section.extra == .recentZips {
                RecentZipsList(zips: model.zips)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(color)
        }
        .padding(.leading, 2)
        .padding(.bottom, 6)
    }
}

/// A square tile: the tool's icon and its name under it. Hover for the full name and what it does.
struct ToolTile: View {
    let tool: Tool
    /// Its section's color.
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.gradient)
                    Image(systemName: tool.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .scaleEffect(hover ? 1.06 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                Text(tool.name)
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .top)
            }
            .frame(width: MenuView.tile, height: 84)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? color.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(tool.title)\n\n\(tool.subtitle)")
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
            IconButton(symbol: "hammer", help: "Build tools: check and install what building updates here needs") {
                BuildToolsWindow.show()
            }
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
            + (Updater.branch == "main" ? "" : " · \(Updater.branch)")
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
            IconButton(symbol: "doc.on.doc", help: "Copy the error (with the build log, if it built)") {
                Clipboard.copy(Updater.report(why))
            }
            Button("Fix…") { BuildToolsWindow.show() }
                .controlSize(.small)
                .help("Check and install what building updates here needs")
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
