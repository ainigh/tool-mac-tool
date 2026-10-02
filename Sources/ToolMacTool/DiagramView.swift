import AppKit
import Combine
import SwiftUI
import ToolCore
import WebKit

/// The diagram tool: you type or say what you want, the model answers with Mermaid, and it's drawn
/// on the glass. Each request sends the diagram as it stands; only the last exchange is kept, and
/// no memory or system prompt from the chat is used. A diagram that won't draw is sent back once
/// with Mermaid's error so the model can fix it.
@MainActor
final class DiagramModel: ObservableObject {
    /// What the canvas is asked to draw: a reply, an undo, or code you edited.
    struct Drawing: Equatable {
        enum Kind { case reply, undo, edit, clear }
        let id: Int
        let code: String
        let kind: Kind
    }

    @Published var input = ""
    /// The Mermaid on the canvas.
    @Published private(set) var code = ""
    /// The one before it, for Undo.
    @Published private(set) var previous: String?
    /// What you asked last.
    @Published private(set) var lastAsk = ""
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var problem: String?
    /// The Mermaid that didn't draw, to look at or copy.
    @Published private(set) var failedCode: String?
    @Published private(set) var drawing: Drawing?
    @Published private(set) var models: [String] = []

    let prefs = Preferences.shared
    /// Closes the window (set when it's made).
    var onClose: (() -> Void)?
    /// Saying what to draw (Parakeet is fetched the first time it listens).
    let listener = Listener()
    private var exchange: (ask: String, reply: String)?
    private var task: Task<Void, Never>?
    private var counter = 0
    /// The conversation for the reply being drawn, so a repair can carry on from it.
    private var pendingTurns: [ChatTurn] = []
    private var pendingAsk = ""
    private var repaired = false
    private var watch: AnyCancellable?

    init() {
        watch = prefs.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        listener.pauseToEnd = 1.4
        listener.onUtterance = { [weak self] said in
            guard let self else { return }
            // "Close", "exit": the window goes, nothing is drawn.
            if VoiceCommand.parse(said) == .close {
                self.input = ""
                self.onClose?()
                return
            }
            self.input = said
            self.send()
        }
    }

    var model: String {
        let s = prefs.settings
        return s.diagramModel.isEmpty ? s.model : s.diagramModel
    }

    func loadModels() {
        Task {
            if let names = try? await prefs.ollama.models() { models = names }
        }
    }

    /// Sends what's in the box, with the diagram as it stands.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        guard !model.isEmpty else {
            problem = "Pick a model in Settings first (Ollama needs at least one: ollama pull llama3.2)"
            return
        }
        input = ""
        lastAsk = text
        problem = nil
        failedCode = nil
        var turns = [ChatTurn(role: "system", content: Diagram.system)]
        if let exchange {
            turns.append(ChatTurn(role: "user", content: "Request: " + exchange.ask))
            turns.append(ChatTurn(role: "assistant", content: "```mermaid\n\(exchange.reply)\n```"))
        }
        turns.append(ChatTurn(role: "user", content: Diagram.request(text, current: code)))
        pendingAsk = text
        repaired = false
        ask(turns)
    }

    /// Draws what another model described (the chat's draw_diagram tool): whatever's under way
    /// stops, and this is sent as if typed.
    func request(_ description: String) {
        if busy { stop() }
        input = description
        send()
    }

    private func ask(_ turns: [ChatTurn]) {
        busy = true
        status = repaired ? "Fixing the diagram…" : "Drawing…"
        listener.hold()
        let s = prefs.settings
        let model = self.model
        let ollama = prefs.ollama
        task = Task {
            do {
                let reply = try await ollama.reply(model: model, messages: turns, contextTokens: s.contextTokens,
                                                   temperature: 0.2, thinking: s.thinking)
                guard !Task.isCancelled else { return done() }
                guard let mermaid = Diagram.extract(reply) else {
                    problem = "The reply had no diagram in it: \(reply.prefix(300))"
                    return done()
                }
                pendingTurns = turns + [ChatTurn(role: "assistant", content: reply)]
                draw(mermaid, kind: .reply)
            } catch {
                if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                    problem = ollama.explain(error)
                }
                done()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        done()
    }

    private func done() {
        busy = false
        status = ""
        listener.release()
    }

    private func draw(_ mermaid: String, kind: Drawing.Kind) {
        counter += 1
        drawing = Drawing(id: counter, code: mermaid, kind: kind)
    }

    /// The canvas drew it, or couldn't (Mermaid's error).
    func drawn(_ id: Int, error: String?) {
        guard let d = drawing, d.id == id else { return }
        drawing = nil
        if let error {
            switch d.kind {
            case .reply where !repaired:
                repaired = true
                ask(pendingTurns + [ChatTurn(role: "user", content: Diagram.repair(error))])
            default:
                failedCode = d.code
                problem = "The diagram didn't draw: \(error)"
                done()
            }
            return
        }
        switch d.kind {
        case .reply, .edit:
            if !code.isEmpty { previous = code }
            code = d.code
            if d.kind == .reply { exchange = (pendingAsk, d.code) }
        case .undo:
            previous = code.isEmpty ? nil : code
            code = d.code
        case .clear:
            code = ""
        }
        failedCode = nil
        done()
    }

    var canUndo: Bool { previous != nil && !busy }

    /// Back to the diagram before (and again to go forward).
    func undo() {
        guard let previous, !busy else { return }
        draw(previous, kind: .undo)
    }

    /// Draws Mermaid you wrote or edited.
    func apply(_ edited: String) {
        let text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        problem = nil
        draw(text, kind: .edit)
    }

    /// A blank canvas, and nothing remembered.
    func clear() {
        stop()
        previous = code.isEmpty ? previous : code
        exchange = nil
        lastAsk = ""
        problem = nil
        failedCode = nil
        draw("", kind: .clear)
    }

    func clearProblem() {
        problem = nil
    }

    func toggleMic() {
        if listener.on { listener.stop() } else { listener.start() }
    }
}

// MARK: - The window

@MainActor
enum DiagramWindow {
    static let margin: CGFloat = 24

    static func show(_ diagram: DiagramModel) {
        Windows.show("diagram") {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size)
            panel.dragsAnywhere = true
            panel.level = .floating
            let close = {
                diagram.listener.stop()
                panel.orderOut(nil)
            }
            diagram.onClose = close
            let reveal = Reveal()
            panel.onDoubleClick = { reveal.toggle() }
            let host = FirstClickHostingView(rootView: DiagramView(diagram: diagram, reveal: reveal, close: close,
                                                                   pin: { on in panel.level = on ? .floating : .normal }))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close, "n": { diagram.clear() }]
            panel.onEscape = {
                if diagram.busy {
                    diagram.stop()
                } else if diagram.listener.on {
                    diagram.listener.stop()
                } else if diagram.input.isEmpty {
                    close()
                } else {
                    return false
                }
                return true
            }
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        diagram.loadModels()
    }
}

/// The canvas filling the glass, what you asked last over its top edge, the box along the
/// bottom, and the controls under it, shown while the pointer is over the glass. The Mermaid
/// itself can be opened beside the canvas, edited and drawn.
struct DiagramView: View {
    @ObservedObject var diagram: DiagramModel
    /// The controls, shown by a double-click.
    @ObservedObject var reveal: Reveal
    var hovering: Bool { reveal.shown }
    let close: () -> Void
    let pin: (Bool) -> Void

    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @State private var pinned = true
    @State private var showCode = false
    @State private var editing = ""
    @State private var copiedSVG = false
    @State private var canvas = MermaidCanvas.Handle()
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var active

    var mood: GlassMood { diagram.busy ? .thinking : diagram.problem != nil ? .error : .idle }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack(alignment: .topLeading) {
                    MermaidCanvas(diagram: diagram, handle: canvas)
                    if !diagram.lastAsk.isEmpty {
                        Text(diagram.lastAsk)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.prompt(ink).opacity(0.7))
                            .lineLimit(2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.25)))
                            .allowsHitTesting(false)
                    }
                    if diagram.busy {
                        HStack(spacing: 10) {
                            Caret(hue: ink).scaleEffect(0.6)
                            Text(diagram.status)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(Ink.reply(ink))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                    }
                }
                if showCode {
                    codePanel
                        .frame(width: 380)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)
            if let problem = diagram.problem {
                DiagramProblem(text: problem) { diagram.clearProblem() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }
            GlowLine(clock: clock, mood: mood, paused: still)
                .padding(.horizontal, 26)
            inputRow
                .padding(.horizontal, 26)
                .padding(.top, 12)
                .padding(.bottom, 6)
            controls
                .onHover { reveal.hold($0) }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .background(GlassCard(clock: clock, mood: mood, paused: still, radius: 30))
        .padding(DiagramWindow.margin)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.2), value: showCode)
        .animation(.easeOut(duration: 0.2), value: diagram.problem)
        .onAppear { focused = true }
        .onChange(of: active) { if $0 == .key { focused = true } }
        .onChange(of: diagram.code) { code in editing = code }
        .onChange(of: diagram.busy) { busy in
            if busy {
                ink = clock.frame.hue
                clock.ripple(x: 0.5, y: 0.85, hue: ink + 180, power: 1.2)
            } else {
                clock.ripple(x: 0.5, y: 0.4, power: 0.7)
            }
        }
    }

    var still: Bool { mood == .idle && active == .inactive }

    var inputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Describe a diagram", text: $diagram.input,
                      prompt: Text(diagram.code.isEmpty ? "Describe a diagram… (or press the mic and say it)"
                                                        : "Ask for a change…").foregroundColor(.white.opacity(0.3)),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.prompt(ink))
                .tint(.white)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { diagram.send() }
                .frame(maxWidth: .infinity, alignment: .leading)
            DiagramMic(diagram: diagram, listener: diagram.listener, ink: ink)
            if diagram.busy {
                RoundButton(symbol: "stop.fill", help: "Stop (Esc)", enabled: true) { diagram.stop() }
            } else {
                RoundButton(symbol: "arrow.up", help: "Draw (Return)",
                            enabled: !diagram.input.trimmingCharacters(in: .whitespaces).isEmpty) { diagram.send() }
            }
        }
    }

    var controls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(kind: diagram.busy ? .thinking : diagram.problem != nil ? .trouble : .ready, hue: ink)
                Text(diagram.model.isEmpty ? "No model (Settings)" : ModelMenu.shortName(diagram.model))
                    .lineLimit(1)
                    .opacity(hovering ? 1 : 0)
            }
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.66))
            .padding(.leading, 8)
            .help("The diagram model is set in Settings (it's the chat's model unless you pick another)")
            Group {
                ActionChip(title: "Undo", symbol: "arrow.uturn.backward", help: "Back to the diagram before (again to come forward)") {
                    diagram.undo()
                }
                .disabled(!diagram.canUndo)
                .opacity(diagram.canUndo ? 1 : 0.4)
                ActionChip(title: showCode ? "Hide Mermaid" : "Mermaid", symbol: "chevron.left.forwardslash.chevron.right",
                           help: "See and edit the diagram's Mermaid") {
                    editing = diagram.code
                    showCode.toggle()
                }
                CopyButton(text: diagram.code)
                    .disabled(diagram.code.isEmpty)
                ActionChip(title: copiedSVG ? "Copied" : "Copy SVG", symbol: "photo", help: "Copy the drawing as SVG") {
                    canvas.svg { svg in
                        guard !svg.isEmpty else { return }
                        Clipboard.copy(svg)
                        copiedSVG = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copiedSVG = false }
                    }
                }
                .disabled(diagram.code.isEmpty)
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            Spacer(minLength: 6)
            Group {
                GlassIcon(symbol: "sparkles", help: "New diagram (⌘N)") { diagram.clear() }
                GlassIcon(symbol: pinned ? "pin.fill" : "pin",
                          help: pinned ? "Stays on top (click to let go)" : "Keep on top") {
                    pinned.toggle()
                    pin(pinned)
                }
                GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .frame(height: 30)
    }

    var codePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Mermaid")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let failed = diagram.failedCode {
                    ActionChip(title: "Load failed one", symbol: "exclamationmark.triangle",
                               help: "Put the Mermaid that didn't draw here, to fix it") { editing = failed }
                }
                PillButton(title: "Draw this", prominent: editing != diagram.code) { diagram.apply(editing) }
            }
            TextEditor(text: $editing)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

/// The microphone: say what to draw, and it's sent when you pause.
struct DiagramMic: View {
    @ObservedObject var diagram: DiagramModel
    @ObservedObject var listener: Listener
    let ink: Double

    var body: some View {
        Button { diagram.toggleMic() } label: {
            Image(systemName: listener.on ? "mic.fill" : "mic")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(listener.on ? Color.black : Color.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(listener.on ? Color.hsl(ink + 180, 0.9, 0.83) : Color.white.opacity(0.1)))
                .overlay(Circle().stroke(Color.hsl(ink + 180, 0.9, 0.83).opacity(listener.on ? 0.6 : 0), lineWidth: 2)
                    .scaleEffect(1 + CGFloat(listener.held ? 0 : listener.level) * 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
        .help(listener.problem ?? (listener.on ? "Listening: pause to send, click to stop" : "Say what to draw (it sends when you pause)"))
        .onChange(of: listener.text) { said in
            if listener.on && !listener.held { diagram.input = said }
        }
    }
}

/// What went wrong, with a way to copy it.
struct DiagramProblem: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ChatProblem.pink)
            Text(text)
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.84))
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyErrorButton(text: text)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ChatProblem.pink.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ChatProblem.pink.opacity(0.35), lineWidth: 0.5))
    }
}

// MARK: - The canvas

/// Mermaid, drawn in a see-through web view. Mermaid's script is downloaded once (from jsDelivr)
/// into ~/Library/Application Support/ToolMacTool/mermaid; after that it draws offline. Pinch to
/// zoom.
struct MermaidCanvas: NSViewRepresentable {
    @ObservedObject var diagram: DiagramModel
    let handle: Handle

    static let version = "11.4.1"
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ToolMacTool/mermaid")
    }
    static var script: URL { folder.appendingPathComponent("mermaid-\(version).min.js") }

    /// Lets the view ask the page for things (the SVG).
    @MainActor
    final class Handle {
        weak var web: WKWebView?

        func svg(_ done: @escaping (String) -> Void) {
            guard let web else { return done("") }
            web.evaluateJavaScript("svgText()") { result, _ in done(result as? String ?? "") }
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var diagram: DiagramModel
        var loaded = false
        var tried: Int?
        weak var web: WKWebView?

        init(diagram: DiagramModel) { self.diagram = diagram }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if json["ready"] as? Bool == true {
                Task { @MainActor in
                    self.loaded = true
                    let current = self.diagram.code
                    if !current.isEmpty { self.run("draw(\(Self.quote(current)), -1)") }
                    self.drawPending()
                }
                return
            }
            guard let id = json["id"] as? Int, id >= 0 else { return }
            let error = json["ok"] as? Bool == true ? nil : (json["error"] as? String ?? "unknown error")
            Task { @MainActor in self.diagram.drawn(id, error: error) }
        }

        @MainActor
        func drawPending() {
            guard loaded, let d = diagram.drawing, d.id != tried else { return }
            tried = d.id
            if d.code.isEmpty {
                run("clearStage(); post({id: \(d.id), ok: true})")
            } else {
                run("draw(\(Self.quote(d.code)), \(d.id))")
            }
        }

        @MainActor
        func run(_ js: String) {
            web?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// A string as a JavaScript literal.
        static func quote(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(diagram: diagram) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "tmt")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.allowsMagnification = true
        context.coordinator.web = web
        handle.web = web
        Self.load(into: web, diagram: diagram)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.diagram = diagram
        context.coordinator.drawPending()
    }

    /// Gets Mermaid's script (downloading it the first time), then opens the page.
    static func load(into web: WKWebView, diagram: DiagramModel) {
        Task { @MainActor in
            do {
                try await fetchScript()
                let page = folder.appendingPathComponent("canvas.html")
                try Data(html.utf8).write(to: page, options: .atomic)
                web.loadFileURL(page, allowingReadAccessTo: folder)
            } catch {
                diagram.report("Couldn't get Mermaid (it's downloaded once, from cdn.jsdelivr.net): \(error.localizedDescription)")
            }
        }
    }

    static func fetchScript() async throws {
        if FileManager.default.fileExists(atPath: script.path) { return }
        let url = URL(string: "https://cdn.jsdelivr.net/npm/mermaid@\(version)/dist/mermaid.min.js")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100_000 else {
            throw Ollama.Problem("the download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: script, options: .atomic)
    }

    static var html: String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; height: 100%; background: transparent; overflow: hidden;
                       font-family: -apple-system, "SF Pro Rounded", sans-serif; -webkit-user-select: none; }
          #stage { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; }
          #stage svg { display: block; }
          #empty { color: rgba(255,255,255,.28); font: 600 24px -apple-system, "SF Pro Rounded", sans-serif;
                   text-align: center; line-height: 1.4; }
        </style>
        <script src="mermaid-\(version).min.js"></script>
        </head><body>
        <div id="stage"><div id="empty">Your diagram appears here.<br>Describe it below, or press the mic and say it.</div></div>
        <script>
          const stage = document.getElementById('stage');
          const emptyHTML = stage.innerHTML;
          function post(m) { window.webkit.messageHandlers.tmt.postMessage(JSON.stringify(m)); }
          mermaid.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict',
            themeVariables: { background: 'transparent', fontFamily: '-apple-system, "SF Pro Rounded", sans-serif',
                              fontSize: '16px' } });
          let n = 0;
          function fit() {
            const svg = stage.querySelector('svg');
            if (!svg || !svg.viewBox || !svg.viewBox.baseVal) return;
            const box = svg.viewBox.baseVal;
            if (!box.width || !box.height) return;
            const w = stage.clientWidth - 16, h = stage.clientHeight - 16;
            const scale = Math.min(w / box.width, h / box.height, 2.5);
            svg.style.maxWidth = 'none';
            svg.setAttribute('width', box.width * scale);
            svg.setAttribute('height', box.height * scale);
          }
          async function draw(code, id) {
            const mine = 'm' + (++n);
            try {
              await mermaid.parse(code);
              const { svg } = await mermaid.render(mine, code);
              stage.innerHTML = svg;
              fit();
              post({ id: id, ok: true });
            } catch (e) {
              for (const x of [mine, 'd' + mine]) { const el = document.getElementById(x); if (el && !stage.contains(el)) el.remove(); }
              post({ id: id, ok: false, error: String((e && (e.message || e.str)) || e) });
            }
          }
          function clearStage() { stage.innerHTML = emptyHTML; }
          function svgText() { const s = stage.querySelector('svg'); return s ? s.outerHTML : ''; }
          window.addEventListener('resize', fit);
          post({ ready: true });
        </script>
        </body></html>
        """
    }
}

extension DiagramModel {
    /// A problem from outside (the canvas couldn't load).
    func report(_ text: String) {
        problem = text
    }
}
