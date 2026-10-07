import AppKit
import SwiftUI
import ToolCore

/// The chat's own window: borderless and clear, sized to the glass panel plus a margin for its
/// glow, so nothing invisible sits over other windows. It's just the box you type in when there's
/// nothing to show, and opens into the full panel when there's a conversation. In a conversation
/// (talk and listen) it holds the voice view instead. Drag it by any part that isn't a control.
@MainActor
enum ChatWindow {
    /// Room around the panel for its glow (and for it to swell into).
    static let margin: CGFloat = 30
    static let id = "chat"

    static func show(_ chat: ChatModel, link: VoiceLink) {
        Windows.show(id) {
            let card = chat.mode == .voice ? VoiceChatView.size
                : ChatView.cardSize(small: chat.messages.isEmpty, smallHeight: nil)
            let panel = GlassPanel(size: frame(for: card))
            panel.dragsAnywhere = true
            panel.level = chat.pinned ? .floating : .normal
            let close = {
                link.closed()
                panel.orderOut(nil)
            }
            link.onClose = close
            ModelTools.shared.closeChat = close
            let reveal = Reveal()
            panel.onDoubleClick = { reveal.toggle() }
            let view = ChatRoot(chat: chat, link: link, reveal: reveal, close: close,
                                pin: { on in panel.level = on ? .floating : .normal },
                                resize: { card in resize(panel, to: card, animate: true) })
            let host = FirstClickHostingView(rootView: view)
            host.sizingOptions = []          // the window sets the size; the view fills it
            panel.contentView = host
            var commands: [String: () -> Void] = ["w": close, "n": { chat.newChat() }]
            for n in 1...SystemPrompt.limit { commands["\(n)"] = { chat.choosePrompt(number: n) } }
            panel.commands = commands
            // In a conversation the space bar interrupts (or sends what you said so far).
            panel.onKey = { key in
                guard key == " ", chat.mode == .voice else { return false }
                link.interrupt()
                return true
            }
            // Esc stops a reply, then the voice, then the microphone; with nothing going on and
            // nothing typed, it puts the chat away. In a conversation it stops or starts listening.
            panel.onEscape = {
                if chat.mode == .voice {
                    if chat.phase != .idle || link.speaker.speaking { link.interrupt() } else { link.toggleMic() }
                    return true
                }
                if link.stopSomething() { return true }
                if chat.input.isEmpty {
                    close()
                    return true
                }
                return false
            }
            if !panel.setFrameUsingName("ToolMacTool.\(id)"), let screen = NSScreen.main {
                let v = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 8, y: v.maxY - panel.frame.height))
            }
            resize(panel, to: card, animate: false)
            panel.setFrameAutosaveName("ToolMacTool.\(id)")
            return panel
        }
        link.opened()
        chat.loadModels()
    }

    static func frame(for card: CGSize) -> NSSize {
        NSSize(width: card.width + 2 * margin, height: card.height + 2 * margin)
    }

    /// Resizes the window around a panel of this size, keeping its top edge where it is.
    static func resize(_ panel: NSWindow, to card: CGSize, animate: Bool) {
        let size = frame(for: card)
        var f = panel.frame
        if f.size == size { return }
        f.origin.y += f.height - size.height
        f.size = size
        panel.setFrame(f, display: true, animate: animate)
    }
}

/// The chat in its mode: the typing chat, or the voice view of a conversation.
struct ChatRoot: View {
    @ObservedObject var chat: ChatModel
    let link: VoiceLink
    let reveal: Reveal
    let close: () -> Void
    let pin: (Bool) -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        if chat.mode == .voice {
            VoiceChatView(chat: chat, link: link, listener: link.listener, speaker: link.speaker,
                          close: close, pin: pin, resize: resize, reveal: reveal)
        } else {
            ChatView(chat: chat, link: link, close: close, pin: pin, resize: resize, reveal: reveal)
        }
    }
}

/// The chat, laid out like Glass's own page: a glass panel split by a glowing line. Above it, the
/// reply, as large as it fits, in the colors moving behind the glass. Below it, what you're
/// typing, in the opposite colors, and under that a row of controls, hidden until you
/// double-click the glass. With nothing to show, only the box and the controls are there.
struct ChatView: View {
    @ObservedObject var chat: ChatModel
    let link: VoiceLink
    let close: () -> Void
    let pin: (Bool) -> Void
    let resize: (CGSize) -> Void

    /// The controls, shown by a double-click.
    @ObservedObject var reveal: Reveal
    var hovering: Bool { reveal.shown }

    @State private var collapsed = false
    @State private var clock = GlassClock()
    /// The hue the words take: picked up from the moving glass each time you send (so they don't
    /// change color under you while you read or select them).
    @State private var ink = Double.random(in: 0..<360)
    @State private var swell = false
    @State private var swellCount = 0
    @State private var typing = false
    @State private var typingCount = 0
    /// The small panel's height, measured, so it fits what's in it (a problem, a long message).
    @State private var smallHeight: CGFloat?
    @Environment(\.controlActiveState) private var active

    static let width: CGFloat = 520
    static let height: CGFloat = 600
    /// The part below the line, when the panel is open (the box and the controls).
    static let promptHeight: CGFloat = 200

    static func cardSize(small: Bool, smallHeight: CGFloat?) -> CGSize {
        small ? CGSize(width: width, height: smallHeight ?? 112) : CGSize(width: width, height: height)
    }

    var small: Bool { collapsed || chat.messages.isEmpty }
    var cardSize: CGSize { Self.cardSize(small: small, smallHeight: smallHeight) }

    var mood: GlassMood {
        switch chat.phase {
        case .thinking: return .thinking
        case .streaming: return .streaming
        case .idle: return chat.problem != nil ? .error : typing ? .typing : .idle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            top
            if !small {
                GlowLine(clock: clock, mood: mood, paused: still)
                    .padding(.horizontal, 26)
            }
            VStack(spacing: 0) {
                PromptWell(chat: chat, link: link, ink: ink, small: small, sent: sent)
                    .padding(.horizontal, 26)
                    .padding(.top, small ? 14 : 16)
                    .padding(.bottom, 8)
                    .frame(maxHeight: small ? nil : .infinity)
                ChatControls(chat: chat, link: link, ink: ink, show: hovering,
                             collapsed: chat.messages.isEmpty ? nil : $collapsed, voiceStatus: nil,
                             close: close, pin: pin)
                    .onHover { reveal.hold($0) }
                    .padding(.leading, 18)
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
            }
            .frame(height: small ? nil : Self.promptHeight)
        }
        .frame(width: Self.width, height: small ? nil : Self.height)
        .fixedSize(horizontal: false, vertical: small)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { if small { smallHeight = g.size.height } }
                .onChange(of: g.size.height) { h in if small { smallHeight = h } }
        })
        .background(GlassCard(clock: clock, mood: mood, swell: swell, paused: still))
        .padding(ChatWindow.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(active == .inactive ? 0.94 : 1)
        .animation(.easeInOut(duration: 0.25), value: active)
        .animation(.easeOut(duration: 0.2), value: chat.problem)
        .environment(\.colorScheme, .dark)
        .onAppear { resize(cardSize) }
        .onChange(of: cardSize) { resize($0) }
        .onChange(of: chat.phase) { phase in
            // Sending from the shrunken panel opens it up again, so the reply can be seen.
            if phase == .thinking { collapsed = false }
            if phase == .idle { clock.ripple(x: 0.5, y: 0.3, power: 0.6) }
        }
        .onChange(of: chat.messages.last?.text) { _ in puff() }
        .onChange(of: chat.input) { _ in
            puff()
            keyPressed()
        }
    }

    /// Calm and in the background: the glass holds still.
    var still: Bool { mood == .idle && active == .inactive }

    var top: some View {
        VStack(spacing: 0) {
            ListenerProblem(listener: link.listener, mode: chat.mode)
            if !small {
                ReplyWell(chat: chat, ink: ink)
                    .padding(.horizontal, 26)
                    .padding(.top, 20)
                    .padding(.bottom, 14)
                    .frame(maxHeight: .infinity)
            } else if chat.problem != nil {
                ChatProblem(chat: chat)
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
            }
        }
    }

    /// You sent something: a ring spreads from the box and the glass livens up.
    func sent() {
        clock.nudge()
        clock.ripple(x: 0.5, y: 0.8, hue: ink + 180, power: 1.2)
        ink = clock.frame.hue
    }

    /// The glass swells when text changes and smooths out again 15 seconds after the last change.
    func puff() {
        if !swell {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) { swell = true }
        }
        swellCount += 1
        let mine = swellCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard mine == swellCount else { return }
            withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: 2.6)) { swell = false }
        }
    }

    /// Typing livens the glass a little, until you stop for a moment.
    func keyPressed() {
        typing = !chat.input.isEmpty
        typingCount += 1
        let mine = typingCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if mine == typingCount { typing = false }
        }
    }
}

// MARK: - The controls, along the bottom

/// The row along the bottom of the glass. The status light is always there; the rest fades in
/// while the pointer is over the panel: the model, how you talk (the mode), the system prompt,
/// memory on or off, the voice, more (memory, prompts, settings), and on the right new chat,
/// shrink, keep on top and close. The empty space in it moves the window, like the rest of the glass.
struct ChatControls: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var link: VoiceLink
    let ink: Double
    let show: Bool
    /// Shrink to just the box (the typing chat, with a conversation).
    let collapsed: Binding<Bool>?
    /// A conversation's status ("Listening…"), shown instead of the model's name.
    let voiceStatus: (StatusDot.Kind, String)?
    let close: () -> Void
    let pin: (Bool) -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let voiceStatus {
                HStack(spacing: 9) {
                    StatusDot(kind: voiceStatus.0, hue: ink)
                    Text(voiceStatus.1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 230, alignment: .leading)
                }
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.66))
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .fixedSize()
                .help(voiceStatus.1)
            } else {
                ChatStatus(chat: chat, ink: ink, showName: show)
            }
            Group {
                GlassIcon(symbol: chat.mode.symbol, help: "How you talk: \(chat.mode.title) (click to change)") {
                    ChatMenus.mode(chat)
                }
                PromptChip(chat: chat)
                MemoryToggle(chat: chat)
                if chat.mode.speaks {
                    SpeakToggle(link: link, speaker: link.speaker)
                }
                if chat.mode == .voice {
                    GlassIcon(symbol: link.listener.on ? "mic.fill" : "mic.slash",
                              help: link.listener.on ? "Stop listening (Esc)" : "Listen (Esc)") { link.toggleMic() }
                }
                GlassIcon(symbol: "ellipsis", help: "Model, memory, prompts and settings") { ChatMenus.more(chat) }
            }
            .opacity(show ? 1 : 0)
            .allowsHitTesting(show)
            Spacer(minLength: 4)
            Group {
                GlassIcon(symbol: "sparkles", help: "New chat (⌘N)") { chat.newChat() }
                    .disabled(chat.messages.isEmpty && chat.phase == .idle)
                if let collapsed {
                    GlassIcon(symbol: collapsed.wrappedValue ? "chevron.down" : "chevron.up",
                              help: collapsed.wrappedValue ? "Show the conversation" : "Shrink to just the box") {
                        collapsed.wrappedValue.toggle()
                    }
                }
                GlassIcon(symbol: chat.pinned ? "pin.fill" : "pin",
                          help: chat.pinned ? "Stays on top (click to let go)" : "Keep on top") {
                    chat.pinned.toggle()
                    pin(chat.pinned)
                }
                GlassIcon(symbol: "xmark", help: "Close (⌘W, or Esc when the box is empty)", action: close)
            }
            .opacity(show ? 1 : 0)
            .offset(y: show ? 0 : 4)
            .allowsHitTesting(show)
        }
        .frame(height: 30)
    }
}

/// The colored light and what's going on (the model's name when it's ready, shown on hover).
/// Clicking it lists the models Ollama has.
struct ChatStatus: View {
    @ObservedObject var chat: ChatModel
    let ink: Double
    let showName: Bool
    @State private var hover = false

    var kind: StatusDot.Kind {
        switch chat.phase {
        case .thinking: return .thinking
        case .streaming: return .streaming
        case .idle: return chat.problem != nil || chat.model.isEmpty ? .trouble : .ready
        }
    }

    var label: String {
        switch chat.phase {
        case .thinking: return chat.activity ?? "Thinking…"
        case .streaming: return "Replying…"
        case .idle:
            if chat.model.isEmpty { return "No model" }
            return ModelMenu.shortName(chat.model)
        }
    }

    var body: some View {
        Button { ModelMenu.show(chat) } label: {
            HStack(spacing: 8) {
                StatusDot(kind: kind, hue: ink)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 104, alignment: .leading)
                    .opacity(showName ? 1 : 0)
            }
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(hover && showName ? 0.1 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help((chat.model.isEmpty ? "Pick a model (from Ollama)" : "\(chat.model) (from Ollama): click to switch")
              + "\n\nDouble-click the glass to show the controls.")
    }
}

/// The system prompt in use, by name: click for the others (⌘1 to ⌘9 pick them too).
struct PromptChip: View {
    @ObservedObject var chat: ChatModel
    @State private var hover = false

    var body: some View {
        let number = (chat.settings.prompts.firstIndex { $0.id == chat.prompt.id } ?? 0) + 1
        Button { ChatMenus.prompts(chat) } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(chat.prompt.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 76, alignment: .leading)
            }
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(hover ? 0.95 : 0.72))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(.white.opacity(hover ? 0.14 : 0.06)))
            .overlay(Capsule().stroke(.white.opacity(hover ? 0.28 : 0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("System prompt: \(chat.prompt.name) (⌘\(number)). Click to switch or edit them.")
    }
}

/// Memory on (MEMORY.md goes with each message, and the model keeps it up to date) or off.
struct MemoryToggle: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        GlassIcon(symbol: "brain",
                  help: chat.memoryOn ? "Memory is on: MEMORY.md goes with every message, and the model keeps it up to date. Click to turn it off for this chat."
                                      : "Memory is off for this chat: nothing is read or saved. Click to turn it on.") {
            chat.memoryOn.toggle()
        }
        .overlay {
            if !chat.memoryOn {
                Capsule().fill(Color.white.opacity(0.7))
                    .frame(width: 1.5, height: 17)
                    .rotationEffect(.degrees(-45))
                    .allowsHitTesting(false)
            }
        }
        .opacity(chat.memoryOn ? 1 : 0.6)
    }
}

/// The chat's menus, as plain AppKit menus at the pointer: they work the same in any window,
/// borderless or not.
@MainActor
enum ChatMenus {
    static func pop(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// How you talk, and which voice answers.
    static func mode(_ chat: ChatModel) {
        let menu = NSMenu()
        menu.addItem(header("How you talk"))
        for kind in ChatKind.allCases {
            let item = ActionMenuItem(title: kind.title) { chat.mode = kind }
            item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
            item.state = kind == chat.mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(header("Voice (and its persona)"))
        for voice in NeuralVoice.all {
            let item = ActionMenuItem(title: VoiceSettings.label(voice)) {
                VoiceSettings.voice = voice
                chat.objectWillChange.send()
                Speaker.preview()
            }
            item.state = voice == VoiceSettings.voice ? .on : .off
            menu.addItem(item)
        }
        pop(menu)
    }

    /// The system prompts (⌘1 to ⌘9), and a way to edit them.
    static func prompts(_ chat: ChatModel) {
        let menu = NSMenu()
        menu.addItem(header("System prompt"))
        for (i, p) in chat.settings.prompts.enumerated() {
            let item = ActionMenuItem(title: p.name) { chat.promptID = p.id }
            item.keyEquivalent = "\(i + 1)"
            item.keyEquivalentModifierMask = .command
            item.state = p.id == chat.prompt.id ? .on : .off
            item.toolTip = p.text
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Edit prompts and personas…") { PromptsWindow.show() })
        pop(menu)
    }

    /// The model, the memory file, the prompts, the settings.
    static func more(_ chat: ChatModel) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let models = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        models.submenu = ModelMenu.menu(chat)
        menu.addItem(models)
        menu.addItem(.separator())
        let count = chat.settings.builtins.filter(\.enabled).count + ShortcutTool.callable(chat.settings.shortcuts).count
        let tools = ActionMenuItem(title: "Use tools (\(count))") { chat.toolsOn.toggle() }
        tools.state = chat.toolsOn && chat.settings.toolsOn ? .on : .off
        tools.isEnabled = chat.settings.toolsOn && count > 0
        menu.addItem(tools)
        menu.addItem(ActionMenuItem(title: "Model tools…") { ModelToolsWindow.show() })
        menu.addItem(ActionMenuItem(title: "Shortcuts as tools…") { ToolsWindow.show() })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Edit memory (MEMORY.md)…") { MemoryWindow.show() })
        menu.addItem(ActionMenuItem(title: "Edit prompts and personas…") { PromptsWindow.show() })
        menu.addItem(ActionMenuItem(title: "Settings…") { SettingsWindow.show() })
        pop(menu)
    }

    static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// The models Ollama has, in a menu.
@MainActor
enum ModelMenu {
    /// "llama3.2:latest" reads as "llama3.2": the tag only shows when it says something.
    static func shortName(_ model: String) -> String {
        model.hasSuffix(":latest") ? String(model.dropLast(":latest".count)) : model
    }

    static func menu(_ chat: ChatModel) -> NSMenu {
        let menu = NSMenu()
        if chat.models.isEmpty {
            let none = NSMenuItem(title: "No models yet (is Ollama running?)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for name in chat.models {
            let item = ActionMenuItem(title: name) { chat.model = name }
            item.state = name == chat.model ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "Look again") { chat.loadModels() })
        return menu
    }

    /// A plain AppKit menu at the pointer: it works the same in any window, borderless or not.
    static func show(_ chat: ChatModel) {
        ChatMenus.pop(menu(chat))
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

// MARK: - The reply, above the line

/// One thing you said and the reply to it, with what was remembered after it.
struct Exchange: Identifiable {
    let id: UUID
    let ask: String
    var reply: ChatModel.Message?
    /// What was remembered or forgotten after it.
    var notes: [ChatModel.Message] = []

    static func group(_ messages: [ChatModel.Message]) -> [Exchange] {
        var out: [Exchange] = []
        for m in messages {
            switch m.role {
            case .user:
                out.append(Exchange(id: m.id, ask: m.text))
            case .assistant:
                if let last = out.indices.last, out[last].reply == nil { out[last].reply = m }
            case .note:
                if let last = out.indices.last { out[last].notes.append(m) }
            case .proposal:
                break
            }
        }
        return out
    }
}

/// The newest reply fills the space above the line, as large as it fits. When a new one starts,
/// the old one slides away. The arrows under it step back through the conversation.
struct ReplyWell: View {
    @ObservedObject var chat: ChatModel
    let ink: Double
    /// Which exchange is shown; nil for the newest.
    @State private var page: Int?

    var body: some View {
        let exchanges = Exchange.group(chat.messages)
        let newest = exchanges.count - 1
        let index = min(page ?? newest, newest)
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if index >= 0 {
                    exchangeView(exchanges[index], isNewest: index == newest)
                        .id(exchanges[index].id)
                        .transition(.asymmetric(insertion: .opacity,
                                                removal: .offset(x: 40).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.timingCurve(0.65, 0, 0.25, 1, duration: 0.42), value: index >= 0 ? exchanges[index].id : nil)
            if index >= 0 {
                ReplyActions(chat: chat, exchange: exchanges[index], isNewest: index == newest,
                             page: index, pages: exchanges.count) { page = $0 >= newest ? nil : $0 }
            }
            ForEach(chat.messages.filter { $0.role == .proposal }) { m in
                ProposalRow(chat: chat, message: m)
            }
            if chat.problem != nil {
                ChatProblem(chat: chat)
            }
        }
        .onChange(of: exchanges.last?.id) { _ in page = nil }
    }

    func exchangeView(_ e: Exchange, isNewest: Bool) -> some View {
        ExchangeView(ask: e.ask, reply: e.reply?.text ?? "", note: e.reply?.note ?? "",
                     answered: e.reply != nil, live: isNewest && chat.phase != .idle, ink: ink)
            .equatable()
    }
}

/// What you asked, small, and the reply under it. Equatable, so it's only drawn (and fitted)
/// again when it changes.
struct ExchangeView: View, Equatable {
    let ask: String
    let reply: String
    let note: String
    /// A reply was kept (it can be empty when it was stopped before it said anything).
    let answered: Bool
    /// Still coming in.
    let live: Bool
    let ink: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.prompt(ink).opacity(0.62))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ask)
            if !reply.isEmpty {
                FittedReply(text: reply, ink: ink, live: live)
            } else if live {
                Caret(hue: ink)
            } else if answered {
                Text("Stopped before it said anything.")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.reply(ink))
                    .opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The reply as large as it fits above the line (Glass's page does the same); once it doesn't
/// fit even small, it scrolls.
struct FittedReply: View {
    let text: String
    let ink: Double
    let live: Bool

    var body: some View {
        let blocks = ReplyBlock.split(text)
        if text.count > 1400 {
            ReplyScroll(blocks: blocks, ink: ink, live: live)
        } else {
            ViewThatFits(in: .vertical) {
                ReplyBody(blocks: blocks, size: 40, ink: ink)
                ReplyBody(blocks: blocks, size: 32, ink: ink)
                ReplyBody(blocks: blocks, size: 26, ink: ink)
                ReplyBody(blocks: blocks, size: 21, ink: ink)
                ReplyBody(blocks: blocks, size: 17, ink: ink)
                ReplyScroll(blocks: blocks, ink: ink, live: live)
            }
        }
    }
}

/// A long reply, small, in a scroll view. While it streams in it follows the end, unless you've
/// scrolled up to read; then an arrow takes you back down.
struct ReplyScroll: View {
    let blocks: [ReplyBlock]
    let ink: Double
    let live: Bool
    @State private var atBottom = true

    static let end = "end"
    static let space = "replyScroll"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ReplyBody(blocks: blocks, size: 15, ink: ink)
                        Color.clear.frame(height: 1)
                            .background(GeometryReader { g in
                                let bottom = g.frame(in: .named(Self.space)).maxY <= outer.size.height + 40
                                Color.clear
                                    .onAppear { atBottom = bottom }
                                    .onChange(of: bottom) { b in
                                        withAnimation(.easeOut(duration: 0.15)) { atBottom = b }
                                    }
                            })
                            .id(Self.end)
                    }
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: Self.space)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.04),
                                             .init(color: .black, location: 0.95),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        JumpDownButton {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .onChange(of: blocks) { _ in
                    if live && atBottom { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }
}

/// A reply's prose and code at one size.
struct ReplyBody: View {
    let blocks: [ReplyBlock]
    let size: CGFloat
    let ink: Double

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.45) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    ProseView(text: t, size: size, ink: ink)
                case .code(let language, let code):
                    CodeBlock(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A reply's prose: paragraphs, headings, lists, quotes and rules, each line with its inline
/// Markdown, in rounded type colored by the ink.
struct ProseView: View {
    let text: String
    let size: CGFloat
    let ink: Double

    var weight: Font.Weight { size >= 20 ? .semibold : .medium }

    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.3) {
            ForEach(Array(ProseBlock.parse(text).enumerated()), id: \.offset) { _, block in
                line(block.kind)
                    .padding(.top, block.spaced ? size * 0.45 : 0)
            }
        }
        .font(.system(size: size, weight: weight, design: .rounded))
        .tracking(-size * 0.012)
        .lineSpacing(size * 0.12)
        .foregroundStyle(Ink.reply(ink))
        .tint(Color.hsl(ink + 180, 0.9, 0.8))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder func line(_ kind: ProseBlock.Kind) -> some View {
        switch kind {
        case .paragraph(let t):
            styled(t)
        case .heading(let level, let t):
            styled(t)
                .font(.system(size: size * (level == 1 ? 1.3 : level == 2 ? 1.15 : 1.05), weight: .bold, design: .rounded))
        case .bullet(let depth, let t):
            item(depth: depth, marker: Text(depth % 2 == 0 ? "•" : "◦"), styled(t))
        case .numbered(let depth, let number, let t):
            item(depth: depth, marker: Text(number + ".").monospacedDigit(), styled(t))
        case .task(let depth, let done, let t):
            item(depth: depth,
                 marker: Text(Image(systemName: done ? "checkmark.square.fill" : "square")).font(.system(size: size * 0.8)),
                 styled(t).strikethrough(done, color: Color.white.opacity(0.4)))
        case .quote(let t):
            HStack(alignment: .top, spacing: size * 0.6) {
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.28)).frame(width: 2.5)
                styled(t).opacity(0.75)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            HairLine().padding(.vertical, 4)
        }
    }

    func styled(_ t: String) -> Text { Text(Self.markdown(t)) }

    /// A list item: its marker in a gutter (so the text lines up), indented by depth.
    func item(depth: Int, marker: Text, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.45) {
            marker
                .foregroundColor(Color.white.opacity(0.5))
                .frame(minWidth: size, alignment: .trailing)
            text
        }
        .padding(.leading, CGFloat(depth) * size * 1.2)
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A ``` block: its language, a copy button, and the code in a monospaced box that scrolls sideways.
struct CodeBlock: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                CopyButton(text: code)
            }
            .foregroundStyle(.white.opacity(0.5))
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.05))
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Color.black.opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// While the model hasn't said anything yet: a block cursor breathing in the reply's color.
struct Caret: View {
    let hue: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = (1 - cos(t * 2 * .pi / 0.9)) / 2
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.hsl(hue, 1, 0.82))
                .frame(width: 15, height: 34)
                .shadow(color: .hsl(hue, 1, 0.65), radius: 8)
                .scaleEffect(x: 1, y: 1 - 0.65 * breath)
                .opacity(1 - 0.5 * breath)
        }
        .frame(width: 15, height: 34)
        .help("Thinking… (Esc stops it)")
    }
}

/// Under the reply: Copy and Retry, how it ended if it didn't finish, what was remembered, and
/// arrows through the conversation.
struct ReplyActions: View {
    @ObservedObject var chat: ChatModel
    let exchange: Exchange
    let isNewest: Bool
    let page: Int
    let pages: Int
    let go: (Int) -> Void

    var live: Bool { isNewest && chat.phase != .idle }

    var body: some View {
        HStack(spacing: 6) {
            if !live {
                if let reply = exchange.reply, !reply.text.isEmpty {
                    CopyButton(text: reply.text)
                }
                if isNewest && chat.canRetry {
                    ActionChip(title: "Retry", symbol: "arrow.clockwise", help: "Ask for this reply again") {
                        chat.retry()
                    }
                }
                if let ran = exchange.reply?.ran, !ran.isEmpty {
                    Label("Ran " + ran.joined(separator: ", "), systemImage: "bolt.fill")
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.5))
                        .help("Shortcuts the model ran for this reply:\n" + ran.joined(separator: "\n"))
                }
                if let note = exchange.reply?.note, !note.isEmpty {
                    Label(note == "stopped" ? "Stopped" : "Didn't finish",
                          systemImage: note == "stopped" ? "stop.circle" : "exclamationmark.circle")
                        .foregroundStyle(.white.opacity(0.42))
                        .help(note == "stopped" ? "Stopped before the reply was done"
                                                : "The reply broke off partway (Retry asks for it again)")
                }
                if let last = exchange.notes.last {
                    MemoryNote(chat: chat, note: last, all: exchange.notes)
                }
            }
            Spacer(minLength: 4)
            if pages > 1 {
                Pager(page: page, pages: pages, go: go)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .frame(height: 24)
    }
}

/// ‹ 2 / 5 ›: back and forth through the conversation.
struct Pager: View {
    let page: Int
    let pages: Int
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", to: page - 1, help: "The reply before")
            Text("\(page + 1) / \(pages)")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
                .frame(minWidth: 38)
            arrow("chevron.right", to: page + 1, help: "The reply after")
        }
    }

    func arrow(_ symbol: String, to target: Int, help: String) -> some View {
        Button { go(target) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.7))
        .disabled(target < 0 || target >= pages)
        .opacity(target < 0 || target >= pages ? 0.3 : 1)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Back to the end of a long reply, when you've scrolled up.
struct JumpDownButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(hover ? 0.6 : 0.45)))
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help("Jump to the end")
        .accessibilityLabel("Jump to the end")
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    /// Counts copies, so an earlier one's timer doesn't take "Copied" away from a later one early.
    @State private var copies = 0

    var body: some View {
        ActionChip(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc",
                   help: "Copy to the clipboard") {
            Clipboard.copy(text)
            copied = true
            copies += 1
            let mine = copies
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if mine == copies { copied = false } }
        }
    }
}

/// What was just remembered or forgotten, with a way to take it back.
struct MemoryNote: View {
    @ObservedObject var chat: ChatModel
    let note: ChatModel.Message
    let all: [ChatModel.Message]

    var body: some View {
        HStack(spacing: 5) {
            Label(note.text, systemImage: note.undone ? "arrow.uturn.backward.circle"
                    : note.forgetting ? "minus.circle.fill" : "checkmark.circle.fill")
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.5))
                .help(all.map(\.text).joined(separator: "\n"))
            if !note.undone {
                Button("Undo") { chat.undo(note.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.75))
                    .underline()
                    .help(note.forgetting ? "Put it back in MEMORY.md" : "Take it out of MEMORY.md")
            }
        }
    }
}

/// A change the model wants to make to memory (when Settings says to ask first): nothing is
/// written to MEMORY.md until you say yes.
struct ProposalRow: View {
    @ObservedObject var chat: ChatModel
    let message: ChatModel.Message

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.09)))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.forgetting ? "Forget this?" : "Remember this?")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                Text(message.text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            PillButton(title: "Not now") { chat.dismiss(message.id) }
            PillButton(title: message.forgetting ? "Forget" : "Remember", prominent: true) { chat.accept(message.id) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 0.5))
        .help(message.forgetting ? "Takes it out of MEMORY.md" : "Adds it to MEMORY.md, which goes with every message (Glass reads it too)")
    }
}

/// What went wrong (Ollama not running, a reply that failed), with a way to try again: when your
/// message is the last thing it asks again, otherwise it looks for Ollama again.
struct ChatProblem: View {
    @ObservedObject var chat: ChatModel

    static let pink = Color(red: 1, green: 0.42, blue: 0.51)

    var body: some View {
        let retry = chat.messages.last?.role == .user && chat.canRetry
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Self.pink)
            Text(chat.problem ?? "")
                .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.84))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(chat.problem ?? "")
            Spacer(minLength: 4)
            CopyErrorButton(text: chat.problem ?? "")
            PillButton(title: retry ? "Try again" : "Check again") {
                chat.clearProblem()
                chat.loadModels()
                if retry { chat.retry() }
            }
            Button { chat.clearProblem() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 11.5, weight: .medium, design: .rounded))
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Self.pink.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Self.pink.opacity(0.35), lineWidth: 0.5))
        .transition(.opacity)
    }
}

// MARK: - What you type, below the line

/// The box: large rounded type in the colors opposite the reply's, smaller the more you write.
/// When you send, what you wrote lifts away and blurs out. Under it, the keys and the tokens the
/// last reply used.
struct PromptWell: View {
    @ObservedObject var chat: ChatModel
    let link: VoiceLink
    let ink: Double
    let small: Bool
    let sent: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var active
    /// What you just sent, on its way out.
    @State private var ghost: String?
    @State private var ghostGone = false

    var busy: Bool { chat.phase != .idle }
    var canSend: Bool { !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var fontSize: CGFloat { Self.fontSize(for: ghost ?? chat.input, small: small) }

    static func fontSize(for text: String, small: Bool) -> CGFloat {
        let n = text.count
        if small { return n < 80 ? 22 : 18 }
        return n < 60 ? 30 : n < 160 ? 24 : n < 400 ? 19 : 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    field
                    if let ghost {
                        Text(ghost)
                            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.prompt(ink))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .offset(y: ghostGone ? -34 : 0)
                            .blur(radius: ghostGone ? 8 : 0)
                            .opacity(ghostGone ? 0 : 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: small ? nil : .infinity, alignment: .topLeading)
                if chat.mode == .listens {
                    MicButton(link: link, listener: link.listener, ink: ink)
                        .padding(.bottom, 2)
                }
                sendButton
            }
        }
        .onAppear { focused = true }
        .onChange(of: active) { if $0 == .key { focused = true } }
    }

    var field: some View {
        TextField("Message", text: $chat.input,
                  prompt: Text(placeholder).foregroundColor(.white.opacity(0.3)),
                  axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .tracking(-fontSize * 0.012)
            .foregroundStyle(Ink.prompt(ink))
            .tint(.white)
            .lineLimit(small ? 1...4 : 1...12)
            .focused($focused)
            .onSubmit(send)
            .opacity(ghost == nil ? 1 : 0)
    }

    var placeholder: String {
        if chat.mode == .listens { return chat.messages.isEmpty ? "Talk (press the mic) or type…" : "Talk or type…" }
        return chat.messages.isEmpty ? "Ask anything…" : "Type here…"
    }

    var sendButton: some View {
        ZStack {
            if busy {
                RoundButton(symbol: "stop.fill", help: "Stop (Esc)", enabled: true) {
                    chat.stop()
                    link.speaker.stop()
                }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                RoundButton(symbol: "arrow.up", help: "Send (Return; ⌥Return for a new line)", enabled: canSend, action: send)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: busy)
        .padding(.bottom, 2)
    }

    func send() {
        let text = chat.input
        chat.send()
        // Sent (the box emptied): what you wrote lifts away, the way Glass's page wipes it.
        guard chat.input.isEmpty, !text.isEmpty else { return }
        sent()
        ghost = text
        ghostGone = false
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.65, 0, 0.25, 1, duration: 0.55)) { ghostGone = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            ghost = nil
            ghostGone = false
        }
    }
}

/// Send and stop: a filled circle when it can be used, a faint one when it can't.
struct RoundButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.35))
                .frame(width: 30, height: 30)
                .background(Circle().fill(enabled ? Color.white.opacity(hover ? 1 : 0.9) : Color.white.opacity(0.1)))
                .overlay(Circle().stroke(.white.opacity(enabled ? 0 : 0.14), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Why the microphone isn't listening (a permission, no microphone), with a way to try again.
struct ListenerProblem: View {
    @ObservedObject var listener: Listener
    let mode: ChatKind

    var body: some View {
        if mode.listens, let problem = listener.problem {
            VoiceProblem(text: problem, action: "Try again") { listener.start() }
                .padding(.horizontal, 22)
                .padding(.top, 14)
        }
    }
}

/// Copies an error message, so it can be pasted into a search or a bug report.
struct CopyErrorButton: View {
    let text: String
    @State private var copied = false
    @State private var copies = 0
    @State private var hover = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            copies += 1
            let mine = copies
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if mine == copies { copied = false } }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.6))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(copied ? "Copied" : "Copy the error")
        .accessibilityLabel("Copy the error")
    }
}
