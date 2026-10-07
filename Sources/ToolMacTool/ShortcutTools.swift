import AppKit
import SwiftUI
import ToolCore

/// Runs Apple Shortcuts with the `shortcuts` command line tool that comes with macOS: the input
/// goes in as a text file, the output (when there is one) comes back as text.
enum ShortcutRunner {
    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let tool = "/usr/bin/shortcuts"
    /// The most of a shortcut's output that goes back to the model.
    static let maxOutput = 8000

    /// Your shortcuts' names, as the Shortcuts app lists them.
    static func list() async throws -> [String] {
        let out = try await run([ "list" ], timeout: 30)
        return out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Runs one with `input`. Returns what it hands back ("" for a one-way shortcut, or one that
    /// returned nothing).
    static func run(_ shortcut: String, input: String, returnsText: Bool, timeout: TimeInterval = 120) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tmt-shortcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inURL = folder.appendingPathComponent("input.txt")
        let outURL = folder.appendingPathComponent("output.txt")
        try Data(input.utf8).write(to: inURL)
        var args = ["run", shortcut, "--input-path", inURL.path]
        if returnsText { args += ["--output-path", outURL.path, "--output-type", "public.plain-text"] }
        _ = try await run(args, timeout: timeout)
        guard returnsText, let data = try? Data(contentsOf: outURL) else { return "" }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > maxOutput ? String(text.prefix(maxOutput)) + "\n…(cut short)" : text
    }

    /// Runs `shortcuts` with these arguments, off the main thread; its output, or its error.
    private static func run(_ args: [String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    continuation.resume(throwing: Problem("Couldn't start shortcuts: \(error.localizedDescription)"))
                    return
                }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                final class Box { var data = Data() }
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                group.wait()
                let errData = errBox.data
                let timedOut = !timer.isCancelled && p.terminationReason == .uncaughtSignal
                timer.cancel()
                if timedOut {
                    continuation.resume(throwing: Problem("it took longer than \(Int(timeout)) seconds, so it was stopped"))
                } else if p.terminationStatus != 0 {
                    let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Problem(message.isEmpty ? "shortcuts failed (\(p.terminationStatus))" : message))
                } else {
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                }
            }
        }
    }
}

// MARK: - The Tools window

@MainActor
enum ToolsWindow {
    static func show() {
        Windows.show("tools", title: "Tools: shortcuts the model can run", size: NSSize(width: 860, height: 620)) {
            ToolsView(prefs: .shared)
        }
    }
}

/// The shortcuts the chat's model may run: which ones, when to call each (its description), what
/// to pass it, whether it hands text back, and whether to ask first. Each can be tried here.
struct ToolsView: View {
    @ObservedObject var prefs: Preferences
    @State private var available: [String] = []
    @State private var listProblem: String?
    @State private var selected: String?

    var tools: [ShortcutTool] { prefs.settings.shortcuts }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Let the chat's model run these shortcuts", isOn: $prefs.settings.toolsOn)
                .toggleStyle(.switch)
            Text("Each shortcut takes one piece of text and gives one back (or nothing, if it's one way). The model reads each description to decide when to call it, runs it, and uses what comes back in its reply. The chat's ⋯ menu turns tools off for a chat. Not every model can call tools: llama3.1 and newer, qwen2.5 and newer, mistral and others can.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let listProblem {
                ErrorLine(text: listProblem)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    List(selection: $selected) {
                        ForEach(tools) { t in
                            HStack {
                                Image(systemName: t.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(t.enabled ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.shortcut).lineLimit(1).truncationMode(.middle)
                                    Text(t.returnsText ? "text in, text back" : "one way")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !available.isEmpty && !available.contains(t.shortcut) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                        .help("There's no shortcut with this name any more")
                                }
                            }
                            .tag(t.id)
                        }
                        .onMove { from, to in prefs.settings.shortcuts.move(fromOffsets: from, toOffset: to) }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                    HStack(spacing: 4) {
                        Menu {
                            let unused = available.filter { name in !tools.contains { $0.shortcut == name } }
                            if unused.isEmpty {
                                Text(available.isEmpty ? "No shortcuts found" : "All your shortcuts are added")
                            }
                            ForEach(unused, id: \.self) { name in
                                Button(name) { add(name) }
                            }
                            Divider()
                            Button("Look again") { loadShortcuts() }
                        } label: {
                            Label("Add shortcut", systemImage: "plus")
                        }
                        .fixedSize()
                        Button { remove() } label: { Image(systemName: "minus") }
                            .disabled(selected == nil)
                            .help("Take the selected shortcut out (the shortcut itself stays)")
                            .accessibilityLabel("Take the selected shortcut out")
                        Spacer()
                        Button("Open Shortcuts") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
                        }
                        .controlSize(.small)
                    }
                }
                .frame(width: 260)

                if let id = selected, tools.contains(where: { $0.id == id }) {
                    ToolEditor(prefs: prefs, id: id, available: available)
                } else {
                    Text(tools.isEmpty ? "Add a shortcut to begin. Make it take text as its input and give text back (or nothing)."
                                       : "Pick one to edit when the model should use it.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            loadShortcuts()
            if selected == nil { selected = tools.first?.id }
        }
    }

    func loadShortcuts() {
        Task {
            do {
                available = try await ShortcutRunner.list()
                listProblem = nil
            } catch {
                listProblem = "Couldn't list your shortcuts: \(error.localizedDescription)"
            }
        }
    }

    func add(_ name: String) {
        let t = ShortcutTool(shortcut: name,
                             description: "Runs the \"\(name)\" shortcut. Call it when the user ")
        prefs.settings.shortcuts.append(t)
        selected = t.id
    }

    func remove() {
        guard let id = selected, let i = tools.firstIndex(where: { $0.id == id }) else { return }
        prefs.settings.shortcuts.remove(at: i)
        selected = prefs.settings.shortcuts.isEmpty ? nil : prefs.settings.shortcuts[min(i, prefs.settings.shortcuts.count - 1)].id
    }
}

/// One tool: the shortcut, when to call it, what to pass, what comes back, and a place to try it.
struct ToolEditor: View {
    @ObservedObject var prefs: Preferences
    let id: String
    let available: [String]
    @State private var trial = ""
    @State private var result: String?
    @State private var failed = false
    @State private var running = false
    /// The tool the run under way is for (nil once another is picked), so its result isn't shown
    /// under a different one.
    @State private var trying: String?

    var tool: ShortcutTool { prefs.settings.shortcuts.first { $0.id == id } ?? ShortcutTool(shortcut: "") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Shortcut", selection: binding(\.shortcut)) {
                        ForEach(available.contains(tool.shortcut) ? available : [tool.shortcut] + available, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Toggle("On", isOn: binding(\.enabled))
                }
                LabeledContent("The model calls it") {
                    Text(ShortcutTool.callable(prefs.settings.shortcuts).first { $0.tool.id == id }?.name
                         ?? ShortcutTool.functionName(tool.shortcut))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("When to call it").font(.headline)
                    Text("Like a prompt: what it does and when the model should use it (and when not).")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: binding(\.description))
                        .font(.system(size: 13))
                        .frame(minHeight: 110)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What to pass it").font(.headline)
                    TextField("What to pass it", text: binding(\.input),
                              prompt: Text("e.g. The city to get the weather for"))
                        .textFieldStyle(.roundedBorder)
                }
                Picker("What comes back", selection: binding(\.returnsText)) {
                    Text("Text, which the model reads").tag(true)
                    Text("Nothing: one way, the model is told it ran").tag(false)
                }
                .pickerStyle(.radioGroup)
                Toggle("Ask me before each run", isOn: binding(\.confirm))
                Divider()
                Text("Try it").font(.headline)
                HStack {
                    TextField("Input", text: $trial, prompt: Text("Text to give it"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(tryIt)
                    Button(running ? "Running…" : "Run", action: tryIt)
                        .disabled(running || tool.shortcut.isEmpty)
                }
                if let result {
                    if failed {
                        ErrorLine(text: result)
                    } else {
                        HStack(alignment: .top) {
                            Text(result.isEmpty ? "(it ran, and gave nothing back)" : result)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Copy") { Clipboard.copy(result) }.controlSize(.small)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    }
                }
            }
            .padding(.trailing, 6)
        }
        .onChange(of: id) { _ in
            result = nil
            failed = false
            trying = nil
        }
    }

    func binding<T>(_ key: WritableKeyPath<ShortcutTool, T>) -> Binding<T> {
        Binding(get: { tool[keyPath: key] },
                set: { value in
                    if let i = prefs.settings.shortcuts.firstIndex(where: { $0.id == id }) {
                        prefs.settings.shortcuts[i][keyPath: key] = value
                    }
                })
    }

    func tryIt() {
        // Return in the box runs it too, so the button's disabled state isn't enough.
        guard !running, !tool.shortcut.isEmpty else { return }
        let t = tool
        running = true
        trying = t.id
        Task {
            let got: String, bad: Bool
            do {
                got = try await ShortcutRunner.run(t.shortcut, input: trial, returnsText: t.returnsText)
                bad = false
            } catch {
                got = "\(t.shortcut) failed: \(error.localizedDescription)"
                bad = true
            }
            running = false
            // Another tool picked meanwhile: this result isn't its.
            guard trying == t.id else { return }
            result = got
            failed = bad
        }
    }
}
