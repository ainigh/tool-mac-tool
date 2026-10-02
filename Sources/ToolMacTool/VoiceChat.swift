import AppKit
import Combine
import SwiftUI
import ToolCore

/// Ties a chat to a voice, the way its kind needs:
/// - Chat 2 speaks each sentence of a reply as soon as it's complete, while the rest streams in.
/// - Chat 3 writes what you say into the box as you say it, and sends it when you pause.
/// - Chat 4 does both, hands-free: it stops listening while it thinks and talks (so it doesn't
///   hear itself), and listens again when it's done.
@MainActor
final class VoiceLink: ObservableObject {
    let chat: ChatModel
    let speaker: Speaker?
    let listener: Listener?
    /// Chat 2: replies are only written.
    @Published var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: "chat\(chat.kind.number)Muted")
            if muted { speaker?.stop() }
        }
    }

    private var stream = SentenceStream()
    private var watch: AnyCancellable?

    init(chat: ChatModel) {
        self.chat = chat
        speaker = chat.kind.speaks ? Speaker() : nil
        listener = chat.kind.listens ? Listener() : nil
        muted = UserDefaults.standard.bool(forKey: "chat\(chat.kind.number)Muted")
        listener?.pauseToEnd = chat.kind == .voice ? 1.1 : 1.6
        listener?.onUtterance = { [weak self] said in self?.heard(said) }
        speaker?.onDone = { [weak self] in self?.listenAgain() }
        chat.onReplyStart = { [weak self] in self?.replyStarted() }
        chat.onReplyText = { [weak self] text in self?.replyGrew(text) }
        chat.onReplyEnd = { [weak self] text, note in self?.replyEnded(text, note: note) }
        chat.onClear = { [weak self] in self?.cleared() }
        // Chat 3: what you're saying shows in the box as you say it.
        if chat.kind == .listens, let listener {
            watch = listener.$text.sink { [weak self] said in
                guard let self, listener.on, !listener.held else { return }
                self.chat.input = said
            }
        }
    }

    var talks: Bool { speaker != nil && !muted }

    /// The window came up: Chat 4 starts listening.
    func opened() {
        if chat.kind == .voice { listener?.start() }
    }

    /// The window went away: no more talking or listening.
    func closed() {
        speaker?.stop()
        listener?.stop()
    }

    func toggleMic() {
        guard let listener else { return }
        if listener.on {
            listener.stop()
        } else {
            listener.start()
        }
    }

    /// Chat 4's click or space bar: stop the reply (thinking or talking) and listen. While it's
    /// listening, it sends what's been said so far without waiting for the pause.
    func interrupt() {
        if chat.phase != .idle || speaker?.speaking == true {
            chat.stop()
            speaker?.stop()
            listenAgain()
        } else if let listener, listener.on, !listener.text.isEmpty {
            listener.endUtterance()
        } else if let listener, !listener.on {
            listener.start()
        }
    }

    private func heard(_ said: String) {
        chat.input = said
        chat.send(spoken: true)
    }

    private func replyStarted() {
        stream = SentenceStream()
        speaker?.stop()
        listener?.hold()
    }

    private func replyGrew(_ text: String) {
        guard talks, let speaker else { return }
        for sentence in stream.update(text) { speaker.say(sentence) }
    }

    private func replyEnded(_ text: String, note: String) {
        guard let speaker, talks else {
            listenAgain()
            return
        }
        if note == "stopped" {
            speaker.stop()
        } else {
            for sentence in stream.finish(text) { speaker.say(sentence) }
            if text.isEmpty && chat.kind == .voice { speaker.say("Sorry, I couldn't get a reply.") }
        }
        if !speaker.speaking { listenAgain() }
    }

    private func cleared() {
        stream = SentenceStream()
        speaker?.stop()
        listenAgain()
    }

    private func listenAgain() {
        guard chat.phase == .idle, speaker?.speaking != true else { return }
        listener?.release()
    }
}

// MARK: - Chat 4: talk and listen, nothing to type in

@MainActor
enum VoiceChatWindow {
    static func show(_ chat: ChatModel, link: VoiceLink) {
        Windows.show(chat.kind.windowID) {
            let size = CGSize(width: VoiceChatView.width, height: VoiceChatView.height)
            let panel = GlassPanel(size: ChatWindow.frame(for: size))
            panel.level = .floating
            let close = {
                link.closed()
                panel.orderOut(nil)
            }
            let host = FirstClickHostingView(rootView: VoiceChatView(chat: chat, link: link, listener: link.listener!,
                                                                     speaker: link.speaker!, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close, "n": { chat.newChat() }]
            panel.onKey = { key in
                guard key == " " else { return false }
                link.interrupt()
                return true
            }
            // Esc: stop the reply; when there's none, stop or start listening.
            panel.onEscape = {
                if chat.phase != .idle || link.speaker?.speaking == true {
                    link.interrupt()
                } else {
                    link.toggleMic()
                }
                return true
            }
            if !panel.setFrameUsingName("ToolMacTool.\(chat.kind.windowID)"), let screen = NSScreen.main {
                let v = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 8, y: v.maxY - panel.frame.height))
            }
            panel.setFrameAutosaveName("ToolMacTool.\(chat.kind.windowID)")
            return panel
        }
        link.opened()
        chat.loadModels()
    }
}

/// The glass with no box: what it's saying above the line, what you're saying below it, and
/// a light that says whose turn it is. Clicking the glass (or the space bar) interrupts it.
struct VoiceChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var link: VoiceLink
    @ObservedObject var listener: Listener
    @ObservedObject var speaker: Speaker
    let close: () -> Void

    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @State private var hovering = false
    @Environment(\.controlActiveState) private var active

    static let width: CGFloat = 520
    static let height: CGFloat = 460

    enum Turn { case off, listening, hearing, thinking, speaking, trouble }

    var turn: Turn {
        if chat.phase == .thinking { return .thinking }
        if speaker.speaking || chat.phase == .streaming { return .speaking }
        if listener.problem != nil || chat.problem != nil { return .trouble }
        if !listener.on || listener.held { return .off }
        return listener.text.isEmpty ? .listening : .hearing
    }

    var mood: GlassMood {
        switch turn {
        case .thinking: return .thinking
        case .speaking: return .streaming
        case .hearing: return .typing
        case .trouble: return .error
        case .listening, .off: return .idle
        }
    }

    var status: (StatusDot.Kind, String) {
        switch turn {
        case .off: return (.trouble, "Not listening: click to start")
        case .listening: return (.ready, "Listening…")
        case .hearing: return (.streaming, "Hearing you…")
        case .thinking: return (.thinking, "Thinking…")
        case .speaking: return (.streaming, "Speaking: click to interrupt")
        case .trouble: return (.trouble, "Something's wrong")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            said
                .padding(.horizontal, 26)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity)
            GlowLine(clock: clock, mood: mood, paused: false)
                .padding(.horizontal, 26)
                .scaleEffect(x: 1, y: 1 + CGFloat(listener.level) * 2)
            hearing
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(height: 150)
        }
        .frame(width: Self.width, height: Self.height)
        .background(GlassCard(clock: clock, mood: mood, swell: turn == .hearing || turn == .speaking,
                              paused: mood == .idle && active == .inactive))
        .contentShape(Rectangle())
        .onTapGesture { link.interrupt() }
        .onHover { h in
            withAnimation(h ? .easeOut(duration: 0.3) : .easeInOut(duration: 1.6)) { hovering = h }
        }
        .padding(ChatWindow.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onChange(of: listener.level) { level in
            if level > 0.45 && !listener.held { clock.nudge(0.05) }
        }
        .onChange(of: chat.phase) { phase in
            if phase == .thinking {
                ink = clock.frame.hue
                clock.ripple(x: 0.5, y: 0.8, hue: ink + 180, power: 1.2)
            }
        }
    }

    var bar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 9) {
                StatusDot(kind: status.0, hue: ink)
                Text(status.1).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.leading, 8)
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            HStack(spacing: 6) {
                GlassIcon(symbol: "brain", help: "Memory (MEMORY.md)") { MemoryWindow.show() }
                GlassIcon(symbol: "sparkles", help: "New conversation (⌘N)") { chat.newChat() }
                    .disabled(chat.messages.isEmpty)
                GlassIcon(symbol: listener.on ? "mic.fill" : "mic.slash",
                          help: listener.on ? "Stop listening (Esc)" : "Listen (Esc)") { link.toggleMic() }
                GlassIcon(symbol: "xmark", help: "Close (⌘W): stops listening", action: close)
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
    }

    /// The reply being spoken (or the last one), large; problems and memory questions under it.
    var said: some View {
        let reply = chat.messages.last(where: { $0.role == .assistant })?.text ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if !reply.isEmpty {
                    FittedReply(text: reply, ink: ink, live: chat.phase != .idle)
                } else if chat.phase == .thinking {
                    Caret(hue: ink)
                } else if chat.messages.isEmpty {
                    Text("Say something. I'm listening.")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.reply(ink))
                        .opacity(0.55)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ForEach(chat.messages.filter { $0.role == .proposal }) { m in
                ProposalRow(chat: chat, message: m)
            }
            if let problem = listener.problem {
                VoiceProblem(text: problem, action: "Try again") { listener.start() }
            } else if chat.problem != nil {
                ChatProblem(chat: chat)
            }
        }
    }

    /// What you're saying, as it's heard; the last thing you said while it answers.
    var hearing: some View {
        let lastAsk = chat.messages.last(where: { $0.role == .user })?.text ?? ""
        let live = listener.on && !listener.held
        let text = live && !listener.text.isEmpty ? listener.text : lastAsk
        return VStack(alignment: .leading, spacing: 8) {
            Text(text.isEmpty ? (live ? "…" : "") : text)
                .font(.system(size: text.count < 80 ? 26 : 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.prompt(ink))
                .opacity(live && !listener.text.isEmpty ? 1 : 0.5)
                .lineLimit(4)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                KeyHint(key: "space", does: "interrupt / send now")
                KeyHint(key: "esc", does: listener.on ? "stop listening" : "listen")
                Spacer()
                Text("Pauses send what you said")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
        }
    }
}

/// A problem with the voice (a permission, no microphone), with a way to try again.
struct VoiceProblem: View {
    let text: String
    let action: String
    let run: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ChatProblem.pink)
            Text(text)
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.84))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if text.contains("System Settings") {
                PillButton(title: "Open Settings") { VoiceProblem.openPrivacy(text) }
            }
            PillButton(title: action, action: run)
        }
        .font(.system(size: 11.5, weight: .medium, design: .rounded))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ChatProblem.pink.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ChatProblem.pink.opacity(0.35), lineWidth: 0.5))
    }

    /// The privacy page the problem names.
    static func openPrivacy(_ problem: String) {
        let pane = problem.contains("Microphone") ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Chat 2 and 3: the voice controls on the typing chat

/// Chat 2's speaker button: speaking (click to mute), or muted.
struct SpeakToggle: View {
    @ObservedObject var link: VoiceLink
    @ObservedObject var speaker: Speaker

    var body: some View {
        GlassIcon(symbol: link.muted ? "speaker.slash" : speaker.speaking ? "speaker.wave.3.fill" : "speaker.wave.2",
                  help: link.muted ? "Replies are only written: click to have them spoken"
                                   : speaker.speaking ? "Speaking: click to mute" : "Replies are spoken: click to mute") {
            link.muted.toggle()
        }
    }
}

/// Chat 3's microphone: off, or on with a ring that moves with your voice. Pausing sends.
struct MicButton: View {
    @ObservedObject var link: VoiceLink
    @ObservedObject var listener: Listener
    let ink: Double

    var body: some View {
        Button { link.toggleMic() } label: {
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
        .animation(.easeOut(duration: 0.08), value: listener.level)
        .help(listener.on ? "Listening: pause to send, click to stop" : "Talk instead of typing (it sends when you pause)")
    }
}
