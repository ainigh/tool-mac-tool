import AppKit
import SwiftUI
import ToolCore

/// The boards (Goals, Strategies, Entities, Notes, People, Ideas, Dreams, Projects, Health,
/// Communication): each a big glass panel of boxes (notes) to type into, kept in
/// ~/Library/Application Support/ToolMacTool/boards/<id>.json.
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
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
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

    init(id: String) {
        url = Board.url(for: id)
        board = Board.load(from: url)
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

/// The glass panel: the board's name at the top, the boxes filling the middle in their order, some
/// spanning more blocks (or one box, opened to fill it all) with an arrow either side for fewer or more, and a line of hints at the bottom.
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

    struct Sizing: Equatable {
        let box: Int
        var across: Int
        var down: Int
    }

    /// The grid's coordinate space, which a box's drag reports the pointer in.
    static let space = "board-grid"

    var body: some View {
        let shown = model.board.shown
        VStack(spacing: 0) {
            header(shown)
            HStack(spacing: 14) {
                SideArrow(symbol: "chevron.left", help: "Fewer boxes (their text is kept)", enabled: shown > Board.minBoxes) {
                    withAnimation(.easeInOut(duration: 0.2)) { model.board.fewer() }
                }
                GeometryReader { geo in
                    if let e = model.expanded, model.board.isShown(e) {
                        box(e, count: 1)
                    } else {
                        grid(size: geo.size)
                    }
                }
                SideArrow(symbol: "chevron.right", help: "More boxes", enabled: shown < Board.maxBoxes) {
                    withAnimation(.easeInOut(duration: 0.2)) { model.board.more() }
                }
            }
            .padding(.horizontal, 14)
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
            Image(systemName: board.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(board.name)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(shown == 1 ? "1 box" : "\(shown) boxes")
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            if let problem = model.problem {
                Text(problem).font(.caption).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.5)).lineLimit(1).help(problem)
            }
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            FocusButton(focus: FocusCenter.shared, board: board)
            MenuBarDockButton(store: store, id: board.id, name: board.name)
            GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Double-click a box to change its color. Drag its top strip to move it, its bottom right corner to resize it. Down its left: its icon, and a timer or a due date (one per box). Top left: Daily (or only Mornings, Afternoons or Evenings), Weekly or Monthly (a reminder every hour until it's done; each day, week or month begins at 8 AM the day before). Bottom left: To do, Pending, Completed; bottom right: its tags. Top right: dock it in the panel, or pin it to float on your screen. Paste a web address to see its page (a YouTube video plays here).")
                .lineLimit(1)
            Spacer()
            if model.expanded != nil { KeyHint(key: "esc", does: "back to the grid") }
            KeyHint(key: "⌘W", does: "close")
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 26)
        .padding(.vertical, 10)
    }

    /// The shown boxes in their order, each in its place (a big one spanning blocks). Drag a box
    /// by the strip along its top to move it to another's place; drag its corner to resize it.
    private func grid(size: CGSize) -> some View {
        let shown = model.board.shown
        let gap = CGFloat(Board.gutter(for: shown)) + 2
        let layout = model.board.layout(width: size.width, height: size.height)
        let block = CGSize(width: (size.width + gap) / CGFloat(layout.across), height: (size.height + gap) / CGFloat(layout.down))
        return ZStack(alignment: .topLeading) {
            ForEach(layout.cells, id: \.box) { cell in
                let frame = Self.frame(cell, size: size, gap: gap)
                let lifted = moving == cell.box || sizing?.box == cell.box
                box(cell.box, count: shown, arrange: arrange(cell.box, size: size, gap: gap, block: block))
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
        .coordinateSpace(name: Self.space)
    }

    /// A cell's frame in points, a gutter between it and its neighbours.
    static func frame(_ cell: Board.Cell, size: CGSize, gap: CGFloat) -> CGRect {
        let w = size.width + gap, h = size.height + gap
        return CGRect(x: CGFloat(cell.x) * w, y: CGFloat(cell.y) * h,
                      width: CGFloat(cell.width) * w - gap, height: CGFloat(cell.height) * h - gap)
    }

    /// Moving and resizing a box on the grid.
    private func arrange(_ i: Int, size: CGSize, gap: CGFloat, block: CGSize) -> BoxArrange {
        BoxArrange(
            move: { point in
                moving = i
                // The board as it is now (it changes as the box takes other places).
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
            })
    }

    private func box(_ i: Int, count: Int, arrange: BoxArrange? = nil) -> some View {
        let open = model.expanded == i
        return BoardBox(model: model, store: store, board: board, index: i,
                        fontSize: open ? 18 : count <= 4 ? 16 : count <= 9 ? 15 : count <= 16 ? 14 : 13,
                        expanded: open, toggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) { model.expanded = open ? nil : i }
                        }, arrange: arrange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// What a box on the board's grid does when it's dragged by its top strip (to another's place)
/// or by its corner (to span more or fewer blocks).
struct BoxArrange {
    /// The pointer, in the grid's coordinate space (`BoardView.space`).
    let move: (CGPoint) -> Void
    let moved: () -> Void
    /// How far the corner's been dragged.
    let resize: (CGSize) -> Void
    let resized: () -> Void
    /// Back to one block.
    let reset: () -> Void
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
private struct ResizeGrip: View {
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

/// The big round arrows either side of the grid.
private struct SideArrow: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? (hover ? 1 : 0.8) : 0.25))
                .frame(width: 48, height: 48)
                .background(Circle().fill(.white.opacity(hover && enabled ? 0.18 : 0.08)))
                .overlay(Circle().stroke(.white.opacity(hover && enabled ? 0.32 : 0.16), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// A box: a thin column down its left (its icon, a click to change it; its timers; its tags at
/// the bottom), its text (the first line twice the size, as its title), the countdown of the timer
/// it runs at its top middle, and copy, open (to fill the board), dock and pin at its top right. A
/// double-click steps it through the light colors. Pinned, it floats in a window of its own (a
/// drag anywhere on it moves it), with a way back to its board at the bottom.
struct BoardBox: View {
    @ObservedObject var model: BoardModel
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    let fontSize: CGFloat
    var expanded = false
    /// Opens it to fill the board, or puts it back (nil: no such button, as when pinned).
    var toggleExpand: (() -> Void)?
    /// Opens its board (shown at the bottom when it's pinned, or on a tag's board).
    var openBoard: (() -> Void)?
    /// Floating in a window of its own: a drag on its text moves the window too.
    var floating = false
    /// On a board's grid: dragged by its top strip to move it, by its corner to resize it.
    var arrange: BoxArrange?
    @State private var copied = false
    @ObservedObject private var focus = FocusCenter.shared

    var body: some View {
        GeometryReader { g in
            content(wide: g.size.width >= 340, roomy: g.size.width >= 300 && g.size.height >= 330, width: g.size.width)
                .frame(width: g.size.width, height: g.size.height)
        }
    }

    /// `wide`: room for the buttons' words (else their first letters or icons); `roomy`: room to
    /// play a YouTube video in the box.
    private func content(wide: Bool, roomy: Bool, width: CGFloat) -> some View {
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
                    // The strip above the text: a double-click here steps the color too, and on a
                    // board's grid, a drag moves the box to another's place.
                    Color.clear
                        .contentShape(Rectangle())
                        .overlay {
                            if arrange != nil {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.black.opacity(0.22))
                                    .allowsHitTesting(false)
                            }
                        }
                        .onTapGesture(count: 2, perform: cycle)
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(BoardView.space))
                            .onChanged { arrange?.move($0.location) }
                            .onEnded { _ in arrange?.moved() })
                        .onHover { inside in
                            guard arrange != nil else { return }
                            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                        }
                        .help(arrange != nil ? "Drag to move the box to another's place; double-click to change its color" : "")
                    BoxButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy the text") {
                        Clipboard.copy(box.text)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copied = false
                        }
                    }
                    if let toggleExpand {
                        BoxButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  help: expanded ? "Back to the grid (Esc)" : "Open to fill the board", action: toggleExpand)
                    }
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
                }
                .frame(height: 20)
                .padding(.horizontal, 3)
                .padding(.top, 2)
                BoxEditor(text: $model.board.boxes[index].text, fontSize: fontSize, dragsWindow: floating, onDoubleClick: cycle)
                    .padding([.horizontal], 4)
                LinkStrip(text: box.text, roomy: roomy, width: width - 40)
                    .padding(.horizontal, 4)
                if let openBoard {
                    OpenBoardButton(board: board, action: openBoard)
                        .padding(.top, 4)
                }
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
        .clipShape(shape)
    }

    private func cycle() {
        withAnimation(.easeInOut(duration: 0.2)) {
            model.board.boxes[index].tint = Board.nextTint(after: model.board.boxes[index].tint)
        }
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

/// "⊞ Goals": back to the board a box belongs to.
struct OpenBoardButton: View {
    let board: BoardStore.Kind
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                Text(board.name)
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
        .help("Open the \(board.name) board, with this box opened")
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
        return "\(spec.name): \(what)." + (on ? " Running on this box: click to change or stop it." : " Click to set it (one timer per box).")
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

/// A small dark icon button, for the light boxes.
private struct BoxButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? Color.black.opacity(hover ? 0.75 : 0.4))
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Text to type in, that says when it's double-clicked (SwiftUI's TextEditor keeps its clicks to
/// itself), with its first line twice the size of the rest (the note's title) and its web addresses
/// underlined: a click on one opens it in your browser. Dark on the light boxes; `ink` sets it
/// (white on the glass cards). With `dragsWindow` (a floating note), a press that moves drags the
/// window; a click still puts the caret there, and ⌥-drag selects.
struct BoxEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    var ink = NSColor(white: 0.12, alpha: 1)
    var linkInk = NSColor(red: 0.1, green: 0.36, blue: 0.85, alpha: 1)
    /// How much bigger the first line is.
    var titleScale: CGFloat = 2
    var dragsWindow = false
    var onDoubleClick: () -> Void = {}

    final class TextView: NSTextView {
        var onDoubleClick: (() -> Void)?
        var dragsWindow = false

        override func mouseDown(with event: NSEvent) {
            if dragsWindow, event.clickCount == 1, !event.modifierFlags.contains(.option), let window,
               moveWindow(window) { return }
            super.mouseDown(with: event)
            if event.clickCount == 2 { onDoubleClick?() }
        }

        /// Waits to see whether the press is a drag (it moves the window: true) or a click (the
        /// release is put back for the text to take as usual: false).
        private func moveWindow(_ window: NSWindow) -> Bool {
            let start = NSEvent.mouseLocation
            let origin = window.frame.origin
            var dragging = false
            defer { if dragging { NSCursor.pop() } }
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    if !dragging { window.postEvent(next, atStart: true) }
                    return dragging
                }
                let now = NSEvent.mouseLocation
                let dx = now.x - start.x, dy = now.y - start.y
                if !dragging, hypot(dx, dy) > 4 {
                    dragging = true
                    NSCursor.closedHand.push()
                }
                if dragging { window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy)) }
            }
            return dragging
        }

        // Only plain text comes in: the look is the note's own. A web address pasted has its
        // page's icon and title fetched straight away (shown under the text).
        override func paste(_ sender: Any?) {
            if let pasted = NSPasteboard.general.string(forType: .string) { LinkPreviews.shared.pasted(pasted) }
            pasteAsPlainText(sender)
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

    /// How long the first line is (up to its line break), in UTF-16 units.
    static func titleLength(_ string: NSString) -> Int {
        let br = string.rangeOfCharacter(from: .newlines)
        return br.location == NSNotFound ? string.length : br.location
    }

    static func fonts(_ size: CGFloat, _ scale: CGFloat) -> (body: NSFont, title: NSFont) {
        (.systemFont(ofSize: size), .systemFont(ofSize: (size * scale).rounded(), weight: .semibold))
    }

    /// The whole text in its look: the first line big, the rest the size of the box, every web
    /// address a link (and nothing else, whatever was pasted or dropped in).
    static func style(_ tv: NSTextView, size: CGFloat, titleScale: CGFloat, ink: NSColor) {
        guard let storage = tv.textStorage else { return }
        let f = fonts(size, titleScale)
        let all = NSRange(location: 0, length: storage.length)
        let title = titleLength(storage.string as NSString)
        storage.beginEditing()
        storage.setAttributes([.font: f.body, .foregroundColor: ink], range: all)
        if title > 0 { storage.addAttribute(.font, value: f.title, range: NSRange(location: 0, length: title)) }
        if let detector {
            for match in detector.matches(in: storage.string, range: all) {
                if let url = match.url { storage.addAttribute(.link, value: url, range: match.range) }
            }
        }
        storage.endEditing()
        matchTyping(tv, size: size, titleScale: titleScale, ink: ink)
    }

    /// What's typed next takes the size of the line the caret is on.
    static func matchTyping(_ tv: NSTextView, size: CGFloat, titleScale: CGFloat, ink: NSColor) {
        let f = fonts(size, titleScale)
        let onTitle = tv.selectedRange().location <= titleLength(tv.string as NSString)
        var attributes = tv.typingAttributes
        attributes[.font] = onTitle ? f.title : f.body
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
