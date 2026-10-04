import AppKit
import SwiftUI
import ToolCore

/// The boards (Goals, Strategies, Entities, Notes): each a big window of boxes to type into, kept
/// in ~/Library/Application Support/ToolMacTool/boards/<id>.json.
@MainActor
enum BoardWindow {
    private static var models: [String: BoardModel] = [:]

    static func show(_ id: String, title: String) {
        let model = models[id] ?? BoardModel(id: id)
        models[id] = model
        Windows.show("board-\(id)", title: title, size: NSSize(width: 1040, height: 720)) {
            BoardView(model: model)
        }
    }
}

/// One board, saved a moment after each change.
@MainActor
final class BoardModel: ObservableObject {
    @Published var board: Board {
        didSet {
            if board != oldValue { scheduleSave() }
        }
    }
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

/// The arrows at the top (fewer, more; the title is the window's), then the boxes filling the rest: or one box, opened to
/// fill it all.
struct BoardView: View {
    @ObservedObject var model: BoardModel
    @State private var expanded: Int?

    var body: some View {
        let shown = model.board.shown
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                IconButton(symbol: "chevron.left", help: "Fewer boxes (their text is kept)") {
                    withAnimation(.easeInOut(duration: 0.2)) { model.board.fewer() }
                }
                .disabled(shown <= Board.minBoxes)
                Text("\(shown)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 22)
                IconButton(symbol: "chevron.right", help: "More boxes") {
                    withAnimation(.easeInOut(duration: 0.2)) { model.board.more() }
                }
                .disabled(shown >= Board.maxBoxes)
                Spacer()
            }
            .overlay(alignment: .leading) {
                if let problem = model.problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(1).help(problem)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            GeometryReader { geo in
                if let e = expanded, e < shown {
                    box(e, count: 1)
                } else {
                    grid(shown: shown, size: geo.size)
                }
            }
            .padding([.horizontal, .bottom], 10)
        }
        .frame(minWidth: 480, minHeight: 360)
        .onChange(of: shown) { _, now in
            if let e = expanded, e >= now { expanded = nil }
        }
    }

    private func grid(shown: Int, size: CGSize) -> some View {
        let gap = CGFloat(Board.gutter(for: shown))
        let rows = Board.rows(for: shown, width: size.width, height: size.height)
        let starts = rows.indices.map { rows.prefix($0).reduce(0, +) }
        return VStack(spacing: gap) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(starts[r]..<(starts[r] + rows[r]), id: \.self) { i in
                        box(i, count: shown)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func box(_ i: Int, count: Int) -> some View {
        BoardBox(box: $model.board.boxes[i], expanded: expanded == i,
                 fontSize: expanded == i ? 17 : count <= 4 ? 15 : count <= 9 ? 14 : count <= 16 ? 13 : 12) {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = expanded == i ? nil : i }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A box: its text, copy and open (to fill the panel) at its top right. A double-click steps it
/// through the light colors.
struct BoardBox: View {
    @Binding var box: Board.Box
    let expanded: Bool
    let fontSize: CGFloat
    let toggleExpand: () -> Void
    @State private var copied = false

    var body: some View {
        let t = Board.tints[box.tint]
        let fill = Color(red: t.red, green: t.green, blue: t.blue)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The strip above the text: a double-click here steps the color too.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: cycle)
                BoxButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy the text") {
                    Clipboard.copy(box.text)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                }
                BoxButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: expanded ? "Back to the grid" : "Open to fill the panel", action: toggleExpand)
            }
            .frame(height: 20)
            .padding(.horizontal, 3)
            .padding(.top, 2)
            BoxEditor(text: $box.text, fontSize: fontSize, onDoubleClick: cycle)
                .padding([.horizontal, .bottom], 4)
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func cycle() {
        withAnimation(.easeInOut(duration: 0.2)) { box.tint = Board.nextTint(after: box.tint) }
    }
}

/// A small dark icon button, for the light boxes.
private struct BoxButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(hover ? 0.75 : 0.4))
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Plain text to type in, dark on the light box, that says when it's double-clicked (SwiftUI's
/// TextEditor keeps its clicks to itself).
struct BoxEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let onDoubleClick: () -> Void

    final class TextView: NSTextView {
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2 { onDoubleClick?() }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BoxEditor
        init(_ parent: BoxEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
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
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(white: 0.12, alpha: 1)
        tv.insertionPointColor = NSColor(white: 0.12, alpha: 1)
        tv.textContainerInset = NSSize(width: 2, height: 2)
        tv.string = text
        tv.delegate = context.coordinator
        tv.onDoubleClick = onDoubleClick
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? TextView else { return }
        tv.onDoubleClick = onDoubleClick
        if tv.string != text { tv.string = text }
        if tv.font?.pointSize != fontSize { tv.font = .systemFont(ofSize: fontSize) }
    }
}
