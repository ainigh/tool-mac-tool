import AppKit
import SwiftUI

/// The panel that drops down from the menu bar icon: a row across the top (Unzip, the battery,
/// the next alarm), columns of titled tile grids under it, and a bar at the bottom for updates,
/// open at login and quit.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    static let tile: CGFloat = 76
    static let gap: CGFloat = 6
    static let perRow = 4
    static let columns = Array(repeating: GridItem(.fixed(tile), spacing: gap), count: perRow)
    /// One column of sections: four tiles across.
    static let columnWidth: CGFloat = tile * CGFloat(perRow) + gap * CGFloat(perRow - 1)
    /// A bigger tile, for a section stacked in a narrow column of its own (the boards).
    static let bigTile: CGFloat = 96
    /// The columns side by side, a hairline between them (14 points either side), so the panel
    /// stays short.
    static var width: CGFloat {
        let columns = Tools.columns.map(width(of:)).reduce(0, +)
        return 14 + columns + 29 * CGFloat(Tools.columns.count - 1) + 14
    }

    /// A column of stacked sections is one big tile wide; the others four tiles.
    static func width(of column: [ToolSection]) -> CGFloat {
        column.allSatisfy { $0.style == .stack } ? bigTile : columnWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            TopRow(model: model)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
                .padding(.horizontal, 14)
            ToolGrid(model: model)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
            BottomBar(model: model, updater: updater)
        }
        .frame(width: Self.width)
    }
}

/// The sections in columns: in each, its title, its tiles, and a divider before the next one.
struct ToolGrid: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(Tools.columns.enumerated()), id: \.offset) { i, column in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(column) { section in
                        if section.id != column.first?.id {
                            Divider().padding(.vertical, 8)
                        }
                        SectionGrid(section: section, model: model)
                    }
                }
                .frame(width: MenuView.width(of: column), alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SectionGrid: View {
    let section: ToolSection
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: section.title, color: section.color)
            if section.extra == .timers {
                TimerGrid(board: model.timers, model: model, color: section.color)
            } else if section.style == .stack {
                VStack(spacing: MenuView.gap) {
                    ForEach(section.tools) { tool in
                        BigToolTile(tool: tool, color: section.color) { model.open(tool) }
                    }
                }
            } else {
                LazyVGrid(columns: MenuView.columns, alignment: .leading, spacing: MenuView.gap) {
                    ForEach(section.tools) { tool in
                        ToolTile(tool: tool, color: section.color) { model.open(tool) }
                    }
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
                    .font(.system(size: 10.5, weight: hover ? .medium : .regular))
                    .foregroundStyle(hover ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .top)
            }
            .frame(width: MenuView.tile, height: 84)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? color.opacity(0.14) : .clear))
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("\(tool.title)\n\n\(tool.subtitle)")
    }
}

/// A bigger tile, for the stacked sections: the same as `ToolTile`, a size up.
struct BigToolTile: View {
    let tool: Tool
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(color.gradient)
                    Image(systemName: tool.symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                .scaleEffect(hover ? 1.06 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                Text(tool.name)
                    .font(.system(size: 12, weight: hover ? .semibold : .medium))
                    .foregroundStyle(hover ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            .frame(width: MenuView.bigTile, height: 100)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hover ? color.opacity(0.14) : .clear))
        }
        .buttonStyle(PressStyle())
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

/// A plain button that sinks a little while pressed, so a click is felt.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
