import AppKit
import SwiftUI
import ToolCore

/// A board on the Boards grid, drawn like a note: down its left, the board's icon (a click picks
/// another); its first line, its name, and its second, what it's for (both typed right there);
/// under them, not typed but kept up to date by itself, the board's notes with a title, each with
/// its icon (a click opens it on its board). Down its top right: open it to fill the grid, and the
/// menu bar. At its bottom, the board's button: a click opens the board, showing its grid. A
/// double-click steps the card through the light colors; it's dragged and resized as a note is.
struct BoardCard: View {
    @ObservedObject var store: BoardStore
    /// The Boards grid: the card's color and size.
    @ObservedObject var grid: BoardModel
    let board: BoardStore.Kind
    /// Its place on the grid.
    let index: Int
    let fontSize: CGFloat
    var expanded = false
    let toggleExpand: () -> Void
    var arrange: BoxArrange?
    @State private var picking = false

    var body: some View {
        let box = grid.board.boxes[index]
        let t = Board.tints[Board.tints.indices.contains(box.tint) ? box.tint : 0]
        let fill = Color(red: t.red, green: t.green, blue: t.blue)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let notes = store.written(board)
        let builtin = store.info(board)?.builtin == true
        HStack(alignment: .top, spacing: 0) {
            // Down its left: the board's icon.
            VStack(spacing: 0) {
                iconButton
                Spacer(minLength: 0)
            }
            .frame(width: 23)
            .padding(.leading, 3)
            .padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 0) {
                // The strip above the name: how many notes (a double-click here steps the color).
                HStack(spacing: 4) {
                    Text(notes.count == 1 ? "1 note" : "\(notes.count) notes")
                    if builtin { Text("· comes with the app") }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.4))
                .lineLimit(1)
                .frame(height: 20)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: cycle)
                TextField("", text: nameBinding, prompt: Text("Board name"))
                    .textFieldStyle(.plain)
                    .font(.system(size: (fontSize * 2).rounded(), weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .help("The board's name: type to change it")
                TextField("", text: detailBinding, prompt: Text("What it's for"))
                    .textFieldStyle(.plain)
                    .font(.system(size: (fontSize * 1.5).rounded(), weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .padding(.top, 2)
                    .help("What the board is for: type to change it")
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 1)
                    .padding(.vertical, 5)
                noteList(notes)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Its bottom: the board's button (it opens the board, showing its grid).
                HStack(spacing: 4) {
                    OpenBoardButton(board: board, help: "Open the \(board.name) board, showing its grid", count: notes.count) {
                        store.show(board.id, grid: true)
                    }
                    Spacer(minLength: 4)
                    if let arrange { ResizeGrip(arrange: arrange, across: box.across, down: box.down) }
                }
                .frame(height: 22)
                .padding(.vertical, 3)
            }
            .padding(.horizontal, 4)
            // Down its top right: open it to fill the grid, the menu bar.
            VStack(spacing: 2) {
                BoxButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: expanded ? "Open to fill the grid: on. Click to go back to the grid (Esc)" : "Open to fill the grid",
                          tint: expanded ? board.color : nil, lit: expanded, action: toggleExpand)
                let inMenuBar = store.isInMenuBar(board.id)
                BoxButton(symbol: inMenuBar ? "menubar.arrow.up.rectangle" : "menubar.rectangle",
                          help: inMenuBar ? "In the menu bar beside the wrench: a click there opens this board. Click to take it out."
                                          : "Put this board in the menu bar beside the wrench, to open it in one click",
                          tint: inMenuBar ? board.color : nil) {
                    store.setInMenuBar(!inMenuBar, board.id)
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 3)
        }
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(Color.black.opacity(0.08)))
        .clipShape(shape)
        .environment(\.colorScheme, .light)
        // On the grid, a drag on it (not on its name or description) moves it to another's place.
        .contentShape(shape)
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { arrange?.move($0.location) }
                    .onEnded { _ in arrange?.moved() },
                 including: arrange == nil ? .subviews : .all)
    }

    private var nameBinding: Binding<String> {
        Binding(get: { store.info(board)?.name ?? "" }, set: { store.rename(board, $0) })
    }

    private var detailBinding: Binding<String> {
        Binding(get: { store.info(board)?.detail ?? "" }, set: { store.setDetail(board, $0) })
    }

    /// The board's icon, on its color: a click picks another.
    private var iconButton: some View {
        Button { picking.toggle() } label: {
            Image(systemName: board.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 21)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(board.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(board.name)'s icon: click to pick another")
        .accessibilityLabel("\(board.name)'s icon")
        .popover(isPresented: $picking, arrowEdge: .trailing) {
            IconPicker(current: board.symbol, board: board, forBoard: true) { picked in
                store.setIcon(picked, for: board)
                picking = false
            }
        }
    }

    /// The board's notes with a title, in its order: not typed here, a click opens one.
    @ViewBuilder
    private func noteList(_ notes: [BoardStore.Note]) -> some View {
        if notes.isEmpty {
            Text("No notes yet: open the board (below) to write some, and they're listed here.")
                .font(.system(size: max(11, fontSize * 0.85), weight: .medium, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(notes) { note in
                        BoardCardNoteRow(note: note, fontSize: fontSize) {
                            store.show(board.id, focus: note.index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cycle() {
        let tint = arrange?.nextTint() ?? Board.nextTint(after: grid.board.boxes[index].tint)
        withAnimation(.easeInOut(duration: 0.2)) { grid.board.boxes[index].tint = tint }
    }
}

/// A note listed on its board's card: its icon on its color, and its first line. A click opens it.
private struct BoardCardNoteRow: View {
    let note: BoardStore.Note
    let fontSize: CGFloat
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let look = NoteLook.colors(tint: note.tint, board: note.board)
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: note.icon)
                    .font(.system(size: max(8, fontSize * 0.6), weight: .bold))
                    .foregroundStyle(look.ink)
                    .frame(width: fontSize + 2, height: fontSize + 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(look.fill))
                Text(note.title ?? note.place)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Color.black.opacity(hover ? 0.9 : 0.72))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(note.title ?? note.place): click to open it on \(note.board.name)")
    }
}
