import AppKit
import SwiftUI
import ToolCore

// MARK: - Settings

@MainActor
enum SettingsWindow {
    static func show() {
        Windows.show("settings", title: "Settings", size: NSSize(width: 580, height: 760)) {
            SettingsView(prefs: .shared)
        }
    }
}

/// Everything that used to be set up in each tool: the model, how the chat starts, the voice,
/// and the time and place the model is told about. Changes are saved as you make them.
struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @State private var models: [String] = []
    @State private var modelProblem: String?
    @State private var voice = VoiceSettings.voice.id
    @State private var speed = VoiceSettings.speed
    @State private var confirmReset = false

    static let contexts = [4096, 8192, 16384, 32768, 65536, 131_072]
    static let zones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        Form {
            Section {
                TextField("Ollama address", text: $prefs.settings.ollama)
                    .onSubmit(loadModels)
                HStack {
                    Picker("Chat model", selection: $prefs.settings.model) {
                        ForEach(modelChoices(including: prefs.settings.model), id: \.self) { Text($0.isEmpty ? "None yet" : $0).tag($0) }
                    }
                    Button("Look again", action: loadModels)
                        .help("Ask Ollama for its models again")
                }
                Picker("Diagram model", selection: $prefs.settings.diagramModel) {
                    Text("Same as the chat").tag("")
                    ForEach(modelChoices(including: prefs.settings.diagramModel).filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) }
                }
                if let modelProblem {
                    ErrorLine(text: modelProblem)
                }
                Picker("Context window", selection: $prefs.settings.contextTokens) {
                    ForEach(contextChoices, id: \.self) { n in Text("\(n / 1024)K tokens").tag(n) }
                }
                LabeledContent("Temperature") {
                    HStack {
                        Slider(value: $prefs.settings.temperature, in: 0...1.5, step: 0.05)
                        Text(String(format: "%.2f", prefs.settings.temperature)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Thinking (reasoning models)", selection: $prefs.settings.thinking) {
                    Text("The model's default").tag(AppSettings.Thinking.auto)
                    Text("Think first (slower)").tag(AppSettings.Thinking.on)
                    Text("Answer straight away").tag(AppSettings.Thinking.off)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Models come from Ollama. A bigger context window remembers more of a long chat but needs more memory; 8K suits most models. Lower temperature is steadier, higher is more inventive.")
            }

            Section {
                Picker("Start in", selection: $prefs.settings.mode) {
                    ForEach(ChatKind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind.rawValue)
                    }
                }
                HStack {
                    Picker("System prompt", selection: $prefs.settings.promptID) {
                        ForEach(Array(prefs.settings.prompts.enumerated()), id: \.element.id) { i, p in
                            Text("\(p.name.isEmpty ? "Untitled" : p.name)  ⌘\(i + 1)").tag(p.id)
                        }
                    }
                    Button("Edit…") { PromptsWindow.show() }
                }
                Toggle("Memory on in the chat", isOn: $prefs.settings.memoryOn)
                Picker("When the model learns something", selection: $prefs.settings.autoRemember) {
                    Text("Save it to memory (you can undo)").tag(true)
                    Text("Ask me first").tag(false)
                }
                .disabled(!prefs.settings.memoryOn)
                HStack {
                    Picker("Voice persona", selection: $prefs.settings.personaScope) {
                        Text("When replies are spoken").tag(AppSettings.PersonaScope.spoken)
                        Text("Always").tag(AppSettings.PersonaScope.always)
                        Text("Never").tag(AppSettings.PersonaScope.never)
                    }
                    Button("Edit…") { PromptsWindow.show(tab: .personas) }
                }
            } header: {
                Text("Chat")
            } footer: {
                Text("These are where the chat starts; its controls change them for the chat you're in. Memory is MEMORY.md, shared with Glass.")
            }

            Section("Voice") {
                Picker("Voice", selection: $voice) {
                    ForEach(NeuralVoice.all, id: \.id) { v in Text(VoiceSettings.label(v)).tag(v.id) }
                }
                .onChange(of: voice) { id in
                    // Already the voice when it was picked in the Personas tab: no second preview.
                    guard VoiceSettings.voice.id != id else { return }
                    VoiceSettings.voice = NeuralVoice.named(id)
                    Speaker.preview()
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $speed, in: 0.6...1.6, step: 0.05)
                            .onChange(of: speed) { VoiceSettings.speed = $0 }
                        Text(String(format: "%.2f×", speed)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }

            Section {
                Picker("Time zone", selection: $prefs.settings.timeZone) {
                    Text("This Mac's (\(TimeZone.current.identifier))").tag("")
                    Divider()
                    ForEach(Self.zones, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                TextField("Location", text: $prefs.settings.location, prompt: Text("e.g. Lagos, Nigeria (blank: from the time zone)"))
                Toggle("24-hour clock", isOn: $prefs.settings.clock24)
                Toggle("Tell the model about this Mac (model, chip, memory, how long it's been on)",
                       isOn: $prefs.settings.shareMacInfo)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(NowContext.describe(context.date, zone: prefs.settings.zone, location: prefs.settings.location,
                                             clock24: prefs.settings.clock24)
                         + (prefs.settings.shareMacInfo ? "\n\n" + MacFacts.describe(now: context.date, zone: prefs.settings.zone) : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Time and place")
            } footer: {
                Text("This goes with every message, already worked out (above is exactly what the model reads), so it never has to think about the date or time.")
            }

            Section {
                HStack {
                    Text("Building updates on this Mac needs Apple's command line tools with Swift 6, and gh.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Build tools…") { BuildToolsWindow.show() }
                }
            } header: {
                Text("Updates")
            }

            Section {
                HStack {
                    Button("Show settings file") { NSWorkspace.shared.activateFileViewerSelecting([prefs.url]) }
                    Spacer()
                    Button("Reset to defaults…", role: .destructive) { confirmReset = true }
                }
                if let problem = prefs.problem {
                    ErrorLine(text: problem)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 500)
        .onAppear(perform: loadModels)
        // The voice can also be picked in the Personas tab, which says so through prefs.
        .onReceive(prefs.objectWillChange) { _ in
            if voice != VoiceSettings.voice.id { voice = VoiceSettings.voice.id }
        }
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { prefs.reset() }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Prompts, personas, the memory prompt and the chat's defaults go back to how they started. The address and model stay, and MEMORY.md isn't touched.")
        }
    }

    /// The usual sizes, plus the one in the settings file when it's another (so the picker isn't blank).
    var contextChoices: [Int] {
        let current = prefs.settings.contextTokens
        return Self.contexts.contains(current) ? Self.contexts : (Self.contexts + [current]).sorted()
    }

    func modelChoices(including current: String) -> [String] {
        if models.isEmpty { return [current] }
        return models.contains(current) || current.isEmpty ? models : [current] + models
    }

    func loadModels() {
        Task {
            do {
                models = try await prefs.ollama.models()
                modelProblem = models.isEmpty ? "Ollama has no models yet: run ollama pull llama3.2 in Terminal" : nil
                if prefs.settings.model.isEmpty, let first = models.first { prefs.settings.model = first }
            } catch {
                modelProblem = prefs.ollama.explain(error)
            }
        }
    }
}

/// An error in a settings window, with a button to copy it.
struct ErrorLine: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(copied ? "Copied" : "Copy") {
                Clipboard.copy(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }
            .controlSize(.small)
        }
        .font(.callout)
    }
}

// MARK: - Prompts

@MainActor
enum PromptsWindow {
    enum Tab: Hashable { case system, memory, personas }

    static let tab = TabChoice()

    /// Which tab is showing, so other windows can open it at the right one.
    final class TabChoice: ObservableObject {
        @Published var current = Tab.system
    }

    static func show(tab: Tab = .system) {
        self.tab.current = tab
        Windows.show("prompts", title: "Prompts and personas", size: NSSize(width: 820, height: 600)) {
            PromptsView(prefs: .shared, tab: self.tab)
        }
    }
}

/// The system prompts (up to nine, picked in the chat with ⌘1 to ⌘9), the one memory prompt
/// (how the model uses and keeps MEMORY.md) and the persona for each voice.
struct PromptsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: PromptsWindow.TabChoice

    var body: some View {
        TabView(selection: $tab.current) {
            SystemPromptsPane(prefs: prefs)
                .tabItem { Text("System prompts") }
                .tag(PromptsWindow.Tab.system)
            MemoryPromptPane(prefs: prefs)
                .tabItem { Text("Memory prompt") }
                .tag(PromptsWindow.Tab.memory)
            PersonasPane(prefs: prefs)
                .tabItem { Text("Personas") }
                .tag(PromptsWindow.Tab.personas)
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 460)
    }
}

/// The list of prompts on the left, the one picked on the right.
struct SystemPromptsPane: View {
    @ObservedObject var prefs: Preferences
    @State private var selected: String?
    @State private var confirmRestore = false

    var prompts: [SystemPrompt] { prefs.settings.prompts }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selected) {
                    ForEach(Array(prompts.enumerated()), id: \.element.id) { i, p in
                        HStack {
                            Text(p.name.isEmpty ? "Untitled" : p.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            if p.id == prefs.settings.promptID {
                                Image(systemName: "star.fill").foregroundStyle(.yellow).help("Used in new chats")
                            }
                            Text("⌘\(i + 1)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(p.id)
                    }
                    .onMove { from, to in prefs.settings.prompts.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 4) {
                    Button { add(SystemPrompt(name: "New prompt", text: "You are Glass, a helpful assistant.")) } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add a prompt")
                    .disabled(prompts.count >= SystemPrompt.limit)
                    .help(prompts.count >= SystemPrompt.limit ? "Nine is the most (one for each of ⌘1 to ⌘9)" : "Add a prompt")
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(selected == nil || prompts.count <= 1)
                        .help(prompts.count <= 1 ? "There has to be at least one prompt" : "Delete the selected prompt")
                        .accessibilityLabel("Delete the selected prompt")
                    Button {
                        if let p = current { add(SystemPrompt(name: p.name + " copy", text: p.text)) }
                    } label: { Image(systemName: "plus.square.on.square") }
                        .disabled(current == nil || prompts.count >= SystemPrompt.limit)
                        .help("Duplicate the selected prompt")
                        .accessibilityLabel("Duplicate the selected prompt")
                    Spacer()
                    Text("\(prompts.count) of \(SystemPrompt.limit)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button("Restore the default prompts…") { confirmRestore = true }
                    .controlSize(.small)
            }
            .frame(width: 230)

            if let id = selected, current != nil {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: field(id, \.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    TextEditor(text: field(id, \.text))
                        .font(.system(size: 13))
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Text("~\(MemoryStore.tokens(current?.text ?? "")) tokens with every message")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(id == prefs.settings.promptID ? "Used in new chats" : "Use in new chats") {
                            prefs.settings.promptID = id
                        }
                        .disabled(id == prefs.settings.promptID)
                    }
                }
            } else {
                Text("Pick a prompt to edit it. The chat lists them in this order; ⌘1 to ⌘9 pick them there.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selected == nil { selected = prefs.settings.promptID } }
        .alert("Restore the default prompts?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) {
                prefs.settings.prompts = SystemPrompt.defaults
                prefs.settings.promptID = SystemPrompt.defaults[0].id
                selected = prefs.settings.promptID
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Your own prompts and edits are replaced by the six that came with the app.")
        }
    }

    var current: SystemPrompt? { prompts.first { $0.id == selected } }

    func field(_ id: String, _ key: WritableKeyPath<SystemPrompt, String>) -> Binding<String> {
        Binding(get: { prefs.settings.prompts.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in
                    if let i = prefs.settings.prompts.firstIndex(where: { $0.id == id }) {
                        prefs.settings.prompts[i][keyPath: key] = value
                    }
                })
    }

    func add(_ p: SystemPrompt) {
        guard prompts.count < SystemPrompt.limit else { return }
        prefs.settings.prompts.append(p)
        selected = p.id
    }

    func remove() {
        guard let id = selected, prompts.count > 1, let i = prompts.firstIndex(where: { $0.id == id }) else { return }
        prefs.settings.prompts.remove(at: i)
        if prefs.settings.promptID == id { prefs.settings.promptID = prefs.settings.prompts[0].id }
        selected = prefs.settings.prompts[min(i, prefs.settings.prompts.count - 1)].id
    }
}

/// The one memory prompt: how the model is told to use MEMORY.md and keep it up to date.
struct MemoryPromptPane: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Goes with every message while memory is on. {{memory}} is replaced by MEMORY.md (its last 6,000 characters). The model adds to memory with [[remember: …]] and takes things out with [[forget: …]]; the chat hides those tags and makes the change (or asks first, as Settings says).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $prefs.settings.memoryPrompt)
                .font(.system(size: 13))
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                if !prefs.settings.memoryPrompt.contains(MemoryStore.placeholder) {
                    Label("No {{memory}} in it: the memory goes after it.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("~\(MemoryStore.tokens(prefs.settings.memoryPrompt)) tokens plus the memory")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Edit MEMORY.md…") { MemoryWindow.show() }
                Button("Restore default") { prefs.settings.memoryPrompt = MemoryStore.defaultInstruction }
                    .disabled(prefs.settings.memoryPrompt == MemoryStore.defaultInstruction)
            }
        }
    }
}

/// A persona for each voice: who the model is when it speaks in that voice.
struct PersonasPane: View {
    @ObservedObject var prefs: Preferences
    @State private var selected = NeuralVoice.all[0].id

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            List(selection: Binding(get: { Optional(selected) }, set: { if let v = $0 { selected = v } })) {
                ForEach(NeuralVoice.all, id: \.id) { v in
                    HStack {
                        Text(Persona.for(v.id, in: prefs.settings.personas).name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(v.female ? "woman" : "man").foregroundStyle(.secondary)
                        if v == VoiceSettings.voice {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).help("The voice in use")
                        }
                    }
                    .tag(v.id)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(width: 230)

            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: field(\.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                Text("Who the model is when it speaks in \(NeuralVoice.named(selected).name)'s voice: its character, tone and manner.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: field(\.text))
                    .font(.system(size: 13))
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Text("Used \(scope).").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(VoiceSettings.voice.id == selected ? "The voice in use" : "Use this voice") {
                        VoiceSettings.voice = NeuralVoice.named(selected)
                        prefs.objectWillChange.send()
                        Speaker.preview()
                    }
                    .disabled(VoiceSettings.voice.id == selected)
                    Button("Restore default") {
                        if let d = Persona.defaults.first(where: { $0.voice == selected }) { set(d) }
                    }
                    .disabled(Persona.defaults.first(where: { $0.voice == selected }).map { $0 == Persona.for(selected, in: prefs.settings.personas) } ?? true)
                }
            }
        }
    }

    var scope: String {
        switch prefs.settings.personaScope {
        case .spoken: return "when the chat speaks its replies (Settings can change that)"
        case .always: return "in every chat"
        case .never: return "nowhere: Settings has personas turned off"
        }
    }

    func field(_ key: WritableKeyPath<Persona, String>) -> Binding<String> {
        Binding(get: { Persona.for(selected, in: prefs.settings.personas)[keyPath: key] },
                set: { value in
                    var p = Persona.for(selected, in: prefs.settings.personas)
                    p[keyPath: key] = value
                    set(p)
                })
    }

    func set(_ p: Persona) {
        if let i = prefs.settings.personas.firstIndex(where: { $0.voice == p.voice }) {
            prefs.settings.personas[i] = p
        } else {
            prefs.settings.personas.append(p)
        }
    }
}
