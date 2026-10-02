import AppKit
import Combine
import SwiftUI
import ToolCore

/// Ties the chat to a voice, the way its mode needs:
/// - "Type, hear the reply" speaks each sentence of a reply as soon as it's complete, while the
///   rest streams in.
/// - "Talk, read the reply" writes what you say into the box as you say it, and sends it when you
///   pause.
/// - "Conversation" does both, hands-free: it stops listening while it thinks and talks (so it
///   doesn't hear itself), and listens again when it's done.
@MainActor
final class VoiceLink: ObservableObject {
    let chat: ChatModel
    let speaker = Speaker()
    let listener = Listener()
    /// Replies are only written, even in a mode that speaks.
    @Published var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: "chatMuted")
            if muted { speaker.stop() }
        }
    }
    /// The chat's window is on screen.
    private(set) var visible = false

    private var stream = SentenceStream()
    private var watches: [AnyCancellable] = []

    init(chat: ChatModel) {
        self.chat = chat
        muted = UserDefaults.standard.bool(forKey: "chatMuted")
        listener.onUtterance = { [weak self] said in self?.heard(said) }
        speaker.onDone = { [weak self] in self?.listenAgain() }
        chat.onReplyStart = { [weak self] in self?.replyStarted() }
        chat.onReplyText = { [weak self] text in self?.replyGrew(text) }
        chat.onReplyEnd = { [weak self] text, note in self?.replyEnded(text, note: note) }
        chat.onClear = { [weak self] in self?.cleared() }
        // Talking into the box: what you're saying shows in it as you say it.
        watches.append(listener.$text.sink { [weak self] said in
            guard let self, self.chat.mode == .listens, self.listener.on, !self.listener.held else { return }
            self.chat.input = said
        })
        // @Published hands over the new mode before it's set.
        watches.append(chat.$mode.dropFirst().removeDuplicates().sink { [weak self] mode in
            self?.switched(to: mode)
        })
        prepare(chat.mode)
    }

    var mode: ChatKind { chat.mode }
    var talks: Bool { mode.speaks && !muted }

    /// Gets the models a mode needs ready (downloading them the first time) before they're needed.
    private func prepare(_ mode: ChatKind) {
        if mode.speaks { _ = Neural.shared.voiceModel() }
        if mode.listens { _ = Neural.shared.earModel() }
        listener.pauseToEnd = mode == .voice ? 1.1 : 1.6
    }

    private func switched(to mode: ChatKind) {
        prepare(mode)
        if !mode.speaks { speaker.stop() }
        if !mode.listens || mode == .listens { listener.stop() }
        if mode == .voice && visible && chat.phase == .idle { listener.start() }
    }

    /// The window came up: a conversation starts listening.
    func opened() {
        visible = true
        if mode == .voice { listener.start() }
    }

    /// The window went away: no more talking or listening.
    func closed() {
        visible = false
        speaker.stop()
        listener.stop()
    }

    func toggleMic() {
        if listener.on {
            listener.stop()
        } else {
            listener.start()
        }
    }

    /// Stops whatever's going on: the reply, the voice, then the microphone. False when there
    /// was nothing to stop.
    func stopSomething() -> Bool {
        if chat.phase != .idle {
            chat.stop()
            speaker.stop()
        } else if speaker.speaking {
            speaker.stop()
        } else if listener.on {
            listener.stop()
        } else {
            return false
        }
        return true
    }

    /// A conversation's click or space bar: stop the reply (thinking or talking) and listen. While
    /// it's listening, it sends what's been said so far without waiting for the pause.
    func interrupt() {
        if chat.phase != .idle || speaker.speaking {
            chat.stop()
            speaker.stop()
            listenAgain()
        } else if listener.on, !listener.text.isEmpty {
            listener.endUtterance()
        } else if !listener.on {
            listener.start()
        }
    }

    private func heard(_ said: String) {
        guard mode.listens else { return }
        chat.input = said
        chat.send(spoken: true)
    }

    private func replyStarted() {
        stream = SentenceStream()
        speaker.stop()
        listener.hold()
    }

    private func replyGrew(_ text: String) {
        guard talks else { return }
        for sentence in stream.update(text) { speaker.say(sentence) }
    }

    private func replyEnded(_ text: String, note: String) {
        guard talks else {
            listenAgain()
            return
        }
        if note == "stopped" {
            speaker.stop()
        } else {
            for sentence in stream.finish(text) { speaker.say(sentence) }
            if text.isEmpty && mode == .voice { speaker.say("Sorry, I couldn't get a reply.") }
        }
        if !speaker.speaking { listenAgain() }
    }

    private func cleared() {
        stream = SentenceStream()
        speaker.stop()
        listenAgain()
    }

    private func listenAgain() {
        guard chat.phase == .idle, !speaker.speaking else { return }
        listener.release()
    }
}

// MARK: - Conversation: talk and listen, nothing to type in

/// The glass with no box: what it's saying above the line, what you're saying below it, and
/// along the bottom a light that says whose turn it is (the controls fade in beside it while the
/// pointer is over the glass). Clicking the glass (or the space bar) interrupts it.
struct VoiceChatView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var link: VoiceLink
    @ObservedObject var listener: Listener
    @ObservedObject var speaker: Speaker
    let close: () -> Void
    let pin: (Bool) -> Void
    let resize: (CGSize) -> Void

    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @State private var hovering = false
    @Environment(\.controlActiveState) private var active

    static let width: CGFloat = 520
    static let height: CGFloat = 460
    static let size = CGSize(width: width, height: height)

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
        case .listening: return (.ready, "Listening… (pauses send)")
        case .hearing: return (.streaming, "Hearing you… (space sends now)")
        case .thinking: return (.thinking, "Thinking…")
        case .speaking: return (.streaming, "Speaking: click to interrupt")
        case .trouble: return (.trouble, "Something's wrong")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            said
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity)
            GlowLine(clock: clock, mood: mood, paused: false)
                .padding(.horizontal, 26)
                .scaleEffect(x: 1, y: 1 + CGFloat(listener.level) * 2)
            hearing
                .padding(.horizontal, 26)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .frame(height: 120)
            ChatControls(chat: chat, link: link, ink: ink, show: hovering, collapsed: nil, voiceStatus: status,
                         close: close, pin: pin)
                .padding(.leading, 14)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
        }
        .frame(width: Self.width, height: Self.height)
        .background(GlassCard(clock: clock, mood: mood, swell: turn == .hearing || turn == .speaking,
                              paused: mood == .idle && active == .inactive))
        .contentShape(Rectangle())
        .onTapGesture { link.interrupt() }
        .onHover { h in
            withAnimation(h ? .easeOut(duration: 0.25) : .easeInOut(duration: 1.2)) { hovering = h }
        }
        .padding(ChatWindow.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { resize(Self.size) }
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
            if let note = chat.messages.last, note.role == .note {
                MemoryNote(chat: chat, note: note, all: [note])
                    .font(.system(size: 11, weight: .medium, design: .rounded))
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
        return Text(text.isEmpty ? (live ? "…" : "") : text)
            .font(.system(size: text.count < 80 ? 26 : 19, weight: .semibold, design: .rounded))
            .foregroundStyle(Ink.prompt(ink))
            .opacity(live && !listener.text.isEmpty ? 1 : 0.5)
            .lineLimit(4)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            CopyErrorButton(text: text)
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

    /// The microphone's privacy page (the only permission the voice tools need).
    static func openPrivacy(_ problem: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - The voice controls on the typing chat

/// The speaker button (in the modes that speak): speaking (click to mute), or muted.
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

/// The microphone beside the box (talking instead of typing): off, or on with a ring that moves
/// with your voice. Pausing sends.
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
