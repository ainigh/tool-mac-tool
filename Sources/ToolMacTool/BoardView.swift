import AppKit
import SwiftUI
import ToolCore
import UniformTypeIdentifiers

/// The boards (the Daily plan, the ten the app comes with and the ones named on the Boards grid):
/// each a big glass panel of boxes (notes) to type into, kept in
/// ~/Library/Application Support/ToolMacTool/boards/<id>.json. The Boards grid is one too, its
/// boxes the boards themselves (`BoardCard`).
@MainActor
enum BoardWindow {
    static func id(_ board: String) -> String { "board-\(board)" }

    static func show(_ store: BoardStore, _ board: BoardStore.Kind, focus: Int? = nil) {
        let model = store.model(board)
        if let focus, model.board.boxes.indices.contains(focus) {
            model.board.reveal(focus)
            model.expanded = focus
        }
        let id = Self.id(board.id)
        Windows.show(id) {
            let screen = Windows.visibleFrame
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size, resizable: true)
            panel.minSize = NSSize(width: 640, height: 440)
            let close = { panel.orderOut(nil) }
            let host = FirstClickHostingView(rootView: BoardView(model: model, store: store, board: board, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close]
            // Esc puts an opened box back in the grid (it doesn't close the board: you type here).
            panel.onEscape = {
                guard model.expanded != nil else { return false }
                withAnimation(.easeInOut(duration: 0.2)) { model.expanded = nil }
                return true
            }
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        if let panel = Windows.window(id) { GlassPanel.fit(panel) }
    }
}

/// One board, saved a moment after each change.
@MainActor
final class BoardModel: ObservableObject {
    @Published var board: Board {
        didSet {
            if board != oldValue {
                scheduleSave()
                onChange?()
            }
        }
    }
    /// Told after each change (the store keeps its summaries of the notes up to date).
    var onChange: (() -> Void)?
    /// The box opened to fill the board, if one is.
    @Published var expanded: Int?
    @Published private(set) var problem: String?

    private let url: URL
    private var saveTask: Task<Void, Never>?

    /// `fresh`: the board it starts as when there's no file yet.
    init(id: String, fresh: Board = Board()) {
        url = Board.url(for: id)
        board = FileManager.default.fileExists(atPath: url.path) ? Board.load(from: url) : fresh
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try self.board.save(to: self.url)
                self.problem = nil
            } catch {
                self.problem = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
}

/// The glass panel: the board's name at the top (its icon a click to change), and in the middle of
/// the top, fewer and more either side of: show every note with text, in 2 rows, colors. The boxes
/// fill the middle in their order, some spanning more blocks (or one box, opened to fill it all),
/// and a line of hints at the bottom.
struct BoardView: View {
    @ObservedObject var model: BoardModel
    let store: BoardStore
    let board: BoardStore.Kind
    let close: () -> Void
    @State private var clock = GlassClock()
    @Environment(\.controlActiveState) private var active
    /// The box being dragged to a new place, and the last box whose place it took.
    @State private var moving: Int?
    @State private var lastTarget: Int?
    /// The box being resized, and the size it would take.
    @State private var sizing: Sizing?
    /// The grid's size, for laying it out from the buttons at the top (colors) and a double-click.
    @State private var gridSize = CGSize(width: 1000, height: 700)
    @State private var picking = false

    struct Sizing: Equatable {
        let box: Int
        var across: Int
        var down: Int
    }

    var body: some View {
        let shown = model.board.shown
        VStack(spacing: 0) {
            header(shown)
            GeometryReader { geo in
                Group {
                    if let e = model.expanded, model.board.isShown(e) {
                        box(e, count: 1)
                    } else {
                        grid(size: geo.size, origin: geo.frame(in: .global).origin)
                    }
                }
                .onAppear { gridSize = geo.size }
                .onChange(of: geo.size) { _, size in gridSize = size }
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            footer
        }
        .background(GlassCard(clock: clock, mood: .idle, paused: active == .inactive, radius: 30))
        .environment(\.colorScheme, .dark)
        .onChange(of: shown) { _, _ in
            if let e = model.expanded, !model.board.isShown(e) { model.expanded = nil }
        }
    }

    private func header(_ shown: Int) -> some View {
        HStack(spacing: 10) {
            if board.isGrid {
                Image(systemName: board.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.06)))
            } else {
                boardIcon
            }
            Text(board.name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            BoardHeaderCount(store: store, board: board, shown: shown, problem: model.problem)
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            if !board.isGrid { FocusButton(focus: FocusCenter.shared, board: board) }
            MenuBarDockButton(store: store, id: board.id, name: board.name)
            GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
        }
        .overlay { arrangeBar(shown) }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// The board's icon, top left: a click picks another.
    private var boardIcon: some View {
        Button { picking.toggle() } label: {
            Image(systemName: board.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(picking ? 0.18 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("\(board.name)'s icon: click to pick another")
        .accessibilityLabel("\(board.name)'s icon")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            IconPicker(current: board.symbol, board: board, forBoard: true) { picked in
                store.setIcon(picked, for: board)
                picking = false
            }
        }
    }

    /// In the middle of the top: fewer, then show every note with text, in 2 rows, colors, then
    /// more. Each puts back a box opened to fill the board first, to show the grid it changes.
    private func arrangeBar(_ shown: Int) -> some View {
        let twoRows = model.board.rows == 2
        let what = board.isGrid ? "boards" : "notes"
        return HStack(spacing: 6) {
            GlassIcon(symbol: "chevron.left", help: board.isGrid ? "Fewer boards (their notes are kept)" : "Fewer boxes (their text is kept)") {
                arranging { model.board.fewer() }
            }
            .disabled(shown <= Board.minBoxes)
            GlassIcon(symbol: "text.below.photo",
                      help: board.isGrid ? "Show every board with notes or a name, and hide the blank ones"
                                         : "Show every note with text, and hide the empty ones") {
                arranging {
                    if board.isGrid {
                        let kinds = BoardStore.gridKinds
                        let kept = Set(kinds.indices.filter { !store.isBlank(kinds[$0]) })
                        model.board.showOnly { kept.contains($0) }
                    } else {
                        model.board.showWritten()
                    }
                }
            }
            GlassIcon(symbol: twoRows ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                      help: twoRows ? "In 2 rows: click to fill the board as it fits best again"
                                    : "Arrange the \(what) shown in 2 rows (each one block)") {
                arranging { model.board.arrange(rows: twoRows ? nil : 2) }
            }
            .background(Circle().fill(.white.opacity(twoRows ? 0.16 : 0)))
            GlassIcon(symbol: "paintpalette", help: "Color the \(what) shown, each a different color from the ones beside it") {
                arranging { model.board.colorize(width: gridSize.width, height: gridSize.height) }
            }
            GlassIcon(symbol: "chevron.right", help: board.isGrid ? "More boards (a blank one comes next, to name)" : "More boxes") {
                arranging { model.board.more() }
            }
            .disabled(shown >= Board.maxBoxes)
        }
        .padding(.horizontal, 6)
        .background(Capsule().fill(.black.opacity(0.18)))
    }

    /// A change to the grid from the top: a box opened to fill the board goes back first.
    private func arranging(_ change: () -> Void) {
        withAnimation(.easeInOut(duration: 0.22)) {
            model.expanded = nil
            change()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // One line, cut short to fit: the whole of it shows on hover.
            let hint = board.isGrid ? Self.gridHint : Self.notesHint
            Text(hint)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(hint)
            Spacer(minLength: 8)
            // The keys keep their words whole; the hint gives way.
            if model.expanded != nil { KeyHint(key: "esc", does: "back to the grid").fixedSize() }
            KeyHint(key: "⌘W", does: "close").fixedSize()
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 26)
        .padding(.vertical, 10)
    }

    private static let gridHint = "Every board, as a card. Type its name (first line) and what it's for (second line); click its icon to pick another. The notes listed under them are the board's own (a click opens one). The board's button at the bottom opens it. Top middle: fewer, show the boards with notes, 2 rows, colors, more (a blank board to name). Double-click a card to change its color; drag it to move it, its corner to resize it. Boards with notes show at the top of the panel, the one opened last first."

    private static let notesHint = "Top middle: fewer, show the notes with text, 2 rows, colors, more. Double-click a box to change its color. Drag it anywhere to move it (⌥-drag selects text), its bottom right corner to resize it. Down its left: its icon, and a timer or a due date (one per box). Top left: Daily (or only Mornings, Afternoons or Evenings), Weekly or Monthly (a reminder every hour until it's done; each day, week or month begins at 8 AM the day before). Bottom left: To do, Pending, Completed; bottom right: its tags. Down its top right: copy, open it, the menu bar, dock it in the panel, or pin it to float on your screen. Above its bottom: its board, the notes it links to, and + to link another. Paste a web address to see its page (a YouTube video plays here)."

    /// The shown boxes in their order, each in its place (a big one spanning blocks). Drag a box
    /// anywhere (its text too) to move it to another's place; drag its corner to resize it.
    /// `origin`: where the grid is in the window, as the drags report the pointer there.
    private func grid(size: CGSize, origin: CGPoint) -> some View {
        let shown = model.board.shown
        let gap = CGFloat(Board.gutter(for: shown)) + 2
        let layout = model.board.layout(width: size.width, height: size.height)
        let block = CGSize(width: (size.width + gap) / CGFloat(layout.across), height: (size.height + gap) / CGFloat(layout.down))
        return ZStack(alignment: .topLeading) {
            ForEach(layout.cells, id: \.box) { cell in
                let frame = Self.frame(cell, size: size, gap: gap)
                let lifted = moving == cell.box || sizing?.box == cell.box
                box(cell.box, count: shown, arrange: arrange(cell.box, size: size, origin: origin, gap: gap, block: block))
                    .frame(width: frame.width, height: frame.height)
                    .overlay(alignment: .topLeading) {
                        if let s = sizing, s.box == cell.box {
                            SizeOutline(across: s.across, down: s.down)
                                .frame(width: CGFloat(s.across) * block.width - gap, height: CGFloat(s.down) * block.height - gap)
                        }
                    }
                    .scaleEffect(moving == cell.box ? 1.03 : 1)
                    .opacity(moving == cell.box ? 0.85 : 1)
                    .zIndex(lifted ? 1 : 0)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// A cell's frame in points, a gutter between it and its neighbours.
    static func frame(_ cell: Board.Cell, size: CGSize, gap: CGFloat) -> CGRect {
        let w = size.width + gap, h = size.height + gap
        return CGRect(x: CGFloat(cell.x) * w, y: CGFloat(cell.y) * h,
                      width: CGFloat(cell.width) * w - gap, height: CGFloat(cell.height) * h - gap)
    }

    /// Moving and resizing a box on the grid.
    private func arrange(_ i: Int, size: CGSize, origin: CGPoint, gap: CGFloat, block: CGSize) -> BoxArrange {
        BoxArrange(
            move: { pointer in
                moving = i
                // The board as it is now (it changes as the box takes other places).
                let point = CGPoint(x: pointer.x - origin.x, y: pointer.y - origin.y)
                let x = Double((point.x + gap / 2) / (size.width + gap)), y = Double((point.y + gap / 2) / (size.height + gap))
                guard let target = model.board.layout(width: size.width, height: size.height).cells
                    .first(where: { $0.contains(x: x, y: y) })?.box else { return }
                if target == i {
                    lastTarget = nil
                } else if target != lastTarget {
                    lastTarget = target
                    withAnimation(.easeInOut(duration: 0.2)) { model.board.move(i, to: target) }
                }
            },
            moved: {
                withAnimation(.easeOut(duration: 0.15)) { moving = nil }
                lastTarget = nil
            },
            resize: { drag in
                let box = model.board.boxes[i]
                let across = min(max(box.across + Int((drag.width / block.width).rounded()), 1), Board.maxSpan)
                let down = min(max(box.down + Int((drag.height / block.height).rounded()), 1), Board.maxSpan)
                let s = Sizing(box: i, across: across, down: down)
                if sizing != s { sizing = s }
            },
            resized: {
                guard let s = sizing else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.board.resize(i, across: s.across, down: s.down)
                    sizing = nil
                }
            },
            reset: {
                withAnimation(.easeInOut(duration: 0.2)) { model.board.resize(i, across: 1, down: 1) }
            },
            nextTint: { model.board.nextTint(for: i, width: size.width, height: size.height) })
    }

    @ViewBuilder
    private func box(_ i: Int, count: Int, arrange: BoxArrange? = nil) -> some View {
        let open = model.expanded == i
        let fontSize: CGFloat = open ? 18 : count <= 4 ? 16 : count <= 9 ? 15 : count <= 16 ? 14 : 13
        let toggle = { withAnimation(.easeInOut(duration: 0.2)) { model.expanded = open ? nil : i } }
        Group {
            if board.isGrid {
                let kinds = BoardStore.gridKinds
                if kinds.indices.contains(i) {
                    BoardCard(store: store, grid: model, board: kinds[i], index: i, fontSize: fontSize, expanded: open,
                              toggleExpand: toggle, arrange: arrange)
                } else {
                    Color.clear
                }
            } else {
                // Its board's button at the bottom puts it back in the grid when it's opened.
                BoardBox(model: model, store: store, board: board, index: i, fontSize: fontSize,
                         expanded: open, toggleExpand: toggle,
                         openBoard: { withAnimation(.easeInOut(duration: 0.2)) { model.expanded = nil } },
                         onOwnBoard: true, arrange: arrange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// "12 boxes · 4 with text" beside a board's name, and a problem saving if there is one. It
/// watches the store itself: the notes are summed up a moment after each change to the board, so
/// a view that only watched the board would show the count from before the last keystroke.
private struct BoardHeaderCount: View {
    @ObservedObject var store: BoardStore
    let board: BoardStore.Kind
    let shown: Int
    let problem: String?

    var body: some View {
        let count = store.count(board)
        Text(board.isGrid ? (shown == 1 ? "1 board" : "\(shown) boards") + " · \(count) in use"
                          : (shown == 1 ? "1 box" : "\(shown) boxes") + " · \(count) with text")
            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .fixedSize()
        if let problem = problem ?? (board.isGrid ? store.catalogProblem : nil) {
            Text(problem)
                .font(.caption)
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(problem)
        }
    }
}

/// What a box on the board's grid does when it's dragged anywhere (to another's place) or by its
/// corner (to span more or fewer blocks).
struct BoxArrange {
    /// The pointer, in the window (SwiftUI's global space).
    let move: (CGPoint) -> Void
    let moved: () -> Void
    /// How far the corner's been dragged.
    let resize: (CGSize) -> Void
    let resized: () -> Void
    /// Back to one block.
    let reset: () -> Void
    /// The color a double-click gives it: the next one that none of the boxes around it wear.
    let nextTint: () -> Int
}

/// Where a box being resized would reach: a dashed outline with its size in blocks.
private struct SizeOutline: View {
    let across: Int
    let down: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        shape.fill(Color.white.opacity(0.08))
            .overlay(shape.strokeBorder(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            .overlay(
                Text("\(across) × \(down)")
                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            )
            .allowsHitTesting(false)
    }
}

/// The corner of a box on the board's grid: drag it to span more or fewer blocks, across and
/// down; a double-click puts it back to one.
struct ResizeGrip: View {
    let arrange: BoxArrange
    let across: Int
    let down: Int
    @State private var hover = false

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for k in 1...3 {
                let d = CGFloat(k) * size.width / 3.4
                lines.move(to: CGPoint(x: size.width - d, y: size.height))
                lines.addLine(to: CGPoint(x: size.width, y: size.height - d))
            }
            context.stroke(lines, with: .color(.black.opacity(hover ? 0.6 : 0.3)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .frame(width: 12, height: 12)
        .frame(width: 16, height: 18, alignment: .bottomTrailing)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: arrange.reset)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { arrange.resize($0.translation) }
            .onEnded { _ in arrange.resized() })
        .help("\(across) × \(down) blocks: drag to make the box span more or fewer (up to \(Board.maxSpan) each way); double-click for one")
    }
}

/// A box: a thin column down its left (its icon, a click to change it; its timers; its tags at
/// the bottom), its text (the first line twice the size, as its title), the countdown of the timer
/// it runs at its top middle, and copy, open (to fill the board), dock and pin down its top right,
/// with the mic and the waveform under the pin (speak into it, or write down sound files: a sound
/// file dropped anywhere on it does that too). A
/// double-click steps it through the light colors. Above its bottom: its board's button (always,
/// on its board's grid too), the notes it links to and + to link another. Pinned, it floats in a
/// window of its own (a drag anywhere on it moves it).
struct BoardBox: View {
    @ObservedObject var model: BoardModel
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let fontSize: CGFloat
    var expanded = false
    /// Opens it to fill the board, or puts it back (nil: no such button, as when pinned).
    var toggleExpand: (() -> Void)?
    /// Opens its board (its button at the bottom: on its own board, it goes back to the grid;
    /// nil: its board, with it opened to fill it).
    var openBoard: (() -> Void)?
    /// On its own board's grid (its board's button there shows the grid).
    var onOwnBoard = false
    /// Floating in a window of its own: a drag on its text moves the window too.
    var floating = false
    /// On a board's grid: dragged anywhere to move it, by its corner to resize it.
    var arrange: BoxArrange?
    @State private var copied = false
    /// Puts the copy button's tick back; a second copy starts it over, so the tick stays its
    /// full time after the last click.
    @State private var copiedReset: Task<Void, Never>?
    /// A sound file is being dragged over it.
    @State private var dropping = false
    @ObservedObject private var focus = FocusCenter.shared

    var body: some View {
        GeometryReader { g in
            content(wide: g.size.width >= 340, roomy: g.size.width >= 300 && g.size.height >= 330, width: g.size.width,
                    tall: g.size.height >= 190)
                .frame(width: g.size.width, height: g.size.height)
        }
    }

    /// `wide`: room for the buttons' words (else their first letters or icons); `roomy`: room to
    /// play a YouTube video in the box; `tall`: room for every button down its right.
    private func content(wide: Bool, roomy: Bool, width: CGFloat, tall: Bool) -> some View {
        let box = model.board.boxes[index]
        let t = Board.tints[box.tint]
        let fill = Color(red: t.red, green: t.green, blue: t.blue)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return HStack(alignment: .top, spacing: 0) {
            NoteSideColumn(store: store, board: board, index: index, box: box)
                .padding(.leading, 3)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Next to the note's icon: Daily, Mornings, Afternoons, Evenings, Weekly, Monthly (one at a time).
                    RepeatButtons(store: store, board: board, index: index, on: box.repeats, short: !wide)
                        .padding(.leading, 2)
                    // The strip above the text: a double-click here steps the color too.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: cycle)
                }
                .frame(height: 20)
                .padding(.horizontal, 3)
                .padding(.top, 2)
                BoxEditor(text: $model.board.boxes[index].text, fontSize: fontSize, dragsWindow: floating, arrange: arrange,
                          onDoubleClick: cycle, onDropSounds: dropped, onDragOver: { dropping = $0 })
                    .padding([.horizontal], 4)
                // Speaking into it, or a sound file being written down into it.
                NoteVoiceStrip(board: board, index: index)
                LinkStrip(text: box.text, roomy: roomy, width: width - 40)
                    .padding(.horizontal, 4)
                // The row above the bottom: its board (a click opens it), the notes it links to,
                // and + to link another.
                NoteLinksRow(store: store, board: board, index: index, links: box.links, onOwnBoard: onOwnBoard,
                             openBoard: openBoard ?? { store.show(board.id, focus: index) })
                    .padding(.top, 4)
                // Bottom left: To do, Pending, Completed (one at a time); bottom right: the tags.
                HStack(spacing: 4) {
                    StatusButtons(store: store, board: board, index: index, on: box.status, short: !wide)
                    Spacer(minLength: 4)
                    ForEach(NoteTag.allCases, id: \.self) { tag in
                        TagButton(tag: tag, on: box.has(tag), height: 18) { store.toggle(tag, board, index) }
                    }
                    if let arrange { ResizeGrip(arrange: arrange, across: box.across, down: box.down) }
                }
                .frame(height: 20)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
            }
            // Down its right, from the top: copy, open to fill the board, the menu bar, dock, pin.
            VStack(spacing: 2) {
                BoxButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy the text") {
                    Clipboard.copy(box.text)
                    copied = true
                    copiedReset?.cancel()
                    copiedReset = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled else { return }
                        copied = false
                    }
                }
                if let toggleExpand {
                    BoxButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                              help: expanded ? "Open to fill the board: on. Click to go back to the grid (Esc)" : "Open to fill the board",
                              tint: expanded ? board.color : nil, lit: expanded, action: toggleExpand)
                }
                NoteMenuBarButton(store: store, board: board, index: index)
                BoxButton(symbol: "dock.arrow.down.rectangle",
                          help: box.docked ? "Undock: take it out of the row along the bottom of the menu bar panel"
                              : "Dock: keep it in the row along the bottom of the menu bar panel, a click away",
                          tint: box.docked ? board.color : nil) {
                    store.setDocked(!box.docked, board, index)
                }
                BoxButton(symbol: box.pinned ? "pin.fill" : "pin",
                          help: focus.isFocus(board, index) ? "Focus keeps this note pinned while it's the one in focus"
                              : box.pinned ? "Unpin: put the floating box away (it stays here)"
                              : "Pin: float this box on your screen, above other windows (drag it anywhere to move it)",
                          tint: box.pinned ? Color(red: 0.86, green: 0.22, blue: 0.28) : nil) {
                    store.setPinned(!box.pinned, board, index)
                }
                // Under the pin: speak into the note, or write down sound files into it.
                NoteVoiceButtons(store: store, board: board, index: index, both: tall)
            }
            .padding(.top, 2)
            .padding(.trailing, 3)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 2) {
                // The note in focus: the phase, its countdown and Completed.
                if focus.isFocus(board, index) { FocusBar(focus: focus) }
                if let alarm = box.alarm, let spec = alarm.timer {
                    BoxCountdown(alarm: alarm, spec: spec) {
                        if spec.isOneOff, spec.phase(alarm.state, now: AppClock.now()) == .finished {
                            store.dismiss(board, index)
                        } else {
                            store.stop(board, index)
                        }
                    }
                }
            }
            .padding(.top, 3)
        }
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(Color.black.opacity(0.08)))
        .overlay {
            // A sound file over it: let go to write it down into the note.
            if dropping {
                shape.fill(Color(red: 0.45, green: 0.32, blue: 0.9).opacity(0.12))
                    .overlay(shape.strokeBorder(Color(red: 0.45, green: 0.32, blue: 0.9), style: StrokeStyle(lineWidth: 2.5, dash: [7, 5])))
                    .overlay(Label("Drop to add what's said in it", systemImage: "waveform")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Color(red: 0.45, green: 0.32, blue: 0.9))))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(shape)
        // A sound file dropped on its edges (the text takes its own: `BoxEditor`).
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Self.fileURLs(providers) { urls in dropped(urls) }
            return true
        }
        // On a board's grid, a drag anywhere on it (its text too: `BoxEditor`) moves it to
        // another's place; its buttons and corner keep their own clicks and drags.
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { arrange?.move($0.location) }
                    .onEnded { _ in arrange?.moved() },
                 including: arrange == nil ? .subviews : .all)
    }

    private func cycle() {
        let tint = arrange?.nextTint() ?? Board.nextTint(after: model.board.boxes[index].tint)
        withAnimation(.easeInOut(duration: 0.2)) { model.board.boxes[index].tint = tint }
    }

    /// Sound files dropped on it: written down, and added at its end.
    private func dropped(_ urls: [URL]) {
        NoteVoice.shared.transcribe(urls, into: store, board, index)
    }

    /// The file addresses a drop carries, on the main thread once they're all read.
    nonisolated static func fileURLs(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}

/// A box floating by itself (pinned): the same box, with its board a click away. A drag anywhere
/// on it moves it (⌥-drag to select text).
struct PinnedBox: View {
    @ObservedObject var model: BoardModel
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int

    var body: some View {
        BoardBox(model: model, store: store, board: board, index: index, fontSize: 14,
                 openBoard: { store.show(board.id, focus: index) }, floating: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.colorScheme, .light)
    }
}

/// The + at the end of the row above a note's bottom: pick a note from any board to link to (it
/// goes in that row, a click away). Dark on the light note, in a ring, so it's easy to see; the
/// notes to pick from come up in a list to search.
struct NoteLinkMenu: View {
    @ObservedObject var store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    /// What it links to now (ticked in the list).
    let links: [NoteLink]
    @State private var hover = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "plus")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(open ? Color.white : Color.black.opacity(hover ? 0.85 : 0.65))
                .frame(width: 20, height: 20)
                .background(Circle().fill(open ? AnyShapeStyle(board.color) : AnyShapeStyle(Color.black.opacity(hover ? 0.14 : 0.08))))
                .overlay(Circle().strokeBorder(Color.black.opacity(open ? 0 : 0.22), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("Link a note from any board: it shows here, beside the notes it links to, a click away (pick it again to unlink)")
        .accessibilityLabel("Link a note")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            NoteLinkPicker(store: store, board: board, index: index, links: links)
        }
    }
}

/// The notes a note can link to, from every board, to search: a click links one (or unlinks it).
private struct NoteLinkPicker: View {
    @ObservedObject var store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let links: [NoteLink]
    @State private var search = ""

    var body: some View {
        let linked = Set(store.model(board).board.boxes.indices.contains(index) ? store.model(board).board.boxes[index].links : links)
        let typed = search.trimmingCharacters(in: .whitespaces)
        let words = typed.lowercased()
        let notes = store.linkable(from: board, index).filter { note in
            words.isEmpty || (note.title ?? "").lowercased().contains(words) || note.board.name.lowercased().contains(words)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Link a note").font(.headline)
                Spacer()
                Text(linked.isEmpty ? "None linked yet" : linked.count == 1 ? "1 linked" : "\(linked.count) linked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("Search the notes", text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if notes.isEmpty {
                        Text(words.isEmpty ? "No notes with a title yet" : "No note matches \u{201C}\(typed)\u{201D}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(BoardStore.kinds.filter { k in notes.contains { $0.board == k } }) { kind in
                        Label(kind.name, systemImage: kind.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(kind.color)
                            .padding(.top, 6)
                        ForEach(notes.filter { $0.board == kind }) { note in
                            let link = NoteLink(board: kind.id, box: note.index)
                            NoteLinkPickerRow(note: note, on: linked.contains(link)) {
                                if linked.contains(link) { store.removeLink(link, board, index) } else { store.addLink(link, board, index) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// A note to link to: its icon on its color, its title, and a tick when it's linked.
private struct NoteLinkPickerRow: View {
    let note: BoardStore.Note
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let look = NoteLook.colors(tint: note.tint, board: note.board)
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: note.icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(look.ink)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(look.fill))
                Text(note.title ?? note.place)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: on ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(on ? Color.green : Color.secondary)
            }
            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(on ? "Linked: click to unlink it" : "Click to link it")
    }
}

/// Down a note's right: put the note in the menu bar beside the wrench (a click there opens it by
/// itself, as if pinned), or take it out.
private struct NoteMenuBarButton: View {
    @ObservedObject var store: BoardStore
    let board: BoardStore.Kind
    let index: Int

    var body: some View {
        let id = BoardStore.dockID(board, index)
        let on = store.isInMenuBar(id)
        BoxButton(symbol: on ? "menubar.arrow.up.rectangle" : "menubar.rectangle",
                  help: on ? "In the menu bar beside the wrench: a click there opens this note by itself. Click to take it out."
                           : "Put this note in the menu bar beside the wrench: a click there opens it by itself, as if pinned",
                  tint: on ? board.color : nil) {
            store.setInMenuBar(!on, id)
        }
    }
}

/// The row above a note's bottom: its board's button (always there), then the notes it links to,
/// and + at the end to link another. A click on a linked note opens its board with it opened;
/// right-click to unlink it.
private struct NoteLinksRow: View {
    @ObservedObject var store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let links: [NoteLink]
    let onOwnBoard: Bool
    let openBoard: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            OpenBoardButton(board: board, help: onOwnBoard ? "On \(board.name): click to show its grid"
                                                         : "Open the \(board.name) board, with this note opened",
                            count: store.count(board), action: openBoard)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(links, id: \.self) { link in
                        if let note = store.note(link) {
                            NoteLinkChip(note: note, open: { store.open(link) }, unlink: { store.removeLink(link, board, index) })
                        } else if let kind = BoardStore.kind(link.board) {
                            // Linked to a note that's empty now: still a way to it.
                            NoteLinkChip(note: BoardStore.Note(board: kind, index: link.box, title: nil, icon: kind.symbol, tint: 0,
                                                               tags: [], docked: false),
                                         open: { store.open(link) }, unlink: { store.removeLink(link, board, index) })
                        }
                    }
                }
            }
            NoteLinkMenu(store: store, board: board, index: index, links: links)
        }
        .padding(.horizontal, 3)
        .frame(height: 22)
    }
}

/// A linked note: its icon on its color, and its title.
private struct NoteLinkChip: View {
    let note: BoardStore.Note
    let open: () -> Void
    let unlink: () -> Void
    @State private var hover = false

    var body: some View {
        let look = NoteLook.colors(tint: note.tint, board: note.board)
        Button(action: open) {
            HStack(spacing: 5) {
                Image(systemName: note.icon)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(look.ink)
                    .frame(width: 15, height: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(look.fill))
                Text(note.title ?? note.place)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(hover ? 0.8 : 0.6))
            .padding(.leading, 3)
            .padding(.trailing, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("\(note.place): click to open it on its board. Right-click to unlink it.")
        .contextMenu {
            Button("Open on \(note.board.name)", action: open)
            Button("Unlink", action: unlink)
        }
    }
}

/// "⊞ Goals 4": the board a box belongs to (or, on the Boards grid, the board itself), and how
/// many notes it has.
struct OpenBoardButton: View {
    let board: BoardStore.Kind
    var help: String?
    /// Its notes with a title (nil: not shown).
    var count: Int?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: board.symbol)
                    .foregroundStyle(board.color)
                Text(board.name)
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 14)
                        .background(Capsule().fill(board.color))
                        .help(count == 1 ? "1 note on \(board.name)" : "\(count) notes on \(board.name)")
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(hover ? 0.8 : 0.55))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help ?? "Open the \(board.name) board")
        .fixedSize()
    }
}

/// The thin column down a box's left: its icon at the top (a click picks another), then its five
/// timers (two countdowns, two repeating ones and a due date; the one it runs is filled in, a click
/// opens its choices). The buttons shrink to fit a small box. (Its tags are along the bottom, at
/// the right.)
private struct NoteSideColumn: View {
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let box: Board.Box

    var body: some View {
        GeometryReader { g in
            let count = CGFloat(1 + TimerSpec.forBoxes.count)
            let h = max(9, min(19, (g.size.height - 10 - 2 * count) / count))
            VStack(spacing: 2) {
                NoteIconButton(store: store, board: board, index: index, symbol: box.icon ?? board.symbol, height: h)
                    .padding(.bottom, 2)
                ForEach(TimerSpec.forBoxes) { spec in
                    AlarmButton(spec: spec, store: store, board: board, index: index, alarm: box.alarm, height: h)
                }
            }
            .padding(.vertical, 3)
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
        }
        .frame(width: 23)
    }
}

/// The note's icon (its board's until you pick one): a click opens the icons to pick from.
private struct NoteIconButton: View {
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let symbol: String
    let height: CGFloat
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: height * 0.62, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: height + 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(board.color.opacity(hover ? 1 : 0.85)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("The note's icon: click to pick another")
        .accessibilityLabel("The note's icon")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            IconPicker(current: symbol, board: board) { picked in
                store.setIcon(picked, board, index)
                open = false
            }
        }
    }
}

/// Daily, Mornings, Afternoons, Evenings (a sun rising, the sun, the moon), Weekly, Monthly, at the
/// top left of a note: the one on comes round with a Note reminder every hour of its hours until
/// it's completed. A click asks first.
private struct RepeatButtons: View {
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let on: NoteRepeat?
    let short: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NoteRepeat.allCases, id: \.self) { r in
                NotePill(title: r.symbol != nil ? nil : short ? String(r.title.prefix(1)) : r.title, symbol: r.symbol, on: on == r,
                         color: Color(red: 0.16, green: 0.55, blue: 0.42),
                         help: on == r
                            ? "\(r.title): on. A Note reminder pops up every hour (\(r.hoursText)) until it's marked completed, then not again until \(r.until). Click to turn it off."
                            : "\(r.title): a Note reminder every hour, \(r.hoursText), until it's completed, then not again until \(r.until). Click to turn it on (it asks first).") {
                    store.chooseRepeat(r, board, index)
                }
            }
        }
        .fixedSize()
    }
}

/// To do, Pending, Completed, at the bottom left of a note: at most one is on (a click on the one
/// on takes it off). A daily, weekly or monthly note uses them: its reminder's Pending and
/// Completed set them, and a new day, week or month sets it back to To do.
private struct StatusButtons: View {
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let on: NoteStatus?
    let short: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NoteStatus.allCases, id: \.self) { st in
                NotePill(title: short ? nil : st.title, symbol: st.symbol, on: on == st, color: Self.color(st),
                         help: on == st ? "\(st.title): on. Click to take it off." : "Mark it \(st.title) (one at a time)") {
                    store.toggle(st, board, index)
                }
            }
        }
        .fixedSize()
    }

    static func color(_ s: NoteStatus) -> Color {
        switch s {
        case .todo: return Color(red: 0.25, green: 0.45, blue: 0.85)
        case .pending: return Color(red: 0.88, green: 0.55, blue: 0.08)
        case .completed: return Color(red: 0.18, green: 0.62, blue: 0.32)
        }
    }
}

/// A small capsule on a light note: a word (or an icon, or both), filled in its color when on.
private struct NotePill: View {
    let title: String?
    let symbol: String?
    let on: Bool
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                if let title { Text(title).font(.system(size: 10, weight: on ? .bold : .semibold, design: .rounded)) }
            }
            .lineLimit(1)
            .foregroundStyle(on ? Color.white : Color.black.opacity(hover ? 0.7 : 0.42))
            .padding(.horizontal, title == nil ? 4 : 6)
            .frame(minWidth: 18)
            .frame(height: 17)
            .background(Capsule().fill(on ? AnyShapeStyle(color) : AnyShapeStyle(Color.black.opacity(hover ? 0.1 : 0.05))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// A tag at the bottom right of a note: lit in its color when the note has it.
private struct TagButton: View {
    let tag: NoteTag
    let on: Bool
    let height: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tag.symbol)
                .font(.system(size: height * 0.55, weight: on ? .bold : .medium))
                .foregroundStyle(on ? Color.white : Color.black.opacity(hover ? 0.6 : 0.28))
                .frame(width: 22, height: height)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? AnyShapeStyle(tag.color) : AnyShapeStyle(Color.black.opacity(hover ? 0.08 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(on ? "\(tag.title): on (it's on the \(tag.title) board). Click to take it off."
                 : "\(tag.title): click to tag it (it shows on the \(tag.title) board)")
        .accessibilityLabel(tag.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

private struct AlarmButton: View {
    let spec: TimerSpec
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let alarm: BoxAlarm?
    var height: CGFloat = 19
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let look = TimerLook.of(spec)
        let on = alarm?.spec == spec.id
        Button { open.toggle() } label: {
            Image(systemName: look.symbol)
                .font(.system(size: height * 0.55, weight: on ? .bold : .medium))
                .foregroundStyle(Color.black.opacity(on ? 0.8 : hover ? 0.75 : 0.38))
                .frame(width: 22, height: height)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? AnyShapeStyle(look.accent) : AnyShapeStyle(Color.black.opacity(hover ? 0.08 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(Self.help(spec, on: on))
        .accessibilityLabel(spec.name)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .popover(isPresented: $open, arrowEdge: .trailing) {
            if spec.kind == .deadline {
                DuePicker(store: store, board: board, index: index, alarm: alarm) { open = false }
            } else {
                PresetPicker(spec: spec, store: store, board: board, index: index, alarm: alarm) { open = false }
            }
        }
    }

    static func help(_ spec: TimerSpec, on: Bool) -> String {
        let what: String
        switch spec.kind {
        case .once: what = "counts down once, then rings until you click OK"
        case .repeating: what = "counts down, rings, sits at 0:00 for 5 minutes and starts again"
        case .deadline: what = "counts down to a day and time you pick, days, months or years ahead"
        default: what = ""
        }
        return (what.isEmpty ? "\(spec.name)." : "\(spec.name): \(what).") + (on ? " Running on this box: click to change or stop it." : " Click to set it (one timer per box).")
    }
}

/// A countdown's choices, to start one in the box.
private struct PresetPicker: View {
    let spec: TimerSpec
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let alarm: BoxAlarm?
    let done: () -> Void

    var body: some View {
        let look = TimerLook.of(spec)
        let mine = alarm?.spec == spec.id ? alarm : nil
        VStack(alignment: .leading, spacing: 10) {
            Label(spec.name, systemImage: look.symbol).font(.headline)
            Text(spec.kind == .once
                 ? "Counts down once, then rings with a card to click OK (one 3-minute snooze). Reminders come up on the way down."
                 : "Counts down, rings, stays at 0:00 for 5 minutes, then starts again until you stop it. Reminders on the way down; one snooze a round.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(spec.choices.enumerated()), id: \.offset) { i, name in
                    Button {
                        store.start(spec, choice: i, in: board, index)
                        done()
                    } label: {
                        HStack(spacing: 3) {
                            if mine?.state.choice == i { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                            Text(name)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let other = alarm?.timer, mine == nil {
                Text("Replaces \(other.name) on this box (one timer at a time).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if mine != nil {
                HStack {
                    Button("Restart") {
                        store.restart(board, index)
                        done()
                    }
                    Spacer()
                    Button("Stop", role: .destructive) {
                        store.stop(board, index)
                        done()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// A due date: a day and a time, days, months or years ahead.
private struct DuePicker: View {
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let alarm: BoxAlarm?
    let done: () -> Void
    @State private var date: Date

    init(store: BoardStore, board: BoardStore.Kind, index: Int, alarm: BoxAlarm?, done: @escaping () -> Void) {
        self.store = store
        self.board = board
        self.index = index
        self.alarm = alarm
        self.done = done
        let set = alarm?.spec == TimerSpec.deadline.id ? alarm?.state.until : nil
        _date = State(initialValue: set ?? Self.tomorrowMorning())
    }

    /// 9 AM tomorrow: a first guess.
    static func tomorrowMorning(_ calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: AppClock.now()) ?? AppClock.now().addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        let mine = alarm?.spec == TimerSpec.deadline.id
        VStack(alignment: .leading, spacing: 10) {
            Label("Due date", systemImage: TimerLook.of(TimerSpec.deadline).symbol).font(.headline)
            Text("Counts down to the day and time you pick, with reminders on the way (a month, a week, a day, an hour before…), then rings until you click OK.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("", selection: $date, in: AppClock.now()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack(spacing: 5) {
                quick("1 h", .hour, 1)
                quick("1 day", .day, 1)
                quick("1 week", .day, 7)
                quick("1 month", .month, 1)
                quick("1 year", .year, 1)
            }
            .controlSize(.small)
            Text(date > AppClock.now() ? "In \(TimerText.span(date.timeIntervalSince(AppClock.now()))) · \(date.formatted(date: .complete, time: .shortened))"
                               : "Pick a time that's still ahead")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let other = alarm?.timer, !mine {
                Text("Replaces \(other.name) on this box (one timer at a time).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            HStack {
                if mine {
                    Button("Clear", role: .destructive) {
                        store.stop(board, index)
                        done()
                    }
                }
                Spacer()
                Button(mine ? "Change due date" : "Set due date") {
                    store.setDue(date, in: board, index)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(date <= AppClock.now())
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// "1 week": that long from now.
    private func quick(_ title: String, _ unit: Calendar.Component, _ n: Int) -> some View {
        Button(title) {
            if let d = Calendar.current.date(byAdding: unit, value: n, to: AppClock.now()) { date = d }
        }
        .help("Due \(title) from now")
    }
}

/// The countdown at the top middle of a box running a timer, with a ✕ to stop it.
private struct BoxCountdown: View {
    let alarm: BoxAlarm
    let spec: TimerSpec
    let stop: () -> Void

    var body: some View {
        let look = TimerLook.of(spec)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = spec.phase(alarm.state, now: AppClock.time(at: context.date))
            let ringing = phase == .finished
            HStack(spacing: 5) {
                Image(systemName: look.symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(ringing ? Color.white : look.accent)
                    .symbolEffect(.pulse, isActive: ringing)
                Text(Self.status(phase, spec: spec))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                Button(action: stop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ringing ? "OK: stop the alarm" : "Stop \(spec.name)")
                .accessibilityLabel(ringing ? "OK" : "Stop \(spec.name)")
            }
            .foregroundStyle(.white)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 19)
            .background(Capsule().fill(ringing ? Color(red: 0.86, green: 0.22, blue: 0.28) : Color.black.opacity(0.66)))
            .help(tip)
        }
        .fixedSize()
    }

    private var tip: String {
        if spec.kind == .deadline, let until = alarm.state.until {
            return "Due \(until.formatted(date: .complete, time: .shortened))"
        }
        return spec.duration(alarm.state).map { "\(spec.name) · \(TimerText.duration($0))" } ?? spec.name
    }

    static func status(_ phase: TimerPhase, spec: TimerSpec) -> String {
        switch phase {
        case .off, .chiming: return ""
        case .counting(let left, _, let round): return TimerText.countdown(left) + (round > 0 ? " · #\(round + 1)" : "")
        case .finished: return spec.kind == .deadline ? "Due now" : "Time's up"
        case .snoozed(let left): return "Zz \(TimerText.clock(left))"
        case .holding(let left, _): return "0:00 · ↻ \(TimerText.clock(left))"
        }
    }
}

/// A small dark icon button, for the light boxes. `lit`: on, filled in its tint.
struct BoxButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    var lit = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: lit ? .bold : .medium))
                .foregroundStyle(lit ? Color.white : tint ?? Color.black.opacity(hover ? 0.75 : 0.4))
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(lit ? AnyShapeStyle(tint ?? Color.black.opacity(0.6)) : AnyShapeStyle(Color.black.opacity(hover ? 0.08 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        // Its name for VoiceOver: the tooltip up to its first colon or full stop ("Pin", "Dock").
        .accessibilityLabel(String(help.prefix { $0 != ":" && $0 != "." }))
    }
}

/// Text to type in, that says when it's double-clicked (SwiftUI's TextEditor keeps its clicks to
/// itself), with its first line twice the size of the rest (the note's title), its second line
/// halfway between the two (a rule under it once there's a third), a line starting "- " a little
/// smaller than the nearest line above it that isn't one, and its web addresses
/// underlined: a click on one opens it in your browser. A sound file dropped on it is handed to
/// `onDropSounds` (to be written down and added to the note). Dark on the light boxes; `ink` sets it
/// (white on the glass cards). With `dragsWindow` (a floating note), a press that moves drags the
/// window; with `arrange` (a note on a board's grid), it drags the note to another's place. Either
/// way a click still puts the caret there, and ⌥-drag selects.
struct BoxEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    var ink = NSColor(white: 0.12, alpha: 1)
    var linkInk = NSColor(red: 0.1, green: 0.36, blue: 0.85, alpha: 1)
    /// How much bigger the first line is.
    var titleScale: CGFloat = 2
    var dragsWindow = false
    var arrange: BoxArrange?
    var onDoubleClick: () -> Void = {}
    /// Sound (or video) files dropped on the text; nil: a drop goes in as usual.
    var onDropSounds: (([URL]) -> Void)?
    /// A sound file is being dragged over it (true), or not any more.
    var onDragOver: ((Bool) -> Void)?

    final class TextView: NSTextView {
        var onDoubleClick: (() -> Void)?
        var dragsWindow = false
        var arrange: BoxArrange?
        var onDropSounds: (([URL]) -> Void)?
        var onDragOver: ((Bool) -> Void)?
        /// The rule under the second line.
        var ruleColor = NSColor(white: 0, alpha: 0.18)
        /// The press became a drag of the note: what follows goes to the board, not the text.
        private var movingNote = false

        override func mouseDown(with event: NSEvent) {
            let plain = event.clickCount == 1 && !event.modifierFlags.contains(.option)
            if dragsWindow, plain, let window, moveWindow(window, from: event) { return }
            if arrange != nil, plain, let window, startsNoteDrag(window) { return }
            super.mouseDown(with: event)
            if event.clickCount == 2 { onDoubleClick?() }
        }

        /// Waits to see whether the press is a drag (the note's: true, and the drag goes on in
        /// `mouseDragged`, so the board redraws as it goes) or a click (false, as usual).
        private func startsNoteDrag(_ window: NSWindow) -> Bool {
            let start = NSEvent.mouseLocation
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    window.postEvent(next, atStart: true)
                    return false
                }
                let now = NSEvent.mouseLocation
                if hypot(now.x - start.x, now.y - start.y) > 4 {
                    movingNote = true
                    NSCursor.closedHand.push()
                    arrange?.move(Self.global(next, in: window))
                    return true
                }
            }
            return false
        }

        override func mouseDragged(with event: NSEvent) {
            guard movingNote, let window else { return super.mouseDragged(with: event) }
            arrange?.move(Self.global(event, in: window))
        }

        override func mouseUp(with event: NSEvent) {
            guard movingNote else { return super.mouseUp(with: event) }
            movingNote = false
            NSCursor.pop()
            arrange?.moved()
        }

        /// The pointer in SwiftUI's global space: the window's content, from its top left.
        static func global(_ event: NSEvent, in window: NSWindow) -> CGPoint {
            let p = event.locationInWindow
            return CGPoint(x: p.x, y: (window.contentView?.bounds.height ?? 0) - p.y)
        }

        /// Waits to see whether the press is a drag (macOS moves the window, onto another display
        /// too: true) or a click (the release is put back for the text to take as usual: false).
        private func moveWindow(_ window: NSWindow, from down: NSEvent) -> Bool {
            let start = NSEvent.mouseLocation
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    window.postEvent(next, atStart: true)
                    return false
                }
                let now = NSEvent.mouseLocation
                if hypot(now.x - start.x, now.y - start.y) > 4 {
                    window.performDrag(with: down)
                    return true
                }
            }
            return false
        }

        // Only plain text comes in: the look is the note's own. A web address pasted has its
        // page's icon and title fetched straight away (shown under the text).
        override func paste(_ sender: Any?) {
            if let pasted = NSPasteboard.general.string(forType: .string) { LinkPreviews.shared.pasted(pasted) }
            pasteAsPlainText(sender)
        }

        // MARK: The rule under the second line

        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            guard let y = ruleY() else { return }
            let inset = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
            ruleColor.setFill()
            NSRect(x: inset, y: y, width: max(0, bounds.width - 2 * inset), height: 1).fill()
        }

        /// Halfway between the bottom of the second line and the top of the third (nil when
        /// there's no third line).
        private func ruleY() -> CGFloat? {
            guard let lm = layoutManager, let storage = textStorage else { return nil }
            let s = string as NSString
            let lines = BoxEditor.lineRanges(s)
            guard lines.count >= 3 else { return nil }
            // The second line's break: its last line fragment, and how tall its text is.
            let br = lines[1].location + lines[1].length
            guard br < s.length else { return nil }
            let brGlyph = lm.glyphIndexForCharacter(at: br)
            let second = lm.lineFragmentRect(forGlyphAt: brGlyph, effectiveRange: nil)
            let font = (storage.attribute(.font, at: lines[1].length > 0 ? br - 1 : br, effectiveRange: nil) as? NSFont)
                ?? .systemFont(ofSize: 13)
            let bottom = second.minY + lm.defaultLineHeight(for: font)
            // The third line's top (an empty last line is the extra fragment).
            let top: CGFloat
            if lines[2].location < s.length {
                top = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lines[2].location), effectiveRange: nil).minY
            } else {
                top = lm.extraLineFragmentRect.minY
            }
            let y = top > bottom ? (bottom + top) / 2 : top
            return (y + textContainerOrigin.y).rounded()
        }

        // MARK: Sound files dropped on it

        /// The sound and video files being dragged, if there are any.
        private func sounds(_ info: NSDraggingInfo) -> [URL]? {
            guard onDropSounds != nil else { return nil }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let found = urls.filter(NoteVoice.isSound)
            return found.isEmpty ? nil : found
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard sounds(sender) != nil else { return super.draggingEntered(sender) }
            onDragOver?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            sounds(sender) != nil ? .copy : super.draggingUpdated(sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onDragOver?(false)
            super.draggingExited(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onDragOver?(false)
            guard let found = sounds(sender), let onDropSounds else { return super.performDragOperation(sender) }
            onDropSounds(found)
            return true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BoxEditor
        /// The size it was last styled at.
        var fontSize: CGFloat = 0
        init(_ parent: BoxEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            // Not while a word is being composed (an input method's marked text keeps its look).
            if !tv.hasMarkedText() { BoxEditor.style(tv, size: fontSize, titleScale: parent.titleScale, ink: parent.ink) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            BoxEditor.matchTyping(tv, size: fontSize, titleScale: parent.titleScale, ink: parent.ink)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
            guard let url else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Each line's range (up to its line break), in UTF-16 units: as many as `NoteText.lines`.
    static func lineRanges(_ string: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        while true {
            let br = string.range(of: "\n", options: [], range: NSRange(location: start, length: string.length - start))
            guard br.location != NSNotFound else {
                out.append(NSRange(location: start, length: string.length - start))
                return out
            }
            out.append(NSRange(location: start, length: br.location - start))
            start = br.location + 1
        }
    }

    /// Each line's range and font: the title semibold, the second line medium, the rest regular,
    /// each its size (`NoteText.scales`: a "- " line a little smaller than the line it's under).
    static func lineFonts(_ string: NSString, size: CGFloat, titleScale: CGFloat) -> [(range: NSRange, font: NSFont)] {
        let ranges = lineRanges(string)
        let scales = NoteText.scales(ranges.map { string.substring(with: $0) }, titleScale: Double(titleScale))
        return ranges.indices.map { i in
            (ranges[i], .systemFont(ofSize: max(8, (size * CGFloat(scales[i])).rounded()),
                                    weight: i == 0 ? .semibold : i == 1 ? .medium : .regular))
        }
    }

    /// The whole text in its look: the first line big, the second a little smaller (and a rule
    /// under it once there's a third), the rest the size of the box ("- " lines a little smaller),
    /// every web address a link (and nothing else, whatever was pasted or dropped in).
    static func style(_ tv: NSTextView, size: CGFloat, titleScale: CGFloat, ink: NSColor) {
        guard let storage = tv.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        let lines = lineFonts(storage.string as NSString, size: size, titleScale: titleScale)
        storage.beginEditing()
        storage.setAttributes([.font: NSFont.systemFont(ofSize: size), .foregroundColor: ink], range: all)
        for line in lines where line.range.length > 0 { storage.addAttribute(.font, value: line.font, range: line.range) }
        if lines.count >= 3 {
            // Room under the second line for its rule.
            let room = NSMutableParagraphStyle()
            room.paragraphSpacing = (size * 0.7).rounded()
            let second = lines[1].range
            storage.addAttribute(.paragraphStyle, value: room, range: NSRange(location: second.location, length: second.length + 1))
        }
        if let detector {
            for match in detector.matches(in: storage.string, range: all) {
                if let url = match.url { storage.addAttribute(.link, value: url, range: match.range) }
            }
        }
        storage.endEditing()
        tv.needsDisplay = true
        matchTyping(tv, size: size, titleScale: titleScale, ink: ink)
    }

    /// What's typed next takes the size of the line the caret is on.
    static func matchTyping(_ tv: NSTextView, size: CGFloat, titleScale: CGFloat, ink: NSColor) {
        let at = tv.selectedRange().location
        let lines = lineFonts(tv.string as NSString, size: size, titleScale: titleScale)
        let line = lines.last { $0.range.location <= at } ?? lines[0]
        var attributes = tv.typingAttributes
        attributes[.font] = line.font
        attributes[.foregroundColor] = ink
        attributes[.link] = nil
        tv.typingAttributes = attributes
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = TextView(frame: .zero)
        // The rule under the second line is drawn from the layout manager's lines (TextKit 1).
        _ = tv.layoutManager
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = false
        // Rich text, so the first line can be bigger; what comes in is made plain (`style`).
        tv.isRichText = true
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = ink
        tv.insertionPointColor = ink
        tv.linkTextAttributes = [.foregroundColor: linkInk, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.textContainerInset = NSSize(width: 2, height: 2)
        tv.string = text
        tv.delegate = context.coordinator
        tv.onDoubleClick = onDoubleClick
        tv.dragsWindow = dragsWindow
        tv.arrange = arrange
        tv.onDropSounds = onDropSounds
        tv.onDragOver = onDragOver
        tv.ruleColor = ink.withAlphaComponent(0.2)
        scroll.documentView = tv
        context.coordinator.fontSize = fontSize
        Self.style(tv, size: fontSize, titleScale: titleScale, ink: ink)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? TextView else { return }
        tv.onDoubleClick = onDoubleClick
        tv.dragsWindow = dragsWindow
        tv.arrange = arrange
        tv.onDropSounds = onDropSounds
        tv.onDragOver = onDragOver
        var restyle = false
        if tv.string != text {
            tv.string = text
            restyle = true
        }
        if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            restyle = true
        }
        if restyle { Self.style(tv, size: fontSize, titleScale: titleScale, ink: ink) }
    }
}
