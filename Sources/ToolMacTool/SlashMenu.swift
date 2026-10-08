import AppKit
import SwiftUI
import ToolCore

// The components' menu: "/" at the start of a word in a note opens it under the caret. Typing on
// narrows it (by name, kind and the words each is known by); ↑ and ↓ move through it, ↩ or ⇥ (or a
// click) puts the one picked in the note, on lines of its own, and esc closes it. It never takes
// the keyboard from the note: it's a panel that doesn't become key.

@MainActor
final class SlashMenu: ObservableObject {
    static let shared = SlashMenu()

    @Published private(set) var matches: [NoteComponentType] = []
    @Published var selected = 0
    @Published private(set) var query = ""
    private weak var textView: NSTextView?
    /// The "/query" in the text view.
    private var range = NSRange(location: 0, length: 0)
    private var panel: Panel?

    /// A panel that never becomes key, so the note keeps the keyboard.
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 46
    static let mostRows = 7

    var isOpen: Bool { panel?.isVisible == true }

    /// The text or the caret moved: open, narrow or close the menu.
    func update(_ tv: NSTextView) {
        let sel = tv.selectedRange()
        guard let window = tv.window, window.firstResponder === tv, sel.length == 0, !tv.hasMarkedText(),
              let found = NoteSlash.query(in: tv.string, caret: sel.location) else {
            close(for: tv)
            return
        }
        let m = NoteComponentType.matching(found.query)
        guard !m.isEmpty else {
            close(for: tv)
            return
        }
        if textView !== tv || m != matches { selected = 0 }
        textView = tv
        range = NSRange(location: found.location, length: found.length)
        query = found.query
        matches = m
        show(at: tv)
    }

    /// Closed (only when it's this text view's).
    func close(for tv: NSTextView) {
        guard textView === tv else { return }
        close()
    }

    func close() {
        panel?.orderOut(nil)
        textView = nil
        matches = []
    }

    /// The keys it takes while it's open; false lets the text view have the rest.
    func handle(_ selector: Selector, in tv: NSTextView) -> Bool {
        guard isOpen, textView === tv, !matches.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            selected = (selected - 1 + matches.count) % matches.count
            return true
        case #selector(NSResponder.moveDown(_:)):
            selected = (selected + 1) % matches.count
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            choose(matches[min(selected, matches.count - 1)])
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// The component put in the note in place of the "/query".
    func choose(_ type: NoteComponentType) {
        guard let tv = textView else { return }
        let r = range
        close()
        let s = tv.string as NSString
        guard r.location + r.length <= s.length else { return }
        let text = NoteSlash.replacement(type.template(), in: tv.string, location: r.location, length: r.length)
        tv.window?.makeFirstResponder(tv)
        tv.insertText(text, replacementRange: r)
    }

    private func show(at tv: NSTextView) {
        let panel = self.panel ?? make()
        let rows = CGFloat(min(matches.count, Self.mostRows))
        let size = NSSize(width: Self.width, height: rows * Self.rowHeight + 34)
        var caret = tv.firstRect(forCharacterRange: range, actualRange: nil)
        if caret.isEmpty, let window = tv.window {
            caret = window.convertToScreen(tv.convert(tv.bounds, to: nil))
        }
        let screen = (NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - size.height - 4)
        // No room under the line: above it.
        if origin.y < screen.minY { origin.y = caret.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func make() -> Panel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = true
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let host = FirstClickHostingView(rootView: SlashMenuView(menu: self))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }
}

/// The list: each component's icon, name and what it's for; the one picked lit.
private struct SlashMenuView: View {
    @ObservedObject var menu: SlashMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                Text(menu.query.isEmpty ? "Components" : "Components matching \u{201C}\(menu.query)\u{201D}")
                    .lineLimit(1)
                Spacer()
                Text("↑↓ ↩")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(menu.matches.enumerated()), id: \.element) { i, type in
                            row(type, lit: i == menu.selected)
                                .id(type)
                                .contentShape(Rectangle())
                                .onTapGesture { menu.choose(type) }
                                .onHover { if $0 { menu.selected = i } }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: menu.selected) { _, now in
                    guard menu.matches.indices.contains(now) else { return }
                    proxy.scrollTo(menu.matches[now])
                }
            }
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func row(_ type: NoteComponentType, lit: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: type.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lit ? Color.white : ComponentLook.color(type.group))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(lit ? ComponentLook.color(type.group) : ComponentLook.color(type.group).opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(type.title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(type.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: SlashMenu.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lit ? Color.accentColor.opacity(0.16) : .clear))
    }
}
