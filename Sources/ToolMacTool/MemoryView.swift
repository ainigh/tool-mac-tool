import AppKit
import SwiftUI
import ToolCore

@MainActor
enum MemoryWindow {
    static func show() {
        Windows.show("memory", title: "Memory", size: NSSize(width: 640, height: 560)) {
            MemoryView(store: MemoryStore.forCurrentUser())
        }
    }
}

/// MEMORY.md, to read and edit. It reloads when the file changes (the chat adds to it) unless
/// you have unsaved edits; saving over a change made meanwhile asks first.
struct MemoryView: View {
    let store: MemoryStore

    @State private var text = ""
    @State private var saved = ""
    @State private var loadedAt: Date?
    @State private var conflict = false
    @State private var message: String?

    let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var dirty: Bool { text != saved }

    var body: some View {
        VStack(spacing: 0) {
            MemoryBar(store: store, text: text, dirty: dirty, message: message,
                      save: { save(force: false) }, revert: load)
                .padding(.horizontal, 14)
                .padding(.top, 34)
                .padding(.bottom, 8)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            try? store.ensure()
            load()
        }
        .onReceive(tick) { _ in reloadIfChanged() }
        .alert("MEMORY.md changed since you opened it", isPresented: $conflict) {
            Button("Save mine anyway", role: .destructive) { save(force: true) }
            Button("Load theirs (drop my edits)") { load() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Something else wrote to it (the chat remembers things there, and Glass can too).")
        }
    }

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
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

struct MemoryBar: View {
    let store: MemoryStore
    let text: String
    let dirty: Bool
    let message: String?
    let save: () -> Void
    let revert: () -> Void

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
            .buttonStyle(.link)
            .help("Show in Finder")
            Spacer()
            Text(message ?? "\(words) words · ~\(MemoryStore.tokens(text)) tokens with every message")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Revert", action: revert).disabled(!dirty)
            Button("Save", action: save)
                .keyboardShortcut("s")
                .disabled(!dirty)
        }
        .controlSize(.small)
    }
}
