import AppKit
import SwiftUI
import ToolCore

/// The panel that drops down from the menu bar icon: the boards across the top, a row under them
/// (Unzip, the battery), columns of titled tile grids under that (the last three: the notes running
/// a timer, the schedules that are on, and the tags' boards), the notes docked along the bottom, and a bar at the bottom for
/// updates, open at login and quit.
struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: Updater

    static let tile: CGFloat = 76
    static let gap: CGFloat = 6
    static let perRow = 4
    static let columns = Array(repeating: GridItem(.fixed(tile), spacing: gap), count: perRow)
    /// One column of sections: four tiles across.
    static let columnWidth: CGFloat = tile * CGFloat(perRow) + gap * CGFloat(perRow - 1)
    /// A bigger tile, for a section stacked in a narrow column of its own (the timers, the tags).
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
            BoardsRow(store: model.boards, groups: model.groups)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
                .padding(.horizontal, 14)
            TopRow(model: model)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
            Divider()
                .padding(.horizontal, 14)
            ToolGrid(model: model)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            DockRow(store: model.boards)
            Divider()
            BottomBar(model: model, updater: updater)
        }
        .frame(width: Self.width)
        .background(WindowReader { MenuPanel.window = $0 })
    }
}

/// The panel that drops down from the menu bar icon, so a button that opens something elsewhere
/// can put it away (it would otherwise sit over what was opened). What it opened is watched: once
/// that's closed again, the panel drops down again, to pick something else (or click away, as
/// usual). The panel opening again some other way, or nothing having opened, ends the watch.
@MainActor
enum MenuPanel {
    static weak var window: NSWindow?

    /// The windows opened from the panel, while they're watched.
    private static var opened: [WeakWindow] = []
    private static var watch: Timer?
    /// Bumped by each close, so only the latest one starts a watch.
    private static var closes = 0
    /// Marks the boards' own icons in the menu bar, so the wrench is told apart from them.
    static let boardItem = NSUserInterfaceItemIdentifier("ToolMacTool.boardItem")

    private struct WeakWindow { weak var window: NSWindow? }

    static func close() {
        guard let window, window.isVisible else { return }
        let before = Set(visibleWindows().map(ObjectIdentifier.init))
        window.close()
        stopWatching()
        closes += 1
        let mine = closes
        // What was clicked opens right after this (some of it a moment later): then see what came up.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard closes == mine, Self.window?.isVisible != true else { return }
            var found = visibleWindows().filter { !before.contains(ObjectIdentifier($0)) }
            // Nothing new: something already open, brought forward (not another app, like Finder).
            if found.isEmpty, NSApp.isActive, let key = NSApp.keyWindow, key.isVisible, key !== Self.window, !isStatusBar(key) {
                found = [key]
            }
            guard !found.isEmpty else { return }
            opened = found.map { WeakWindow(window: $0) }
            let t = Timer(timeInterval: 0.3, repeats: true) { _ in
                Task { @MainActor in check() }
            }
            RunLoop.main.add(t, forMode: .common)
            watch = t
        }
    }

    private static func check() {
        // Dropped down again some other way (the wrench clicked): it's as usual from here.
        if window?.isVisible == true { return stopWatching() }
        let open = opened.contains { $0.window.map { $0.isVisible || $0.isMiniaturized } ?? false }
        guard !open else { return }
        stopWatching()
        reopen()
    }

    private static func stopWatching() {
        watch?.invalidate()
        watch = nil
        opened = []
    }

    /// Drops the panel down again, as a click on the wrench does. Up to macOS 26 that's a click on
    /// its button; from macOS 27 the button does nothing by itself, and the item is asked to begin
    /// its "expanded interface session" instead (private, so only where it answers to it).
    static func reopen() {
        guard window?.isVisible != true, let item = wrench() else { return }
        let begin = NSSelectorFromString("_beginExpandedInterfaceSession:")
        let delegate = NSSelectorFromString("expandedInterfaceDelegate")
        if item.responds(to: begin), item.responds(to: delegate), item.perform(delegate) != nil,
           let imp = item.method(for: begin) {
            // It takes the time of the click that began it, and drops one older than the last
            // session's end: none is older than the end of time.
            typealias Begin = @convention(c) (NSStatusItem, Selector, TimeInterval) -> Void
            unsafeBitCast(imp, to: Begin.self)(item, begin, .greatestFiniteMagnitude)
        } else {
            item.button?.performClick(nil)
        }
    }

    /// The wrench's menu bar item: the one that isn't a board's (nor a copy of it shown on
    /// another display).
    private static func wrench() -> NSStatusItem? {
        let key = NSSelectorFromString("statusItem")
        return NSApp.windows
            .filter { isStatusBar($0) && $0.responds(to: key) }
            .compactMap { $0.value(forKey: "statusItem") as? NSStatusItem }
            .first { $0.button?.identifier != boardItem && !NSStringFromClass(type(of: $0)).contains("Replicant") }
    }

    /// The app's windows on screen, but for the panel and the menu bar's own.
    private static func visibleWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0 !== window && !isStatusBar($0) }
    }

    private static func isStatusBar(_ w: NSWindow) -> Bool {
        NSStringFromClass(type(of: w)).contains("StatusBarWindow")
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
                        SectionGrid(section: section, model: model, groups: model.groups)
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
    /// For the pin at the right of its title.
    var groups: PinnedGroups?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: section.title, color: section.color, groups: groups, pinID: section.id)
            if section.extra == .timedNotes {
                TimedNotesColumn(store: model.boards, color: section.color)
            } else if section.extra == .scheduledJobs {
                ScheduledJobsColumn(scheduler: model.scheduler, color: section.color)
            } else if section.extra == .tagBoards {
                TagBoardsColumn(store: model.boards)
            } else if section.style == .stack {
                VStack(spacing: MenuView.gap) {
                    ForEach(section.tools) { tool in
                        DockableToolTile(tool: tool, color: section.color, big: true, dock: model.toolDock) { model.open(tool) }
                    }
                }
            } else {
                LazyVGrid(columns: MenuView.columns, alignment: .leading, spacing: MenuView.gap) {
                    ForEach(section.tools) { tool in
                        DockableToolTile(tool: tool, color: section.color, dock: model.toolDock) { model.open(tool) }
                    }
                    if section.extra == .chimes {
                        ForEach(ScheduledJob.Builtin.chimes, id: \.self) { b in
                            ChimeTile(builtin: b, scheduler: model.scheduler, color: section.color)
                        }
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
    /// With both: a pin at the right, to float the group on the screen.
    var groups: PinnedGroups? = nil
    var pinID: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(color)
                .lineLimit(1)
            if let groups, let pinID {
                Spacer(minLength: 2)
                GroupPinButton(groups: groups, id: pinID, color: color)
            }
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
    @ObservedObject private var focus = FocusCenter.shared

    var body: some View {
        HStack(spacing: 4) {
            update
            Spacer(minLength: 8)
            ModeSwitch(modes: ModeCenter.shared)
            Spacer(minLength: 8)
            IconButton(symbol: "checkmark.shield", help: "Permissions: check the folders, the microphone and screen recording (macOS asks for each, one at a time)") {
                MenuPanel.close()
                Permissions.shared.show()
            }
            IconButton(symbol: "hammer", help: "Build tools: check and install what building updates here needs") {
                MenuPanel.close()
                BuildToolsWindow.show()
            }
            IconButton(symbol: model.openAtLogin ? "sunrise.fill" : "sunrise",
                       help: model.openAtLogin ? "Opens at login (click to stop)" : "Open at login",
                       tint: model.openAtLogin ? .accentColor : .secondary) {
                model.setOpenAtLogin(!model.openAtLogin)
            }
            if focus.isStrict {
                // Strict focus: nothing in the app ends it (Quit would).
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 24)
                    .help("Strict focus is on: Quit is locked until the battery is empty")
                    .accessibilityLabel("Quit is locked: strict focus is on")
            } else {
                IconButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
            }
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
            .disabled(focus.isStrict)
            .help(focus.isStrict ? "Strict focus is on: updating (which relaunches the app) waits until it's over"
                  : "\(u.commit.short): \(u.commit.title)"
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
            Button("Fix…") {
                MenuPanel.close()
                BuildToolsWindow.show()
            }
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
        // Only an icon shows, so VoiceOver reads the tooltip's first line instead of the symbol's name.
        .accessibilityLabel(help.components(separatedBy: "\n").first ?? help)
    }
}
