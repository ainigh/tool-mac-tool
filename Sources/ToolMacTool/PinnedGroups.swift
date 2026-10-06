import AppKit
import SwiftUI
import ToolCore

// Any group of the panel (Boards, Files, Automate, Voice, Record, Glass, Model tools, Timers,
// Tags) can be pinned, as a note can: it floats on the screen in a window of its own, above other
// windows, with the same tiles working as they do in the panel. The pin is at the right of each
// group's title; the pinned ones come back after a relaunch.

@MainActor
final class PinnedGroups: ObservableObject {
    /// The pinned groups' ids (a section's title, or "Boards").
    @Published private(set) var pinned: [String]

    private unowned let app: AppModel
    private var panels: [String: GlassPanel] = [:]
    private static let key = "pinnedGroups"
    static let boardsID = "Boards"

    init(app: AppModel) {
        self.app = app
        pinned = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    /// Every group that can be pinned.
    static var ids: [String] { [boardsID] + Tools.sections.map(\.id) }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    func toggle(_ id: String) { set(!isPinned(id), id) }

    func set(_ on: Bool, _ id: String) {
        pinned.removeAll { $0 == id }
        if on { pinned.append(id) }
        UserDefaults.standard.set(pinned, forKey: Self.key)
        if on { show(id) } else { panels[id]?.orderOut(nil) }
    }

    /// The pinned groups back on the screen, once the app has finished starting up.
    func restore() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            for id in self.pinned where Self.ids.contains(id) { self.show(id) }
        }
    }

    private func show(_ id: String) {
        if let panel = panels[id] {
            panel.orderFrontRegardless()
            return
        }
        let panel = GlassPanel(size: NSSize(width: 360, height: 200))
        panel.level = .floating
        panel.hasShadow = true
        panel.dragsAnywhere = true
        let host = FirstClickHostingView(rootView: PinnedGroupView(id: id, app: app, groups: self))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.commands = ["w": { [weak self] in self?.set(false, id) }]
        let name = "ToolMacTool.group.\(id)"
        if !panel.setFrameUsingName(name), let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            // Down the left of the screen, each new one a little in from the last.
            let n = CGFloat(panels.count % 8)
            panel.setFrameOrigin(NSPoint(x: v.minX + 24 + n * 26, y: v.maxY - panel.frame.height - 24 - n * 26))
        }
        panel.setFrameAutosaveName(name)
        panels[id] = panel
        panel.orderFrontRegardless()
    }
}

/// A pinned group: the same title and tiles as in the panel, on a frosted card.
struct PinnedGroupView: View {
    let id: String
    @ObservedObject var app: AppModel
    @ObservedObject var groups: PinnedGroups

    var body: some View {
        Group {
            if id == PinnedGroups.boardsID {
                BoardsRow(store: app.boards, groups: groups)
                    .frame(width: 10 * 74 + 9 * MenuView.gap)
            } else if let section = Tools.sections.first(where: { $0.id == id }) {
                SectionGrid(section: section, model: app, groups: groups)
                    .frame(width: section.style == .stack ? MenuView.bigTile : MenuView.columnWidth, alignment: .leading)
            } else {
                Text("This group is gone").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .padding(1)
        .fixedSize()
    }
}

/// The pin at the right of a group's title: floats the group on the screen, or puts it back.
struct GroupPinButton: View {
    @ObservedObject var groups: PinnedGroups
    let id: String
    let color: Color
    @State private var hover = false

    var body: some View {
        let on = groups.isPinned(id)
        Button { groups.toggle(id) } label: {
            Image(systemName: on ? "pin.fill" : "pin")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(on ? color : Color.secondary.opacity(hover ? 1 : 0.45))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(on ? "Unpin: put this group's floating window away (⌘W on it does too)"
                 : "Pin: float this group on your screen, above other windows (drag it anywhere to move it)")
    }
}
