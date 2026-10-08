import AppKit
import SwiftUI
import ToolCore

// A note's text, to write in. With no components in it, it's the note's editor as it always was.
// With some, it's a column: each run of text an editor as tall as its text (the first with the
// note's title), each component drawn to use (`ComponentView`), and a line to type on between two
// components, and after the last. Whatever's done in either is written back into the note's text,
// so the note is still just text. "/" in any of its text opens the components' menu.

struct NoteBody: View {
    @Binding var text: String
    let fontSize: CGFloat
    var ink = NSColor(white: 0.12, alpha: 1)
    var linkInk = NSColor(red: 0.1, green: 0.36, blue: 0.85, alpha: 1)
    var titleScale: CGFloat = 2
    var dragsWindow = false
    var arrange: BoxArrange?
    var onDoubleClick: () -> Void = {}
    var onDropSounds: (([URL]) -> Void)?
    var onDragOver: ((Bool) -> Void)?

    /// A row of the column: a run of text (an editor), or a component.
    private enum Row: Identifiable {
        /// `segment`: which of the document's segments it is (nil: a line to type on that isn't
        /// in the text yet, going in at `insertAt`).
        case text(segment: Int?, insertAt: Int, lines: [String], first: Bool)
        case component(index: Int, component: NoteComponent, last: Bool)

        var id: String {
            switch self {
            case .text(let s, let at, _, _): return s.map { "t\($0)" } ?? "gap\(at)"
            case .component(let i, _, _): return "c\(i)"
            }
        }
    }

    var body: some View {
        if NoteDocument.hasComponents(text) {
            blocks(NoteDocument(text))
        } else {
            editor($text, first: true, autoHeight: false)
        }
    }

    private func blocks(_ doc: NoteDocument) -> some View {
        let rows = Self.rows(doc)
        let style = ComponentStyle(ink: Color(nsColor: ink), size: fontSize)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    switch row {
                    case .text(let segment, let at, let lines, let first):
                        editor(textBinding(segment: segment, insertAt: at, lines: lines), first: first, autoHeight: true)
                            .overlay(alignment: .leading) {
                                if segment == nil {
                                    Text("Type here, or / for a component")
                                        .font(.system(size: max(9, fontSize * 0.8)))
                                        .foregroundStyle(Color(nsColor: ink).opacity(0.3))
                                        .padding(.leading, 6)
                                        .allowsHitTesting(false)
                                }
                            }
                    case .component(let index, let component, let last):
                        ComponentView(component: componentBinding(index, component), style: style,
                                      canMoveUp: index > 0, canMoveDown: !last) { change in apply(change, to: index) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.automatic)
    }

    private func editor(_ text: Binding<String>, first: Bool, autoHeight: Bool) -> BoxEditor {
        BoxEditor(text: text, fontSize: fontSize, ink: ink, linkInk: linkInk, titleScale: titleScale, dragsWindow: dragsWindow,
                  arrange: arrange, onDoubleClick: onDoubleClick, onDropSounds: onDropSounds, onDragOver: onDragOver,
                  autoHeight: autoHeight, continuation: !first)
    }

    private static func rows(_ doc: NoteDocument) -> [Row] {
        var out: [Row] = []
        var n = 0
        let total = doc.components.count
        for (i, segment) in doc.segments.enumerated() {
            switch segment {
            case .text(let lines):
                out.append(.text(segment: i, insertAt: i, lines: lines, first: i == 0))
            case .component(let c):
                // Two components together: a line to type on between them.
                if i > 0, doc.segments[i - 1].component != nil { out.append(.text(segment: nil, insertAt: i, lines: [], first: false)) }
                out.append(.component(index: n, component: c, last: n == total - 1))
                n += 1
            }
        }
        if doc.segments.last?.component != nil {
            out.append(.text(segment: nil, insertAt: doc.segments.count, lines: [], first: false))
        }
        return out
    }

    private func textBinding(segment: Int?, insertAt: Int, lines: [String]) -> Binding<String> {
        Binding(get: { lines.joined(separator: "\n") }, set: { new in
            var doc = NoteDocument(text)
            let newLines = new.components(separatedBy: "\n")
            if let segment {
                guard doc.segments.indices.contains(segment) else { return }
                doc.segments[segment] = .text(newLines)
            } else {
                guard !new.isEmpty else { return }
                doc.segments.insert(.text(newLines), at: min(insertAt, doc.segments.count))
            }
            text = doc.text
        })
    }

    private func componentBinding(_ index: Int, _ component: NoteComponent) -> Binding<NoteComponent> {
        Binding(get: { component }, set: { new in
            var doc = NoteDocument(text)
            doc.setComponent(index, new)
            text = doc.text
        })
    }

    private func apply(_ change: ComponentView.Change, to index: Int) {
        var doc = NoteDocument(text)
        switch change {
        case .remove: doc.removeComponent(index)
        case .moveUp: doc.moveComponent(index, by: -1)
        case .moveDown: doc.moveComponent(index, by: 1)
        case .duplicate: doc.duplicateComponent(index)
        case .replace(let raw): doc.replaceComponent(index, withText: raw)
        }
        withAnimation(.easeInOut(duration: 0.15)) { text = doc.text }
    }
}

// MARK: - Services the components reach into

/// What components reach into in the app (the actions, to run one from a note).
@MainActor
final class NoteComponentServices {
    static let shared = NoteComponentServices()
    weak var scheduler: Scheduler?
}
