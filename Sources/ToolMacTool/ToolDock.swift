import AppKit
import SwiftUI

/// Tools docked in the menu bar beside the wrench, as boards can be: each its own icon there, a
/// click opens it (its window) without the panel, a right-click takes it out. The tile's menu-bar
/// button (or right-click on the tile) puts it there.
@MainActor
final class ToolDock: ObservableObject {
    private static let key = "menuBarTools"

    @Published private(set) var ids: [String] = UserDefaults.standard.stringArray(forKey: ToolDock.key) ?? []
    private weak var app: AppModel?
    private var items: [String: NSStatusItem] = [:]
    private var targets: [String: StatusTarget] = [:]

    init(app: AppModel) {
        self.app = app
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func set(_ on: Bool, _ id: String) {
        ids.removeAll { $0 == id }
        if on { ids.append(id) }
        UserDefaults.standard.set(ids, forKey: Self.key)
        sync()
    }

    /// The menu bar as `ids` says (at launch, and after each change).
    func sync() {
        let wanted = Set(ids)
        for (id, item) in items where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            items[id] = nil
            targets[id] = nil
        }
        for id in ids where items[id] == nil {
            guard let tool = Tools.sections.flatMap(\.tools).first(where: { $0.id == id }) else { continue }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "ToolMacTool.tool.\(id)"
            let target = StatusTarget { [weak self] in
                guard let app = self?.app else { return }
                app.open(tool)
            }
            target.onRightClick = { [weak self] in self?.set(false, id) }
            if let button = item.button {
                button.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.name)
                button.image?.isTemplate = true
                // Told apart from the wrench, as the boards' icons are.
                button.identifier = MenuPanel.boardItem
                button.toolTip = "\(tool.title): click to open (right-click to take it out of the menu bar)"
                button.target = target
                button.action = #selector(StatusTarget.clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            items[id] = item
            targets[id] = target
        }
    }
}

/// A tool's tile with its menu-bar button: shown in the corner while the pointer is over the
/// tile, and always while the tool is in the menu bar. Right-click does the same.
struct DockableToolTile: View {
    let tool: Tool
    let color: Color
    var big = false
    @ObservedObject var dock: ToolDock
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let on = dock.contains(tool.id)
        ZStack(alignment: .topTrailing) {
            if big {
                BigToolTile(tool: tool, color: color, action: action)
            } else {
                ToolTile(tool: tool, color: color, action: action)
            }
            if hover || on {
                Button { dock.set(!on, tool.id) } label: {
                    Image(systemName: on ? "menubar.arrow.up.rectangle" : "menubar.rectangle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(on ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(on ? "In the menu bar beside the wrench: a click there opens \(tool.name). Click to take it out."
                         : "Put \(tool.name) in the menu bar beside the wrench, to open it with one click")
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open \(tool.name)", action: action)
            Button(on ? "Take out of the menu bar" : "Dock in the menu bar (beside the wrench)") { dock.set(!on, tool.id) }
        }
    }
}
