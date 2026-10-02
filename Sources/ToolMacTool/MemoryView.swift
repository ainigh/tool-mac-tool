import AppKit
import SwiftUI
import ToolCore

/// MEMORY.md on a glass panel like the chat's, in its own borderless window (drag its edges to
/// resize it).
@MainActor
enum MemoryWindow {
    static let margin: CGFloat = 30

    static func show() {
        Windows.show("memory") {
            let panel = GlassPanel(size: NSSize(width: 600 + 2 * margin, height: 560 + 2 * margin), resizable: true)
            panel.level = .floating          // like the chat, so the chat doesn't cover it
            panel.minSize = NSSize(width: 440 + 2 * margin, height: 320 + 2 * margin)
            let view = MemoryView(store: MemoryStore.forCurrentUser(), close: { panel.orderOut(nil) })
            let host = FirstClickHostingView(rootView: view)
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": { panel.orderOut(nil) }]
            panel.center()
            panel.setFrameAutosaveName("ToolMacTool.memory")
            return panel
        }
    }
}

/// MEMORY.md, to read and edit. Above the line: its status and the text; below it: where the file
/// is and what it costs each message. It reloads when the file changes (the chat adds to it)
/// unless you have unsaved edits; saving over a change made meanwhile asks first.
struct MemoryView: View {
    let store: MemoryStore
    let close: () -> Void

    @State private var text = ""
    @State private var saved = ""
    @State private var loadedAt: Date?
    @State private var conflict = false
    @State private var message: String?
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @Environment(\.controlActiveState) private var active

    var dirty: Bool { text != saved }
    var failed: Bool { message?.hasPrefix("Couldn't") == true }

    var mood: GlassMood { failed ? .error : dirty ? .typing : .idle }

    var body: some View {
        VStack(spacing: 0) {
            MemoryBar(dirty: dirty, failed: failed, message: message, ink: ink, close: close,
                      save: { save(force: false) }, revert: load)
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            TextEditor(text: $text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(Ink.prompt(ink))
                .tint(.white)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            GlowLine(clock: clock, mood: mood, paused: still)
                .padding(.horizontal, 26)
            MemoryFooter(store: store, text: text)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
        }
        .background(GlassCard(clock: clock, mood: mood, paused: still))
        .padding(MemoryWindow.margin)
        .frame(minWidth: 440, minHeight: 320)
        .opacity(active == .inactive ? 0.94 : 1)
        .animation(.easeInOut(duration: 0.25), value: active)
        .environment(\.colorScheme, .dark)
        .onAppear {
            try? store.ensure()
            load()
        }
        .onVisibleTick(every: 3) { reloadIfChanged() }
        .alert("MEMORY.md changed since you opened it", isPresented: $conflict) {
            Button("Save mine anyway", role: .destructive) { save(force: true) }
            Button("Load theirs (drop my edits)") { load() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Something else wrote to it (the chat remembers things there, and Glass can too).")
        }
    }

    var still: Bool { mood == .idle && active == .inactive }

    func load() {
        text = store.read()
        saved = text
        loadedAt = store.modified
        message = nil
    }

    func reloadIfChanged() {
        guard !dirty, let m = store.modified, m != loadedAt else { return }
        load()
        message = "Reloaded: it changed on disk"
        clock.ripple(x: 0.5, y: 0.4, power: 0.7)
    }

    func save(force: Bool) {
        if !force, let m = store.modified, let l = loadedAt, m != l {
            conflict = true
            return
        }
        do {
            try store.write(text)
            saved = text
            loadedAt = store.modified
            message = "Saved"
            clock.nudge()
            clock.ripple(x: 0.5, y: 0.5, hue: 150)
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// The status light and what's going on, the drag area, and Revert, Save and close.
struct MemoryBar: View {
    let dirty: Bool
    let failed: Bool
    let message: String?
    let ink: Double
    let close: () -> Void
    let save: () -> Void
    let revert: () -> Void

    var kind: StatusDot.Kind { failed ? .trouble : dirty ? .thinking : .ready }

    var status: String {
        if dirty { return "Unsaved edits" }
        return message ?? "Memory"
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 9) {
                StatusDot(kind: kind, hue: ink)
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(failed ? Color(red: 1, green: 0.7, blue: 0.75) : .white.opacity(0.72))
            .padding(.leading, 8)
            .help(message ?? "")
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            PillButton(title: "Revert", action: revert)
                .disabled(!dirty)
                .opacity(dirty ? 1 : 0.4)
            PillButton(title: "Save", prominent: dirty, action: save)
                .keyboardShortcut("s")
                .disabled(!dirty)
                .opacity(dirty ? 1 : 0.4)
            GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
                .padding(.leading, 2)
        }
    }
}

/// Where the file is (click to show it in Finder), and its size in words and in tokens added to
/// every message.
struct MemoryFooter: View {
    let store: MemoryStore
    let text: String

    var body: some View {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.url])
            } label: {
                Label(store.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "doc.text")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 18)
            KeyHint(key: "⌘S", does: "save")
            Text("\(words) words · ~\(MemoryStore.tokens(text)) tokens with every message")
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.42))
    }
}
