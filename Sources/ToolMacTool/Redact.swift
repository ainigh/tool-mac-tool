import AppKit
import SwiftUI
import ToolCore

// Redact and the Redaction map. The map is every sensitive word you've met, each with what
// stands in for it, kept in ~/Library/Application Support/ToolMacTool/redaction-map.json and
// filled in over time: the model (Ollama, on this Mac: the text never leaves it) lists the names
// it finds in what you paste, one word a line, and new ones join the map as "Person<n>" for you to
// review. Redacting is then a mechanical swap through the map (whole words, in one pass, capitals
// kept), and Restore swaps back.

@MainActor
final class RedactionStore: ObservableObject {
    static let shared = RedactionStore()

    @Published var map: RedactionMap {
        didSet { if map != oldValue { scheduleSave() } }
    }
    @Published private(set) var finding = false
    @Published private(set) var problem: String?

    let url = RedactionMap.defaultURL()
    private var saveTask: Task<Void, Never>?

    private init() {
        map = RedactionMap.load(from: RedactionMap.defaultURL())
    }

    /// What a look for names found: every name in the text, and those that were new to the map.
    struct Found {
        var names: [String]
        var added: [String]
    }

    /// Asks the model for the names in `text` (a long text a piece at a time), and learns them
    /// into the map. Nil when it couldn't ask (the problem says why).
    func find(in text: String) async -> Found? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !finding else { return nil }
        let prefs = Preferences.shared
        let s = prefs.settings
        guard !s.model.isEmpty else {
            problem = "Pick a model in Settings first (Ollama needs at least one: ollama pull llama3.2)"
            return nil
        }
        finding = true
        problem = nil
        defer { finding = false }
        var names: [String] = []
        var seen = Set<String>()
        do {
            for piece in Redaction.chunks(trimmed) {
                let answer = try await prefs.ollama.reply(model: s.model,
                                                          messages: [ChatTurn(role: "system", content: Redaction.system),
                                                                     ChatTurn(role: "user", content: Redaction.prompt(piece))],
                                                          contextTokens: s.contextTokens, temperature: 0)
                for name in Redaction.parseNames(answer) where seen.insert(Redaction.key(name)).inserted {
                    names.append(name)
                }
            }
        } catch {
            problem = prefs.ollama.explain(error)
            return nil
        }
        let added = map.learn(names)
        return Found(names: names, added: added)
    }

    /// The text swapped through the map.
    func redact(_ text: String) -> Redaction.Swap { Redaction.apply(text, pairs: map.pairs) }

    func restore(_ text: String) -> Redaction.Swap { Redaction.restore(text, map: map) }

    // MARK: Editing

    func binding<T>(_ id: UUID, _ path: WritableKeyPath<RedactionMap.Entry, T>, reviewed: Bool = true) -> Binding<T>? {
        guard let i = map.entries.firstIndex(where: { $0.id == id }) else { return nil }
        let fallback = map.entries[i][keyPath: path]
        return Binding(get: { [weak self] in
            self?.map.entries.first { $0.id == id }?[keyPath: path] ?? fallback
        }, set: { [weak self] value in
            guard let self, let i = self.map.entries.firstIndex(where: { $0.id == id }) else { return }
            self.map.entries[i][keyPath: path] = value
            // Touching it is reviewing it.
            if reviewed { self.map.entries[i].isNew = false }
        })
    }

    /// A word added by hand (one already there is left as it is).
    func add(_ word: String, substitute: String = "") {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, map.entry(for: w) == nil else { return }
        let sub = substitute.trimmingCharacters(in: .whitespacesAndNewlines)
        map.entries.append(RedactionMap.Entry(original: w, substitute: sub.isEmpty ? map.nextPlaceholder() : sub, isNew: false, seen: 0))
    }

    func delete(_ ids: Set<UUID>) { map.entries.removeAll { ids.contains($0.id) } }

    /// The chosen ones all take the first one's substitute (the same person under several names).
    func merge(_ ids: Set<UUID>) {
        let chosen = map.entries.filter { ids.contains($0.id) }
        guard let first = chosen.first else { return }
        for i in map.entries.indices where ids.contains(map.entries[i].id) {
            map.entries[i].substitute = first.substitute
            map.entries[i].isNew = false
        }
    }

    func markReviewed(_ ids: Set<UUID>? = nil) {
        for i in map.entries.indices where ids?.contains(map.entries[i].id) ?? true { map.entries[i].isNew = false }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try self.map.save(to: self.url)
            } catch {
                self.problem = "Couldn't save the map: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Redact

@MainActor
enum RedactWindow {
    static func show() {
        Windows.show("redact", title: "Redact", size: NSSize(width: 980, height: 620)) {
            RedactView(store: .shared)
        }
    }
}

/// Paste text, find its names (they join the map), redact it through the map, copy it. Restore
/// swaps a redacted text (a reply that used the substitutes) back.
struct RedactView: View {
    @ObservedObject var store: RedactionStore
    @State private var input = ""
    @State private var output = ""
    @State private var summary: String?
    @State private var added: [String] = []
    @State private var copied = false
    @AppStorage("redactFrontMatter") private var frontMatter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Paste") {
                    input = NSPasteboard.general.string(forType: .string) ?? input
                    output = ""
                }
                .help("Put what's on the clipboard in the box")
                Button {
                    Task { await find(thenRedact: false) }
                } label: {
                    Label("Find names", systemImage: "person.text.rectangle")
                }
                .help("Ask the model (on this Mac) for every person's name in the text; new ones join the Redaction map")
                Button {
                    Task { await find(thenRedact: true) }
                } label: {
                    Label("Find & redact", systemImage: "wand.and.stars")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Find the names, then redact (⌘Return)")
                Button("Redact") { redact() }
                    .help("Swap every word in the map for its substitute: no model, the same every time")
                Button("Restore") { restore() }
                    .help("The other way: each substitute back to its original (for a reply that used them)")
                if store.finding { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Mapping at the top", isOn: $frontMatter)
                    .help("Put the substitutions used at the top of the result, as front matter")
                Button("Redaction map…") { RedactionMapWindow.show() }
            }
            .disabled(store.finding)
            HStack(spacing: 10) {
                pane("Text", text: $input, prompt: "Paste the text to redact")
                pane("Result", text: $output, prompt: "The redacted text comes here")
            }
            HStack(spacing: 8) {
                if let problem = store.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
                } else if let summary {
                    Text(summary).lineLimit(2)
                } else {
                    Text("\(store.map.pairs.count) words in the map. Names are found by the model on this Mac (Ollama); redacting is a plain swap through the map.")
                        .foregroundStyle(.secondary)
                }
                if !added.isEmpty {
                    Button("Review \(added.count) new…") { RedactionMapWindow.show(filter: .new) }
                }
                Spacer()
                Button(copied ? "Copied" : "Copy result") {
                    Clipboard.copy(output)
                    copied = true
                }
                .disabled(output.isEmpty)
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .font(.callout)
        }
        .padding(14)
        .onChange(of: output) { _, _ in copied = false }
    }

    private func pane(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(text.wrappedValue.count) characters").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: text)
                .font(.system(size: 13))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(prompt).foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        }
    }

    private func find(thenRedact: Bool) async {
        guard let found = await store.find(in: input) else { return }
        added = found.added
        summary = found.names.isEmpty ? "No names found."
            : "Found \(found.names.count) name\(found.names.count == 1 ? "" : "s")"
                + (found.added.isEmpty ? ", all already in the map." : "; new in the map: \(found.added.joined(separator: ", ")).")
        if thenRedact { redact(keepSummary: true) }
    }

    private func redact(keepSummary: Bool = false) {
        let r = store.redact(input)
        output = frontMatter ? Redaction.withFrontMatter(r) : r.text
        let swaps = r.used.reduce(0) { $0 + $1.count }
        let line = swaps == 0 ? "Nothing in the map was found in the text." : "Redacted: \(swaps) swap\(swaps == 1 ? "" : "s") of \(r.used.count) word\(r.used.count == 1 ? "" : "s")."
        summary = keepSummary ? [summary, line].compactMap { $0 }.joined(separator: " ") : line
    }

    private func restore() {
        let r = store.restore(input)
        output = r.text
        let swaps = r.used.reduce(0) { $0 + $1.count }
        summary = swaps == 0 ? "No substitutes found to restore." : "Restored \(swaps) substitute\(swaps == 1 ? "" : "s")."
    }
}

// MARK: - The map

@MainActor
enum RedactionMapWindow {
    static let focus = Focus()

    final class Focus: ObservableObject {
        @Published var filter = RedactionMapView.Filter.all
    }

    static func show(filter: RedactionMapView.Filter? = nil) {
        if let filter { focus.filter = filter }
        Windows.show("redaction-map", title: "Redaction map", size: NSSize(width: 860, height: 600)) {
            RedactionMapView(store: .shared, focus: focus)
        }
    }
}

/// Every word and its substitute, to edit: several words can share one substitute (the same
/// person), a word can be kept (not a name after all). Learn from text adds the names in what you
/// paste.
struct RedactionMapView: View {
    enum Filter: String, CaseIterable {
        case all = "All", new = "New", kept = "Kept"
    }

    @ObservedObject var store: RedactionStore
    @ObservedObject var focus: RedactionMapWindow.Focus
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var newWord = ""
    @State private var learning = false

    var rows: [RedactionMap.Entry] {
        let q = Redaction.key(search)
        return store.map.entries.filter { e in
            switch focus.filter {
            case .all: break
            case .new: if !e.isNew { return false }
            case .kept: if !e.keep { return false }
            }
            return q.isEmpty || Redaction.key(e.original).contains(q) || Redaction.key(e.substitute).contains(q)
                || Redaction.key(e.note).contains(q)
        }
    }

    var body: some View {
        let shared = store.map.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: $focus.filter) {
                    ForEach(Filter.allCases, id: \.self) { f in
                        Text(f == .new ? "New (\(store.map.entries.filter(\.isNew).count))" : f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Spacer()
                Button {
                    learning = true
                } label: {
                    Label("Learn from text…", systemImage: "text.badge.plus")
                }
                .help("Paste past text: the model lists its names and new ones join the map")
            }
            Table(rows, selection: $selection) {
                TableColumn("") { e in
                    Circle().fill(e.isNew ? Color.accentColor : .clear).frame(width: 7, height: 7)
                        .help(e.isNew ? "New: not reviewed yet" : "")
                }
                .width(12)
                TableColumn("Original") { e in
                    if let b = store.binding(e.id, \.original) { TextField("", text: b) }
                }
                .width(min: 120, ideal: 180)
                TableColumn("Substitute") { e in
                    HStack(spacing: 4) {
                        if let b = store.binding(e.id, \.substitute) { TextField("", text: b) }
                        if shared.contains(e.substitute) {
                            Image(systemName: "link").foregroundStyle(.secondary)
                                .help("Shared with another word (the same person): Restore gives back the first one")
                        }
                    }
                }
                .width(min: 120, ideal: 180)
                TableColumn("Keep") { e in
                    if let b = store.binding(e.id, \.keep) {
                        Toggle("", isOn: b).labelsHidden()
                            .help("Keep: not redacted (an ordinary word the model took for a name)")
                    }
                }
                .width(40)
                TableColumn("Seen") { e in Text("\(e.seen)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(40)
                TableColumn("Note") { e in
                    if let b = store.binding(e.id, \.note) { TextField("", text: b) }
                }
                .width(min: 120, ideal: 200)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Same substitute (the first one's)") { store.merge(ids) }.disabled(ids.count < 2)
                Button("Mark reviewed") { store.markReviewed(ids) }
                Divider()
                Button("Delete", role: .destructive) { store.delete(ids) }
            }
            .onDeleteCommand { store.delete(selection) }
            HStack(spacing: 8) {
                TextField("Add a word (a name, a company, an email…)", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(addWord)
                Button("Add", action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Same substitute") { store.merge(selection) }
                    .disabled(selection.count < 2)
                    .help("Give the selected words the first one's substitute (the same person under several names)")
                Button("Mark reviewed") { store.markReviewed(selection.isEmpty ? nil : selection) }
                    .help("Take the New mark off the selected words (or all of them)")
                Button("Delete") { store.delete(selection) }.disabled(selection.isEmpty)
            }
            Text("\(store.map.entries.count) words · kept in \(store.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · new ones get Person<n> until you change them")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .sheet(isPresented: $learning) {
            LearnSheet(store: store) { learning = false }
        }
    }

    private func addWord() {
        store.add(newWord)
        newWord = ""
    }
}

/// Paste past text: its names join the map.
private struct LearnSheet: View {
    @ObservedObject var store: RedactionStore
    let done: () -> Void
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Learn names from text").font(.headline)
            Text("The model on this Mac lists every person's name in it, one word a line; the new ones join the map as Person<n>, marked New for you to review.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let result {
                Text(result)
            }
            HStack {
                Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? text }
                if store.finding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close", action: done).keyboardShortcut(.cancelAction)
                Button("Learn") {
                    Task {
                        guard let found = await store.find(in: text) else { return }
                        result = found.names.isEmpty ? "No names found."
                            : "Found \(found.names.count); \(found.added.isEmpty ? "none new" : "new: \(found.added.joined(separator: ", "))")."
                        text = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.finding || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}
