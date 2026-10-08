import AppKit
import SwiftUI
import ToolCore

// What the notes share across the boards: each tag's color, the icons a note can wear, a board's
// switch for its icon in the menu bar, and the tags' boards (Important, Urgent, Delegate, Think),
// each a glass panel of every note with that tag, from all the boards: the notes themselves, so
// what you type there is typed in its own board too.

extension NoteTag {
    /// Its color, lit on a note that has it (and on its board's tile).
    var color: Color {
        switch self {
        case .important: return Color(red: 0.90, green: 0.62, blue: 0.05)
        case .urgent: return Color(red: 0.88, green: 0.22, blue: 0.22)
        case .delegate: return Color(red: 0.20, green: 0.48, blue: 0.90)
        case .think: return Color(red: 0.55, green: 0.33, blue: 0.85)
        }
    }

    var help: String {
        switch self {
        case .important: return "Every note tagged Important (the star at the bottom right of a note)"
        case .urgent: return "Every note tagged Urgent (the flame at the bottom right of a note)"
        case .delegate: return "Every note tagged Delegate (the arrow at the bottom right of a note): for someone else to do"
        case .think: return "Every note tagged Think (the head at the bottom right of a note): to think over"
        }
    }
}

/// How a note's icon is drawn in the panel: on the note's own color when it has one (dark on it),
/// on its board's color when it's plain paper (white on it).
enum NoteLook {
    static func colors(tint: Int, board: BoardStore.Kind) -> (fill: Color, ink: Color) {
        guard tint != 0, Board.tints.indices.contains(tint) else { return (board.color, .white) }
        let t = Board.tints[tint]
        return (Color(red: t.red, green: t.green, blue: t.blue), Color.black.opacity(0.72))
    }
}

/// The icons a note (or a board) can wear: a click picks one, or goes back to its board's (the one
/// a board comes with).
struct IconPicker: View {
    let current: String
    let board: BoardStore.Kind
    /// Picking a board's own icon, rather than a note's.
    var forBoard = false
    let pick: (String?) -> Void

    static let symbols: [String] = [
        "note.text", "doc.text", "star.fill", "flag.fill", "bookmark.fill", "tag.fill", "pin.fill", "heart.fill",
        "bolt.fill", "flame.fill", "lightbulb.fill", "brain.head.profile", "sparkles", "target", "scope", "map",
        "person.fill", "person.2.fill", "person.3.fill", "figure.walk", "figure.run", "house.fill", "building.2.fill", "briefcase.fill",
        "cart.fill", "creditcard.fill", "dollarsign.circle.fill", "chart.bar.fill", "chart.line.uptrend.xyaxis", "globe", "airplane", "car.fill",
        "bicycle", "calendar", "clock.fill", "alarm.fill", "hourglass", "checkmark.circle.fill", "checklist", "list.bullet",
        "square.and.pencil", "pencil", "paintbrush.fill", "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "cpu", "laptopcomputer",
        "iphone", "envelope.fill", "phone.fill", "bubble.left.fill", "bubble.left.and.bubble.right.fill", "megaphone.fill", "music.note", "book.fill",
        "graduationcap.fill", "leaf.fill", "sun.max.fill", "moon.stars.fill", "cloud.fill", "drop.fill", "pills.fill", "cross.case.fill",
        "fork.knife", "cup.and.saucer.fill", "gift.fill", "camera.fill", "photo.fill", "film.fill", "gamecontroller.fill", "trophy.fill",
        "crown.fill", "puzzlepiece.fill", "link", "paperplane.fill", "tray.fill", "archivebox.fill", "folder.fill", "lock.fill",
        "key.fill", "shield.fill", "eye.fill", "hand.thumbsup.fill", "face.smiling", "exclamationmark.triangle.fill", "questionmark.circle.fill", "circle.hexagongrid",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(forBoard ? "\(board.name)'s icon" : "The note's icon").font(.headline)
                Spacer()
                Button {
                    pick(nil)
                } label: {
                    Label(forBoard ? "As it came" : "\(board.name)'s", systemImage: forBoard ? board.defaultSymbol : board.symbol)
                }
                .controlSize(.small)
                .help(forBoard ? "Back to the icon the board came with" : "Back to its board's icon")
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button { pick(symbol) } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(symbol == current ? Color.white : Color.primary)
                                .frame(width: 30, height: 28)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(symbol == current ? board.color : Color.primary.opacity(0.06)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 250)
        }
        .padding(12)
        .frame(width: 8 * 34 + 24)
    }
}

/// A board's switch for its icon in the menu bar, beside the wrench (a click there opens it).
struct MenuBarDockButton: View {
    @ObservedObject var store: BoardStore
    let id: String
    let name: String

    var body: some View {
        let on = store.isInMenuBar(id)
        PillButton(title: on ? "In the menu bar" : "Dock in the menu bar", prominent: on) { store.setInMenuBar(!on, id) }
            .help(on ? "\(name)'s icon is in the menu bar beside the wrench: a click there opens it. Click to take it out."
                     : "Put \(name)'s icon in the menu bar beside the wrench, to open it in one click")
    }
}

// MARK: - A tag's board

@MainActor
enum TagBoardWindow {
    static func id(_ tag: NoteTag) -> String { "tag-board-\(tag.rawValue)" }

    static func show(_ store: BoardStore, _ tag: NoteTag) {
        let id = Self.id(tag)
        Windows.show(id) {
            let screen = Windows.visibleFrame
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size, resizable: true)
            panel.minSize = NSSize(width: 640, height: 440)
            let close = { panel.orderOut(nil) }
            let host = FirstClickHostingView(rootView: TagBoardView(store: store, tag: tag, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close]
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        if let panel = Windows.window(id) { GlassPanel.fit(panel) }
    }
}

/// Every note with the tag, from all the boards, in a grid that fills the panel: each is the note
/// itself (its board a click away at its bottom). Taking the tag off a note takes it off this board.
struct TagBoardView: View {
    @ObservedObject var store: BoardStore
    let tag: NoteTag
    let close: () -> Void
    @State private var clock = GlassClock()
    @Environment(\.controlActiveState) private var active

    var body: some View {
        let notes = store.tagged(tag)
        VStack(spacing: 0) {
            header(notes.count)
            GeometryReader { geo in
                if notes.isEmpty {
                    empty.frame(width: geo.size.width, height: geo.size.height)
                } else {
                    grid(notes, size: geo.size)
                }
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
            footer
        }
        .background(GlassCard(clock: clock, mood: .idle, paused: active == .inactive, radius: 30))
        .environment(\.colorScheme, .dark)
    }

    private func header(_ count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tag.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tag.color)
            Text(tag.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(count == 1 ? "1 note" : "\(count) notes")
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            MenuBarDockButton(store: store, id: BoardStore.dockID(tag), name: tag.title)
            GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: tag.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tag.color)
            Text("No notes tagged \(tag.title) yet")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text("Turn on the \(tag.title) tag at the bottom right of a note on any board, and it shows up here.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        // Kept off the panel's edges when it's narrow, so the hint wraps instead of running to them.
        .padding(.horizontal, 40)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("The notes themselves: what you type here is typed on their own boards. Take the tag off a note (bottom right) to take it off this board.")
                .lineLimit(1)
            Spacer()
            KeyHint(key: "⌘W", does: "close")
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 26)
        .padding(.vertical, 10)
    }

    private func grid(_ notes: [BoardStore.Note], size: CGSize) -> some View {
        let gap = CGFloat(Board.gutter(for: notes.count)) + 2
        let rows = Board.rows(for: notes.count, width: size.width, height: size.height)
        let starts = rows.indices.map { rows.prefix($0).reduce(0, +) }
        let fontSize: CGFloat = notes.count <= 4 ? 16 : notes.count <= 9 ? 15 : notes.count <= 16 ? 14 : 13
        return VStack(spacing: gap) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(Array(notes[starts[r]..<(starts[r] + rows[r])])) { note in
                        BoardBox(model: store.model(note.board), store: store, board: note.board, index: note.index,
                                 fontSize: fontSize, openBoard: { store.show(note.board.id, focus: note.index) })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
