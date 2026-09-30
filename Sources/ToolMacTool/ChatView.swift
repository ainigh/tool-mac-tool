import AppKit
import SwiftUI
import ToolCore

/// The chat's own window: borderless and clear, sized to the glass card plus a margin for its
/// glow, so nothing invisible sits over other windows. It grows downward when there's a
/// conversation to show and shrinks back to just the box when there isn't.
@MainActor
enum ChatWindow {
    /// Room around the card for its glow.
    static let margin: CGFloat = 24

    static func show(_ chat: ChatModel) {
        Windows.show("chat") {
            let card = ChatView.cardSize(small: chat.messages.isEmpty, problem: chat.problem != nil)
            let panel = GlassPanel(size: frame(for: card))
            panel.level = .floating
            let view = ChatView(chat: chat,
                                close: { panel.orderOut(nil) },
                                pin: { on in panel.level = on ? .floating : .normal },
                                resize: { card in resize(panel, to: card, animate: true) })
            let host = FirstClickHostingView(rootView: view)
            host.sizingOptions = []          // the window sets the size; the view fills it
            panel.contentView = host
            panel.commands = ["w": { panel.orderOut(nil) }, "n": { chat.newChat() }]
            panel.onEscape = {
                guard chat.phase != .idle else { return false }
                chat.stop()
                return true
            }
            if !panel.setFrameUsingName("ToolMacTool.chat"), let screen = NSScreen.main {
                let v = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 8, y: v.maxY - panel.frame.height))
            }
            resize(panel, to: card, animate: false)
            panel.setFrameAutosaveName("ToolMacTool.chat")
            return panel
        }
        chat.loadModels()
    }

    static func frame(for card: CGSize) -> NSSize {
        NSSize(width: card.width + 2 * margin, height: card.height + 2 * margin)
    }

    /// Resizes the window around a card of this size, keeping its top edge where it is.
    static func resize(_ panel: NSWindow, to card: CGSize, animate: Bool) {
        let size = frame(for: card)
        var f = panel.frame
        if f.size == size { return }
        f.origin.y += f.height - size.height
        f.size = size
        panel.setFrame(f, display: true, animate: animate)
    }
}

/// The chat: a glass card that is just the box you type in when there's nothing to show, and
/// grows to hold the conversation. The glass ripples while the model thinks; the controls on it
/// stay put.
struct ChatView: View {
    @ObservedObject var chat: ChatModel
    let close: () -> Void
    let pin: (Bool) -> Void
    let resize: (CGSize) -> Void

    @State private var collapsed = false
    @State private var pinned = true
    @Environment(\.controlActiveState) private var active

    static func cardSize(small: Bool, problem: Bool) -> CGSize {
        small ? CGSize(width: 440, height: problem ? 148 : 104) : CGSize(width: 480, height: 640)
    }

    var small: Bool { collapsed || chat.messages.isEmpty }
    var cardSize: CGSize { Self.cardSize(small: small, problem: chat.problem != nil) }

    var mood: GlassMood {
        switch chat.phase {
        case .idle: return .calm
        case .thinking: return .thinking
        case .streaming: return .speaking
        }
    }

    var body: some View {
        ZStack {
            // Only the glass redraws every frame: slower when calm, still when calm in the background.
            TimelineView(.animation(minimumInterval: chat.phase == .idle ? 1 / 20 : 1 / 45,
                                    paused: chat.phase == .idle && active == .inactive)) { context in
                GlassSurface(mood: mood, time: context.date.timeIntervalSinceReferenceDate)
            }
            VStack(spacing: 0) {
                ChatHeader(chat: chat, collapsed: $collapsed, pinned: $pinned, close: close, pin: pin)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, small ? 4 : 8)
                if !small {
                    Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5)
                    ChatMessages(chat: chat)
                }
                if let problem = chat.problem {
                    ProblemBanner(text: problem) {
                        chat.clearProblem()
                        chat.loadModels()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                }
                ChatInput(chat: chat, showHints: !small)
                    .padding(.horizontal, 12)
                    .padding(.top, small ? 2 : 8)
                    .padding(.bottom, 12)
            }
        }
        .padding(ChatWindow.margin)
        .opacity(active == .inactive ? 0.94 : 1)
        .animation(.easeInOut(duration: 0.25), value: active)
        .environment(\.colorScheme, .dark)
        .onChange(of: cardSize) { resize($0) }
    }
}

/// The model on the left, the empty middle to drag the window by, the buttons on the right.
struct ChatHeader: View {
    @ObservedObject var chat: ChatModel
    @Binding var collapsed: Bool
    @Binding var pinned: Bool
    let close: () -> Void
    let pin: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ModelMenu(chat: chat)
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            GlassIcon(symbol: "brain", help: "Memory (MEMORY.md)") { MemoryWindow.show() }
            GlassIcon(symbol: "square.and.pencil", help: "New chat (⌘N)") { chat.newChat() }
                .disabled(chat.messages.isEmpty && chat.phase == .idle)
            if !chat.messages.isEmpty {
                GlassIcon(symbol: collapsed ? "chevron.down" : "chevron.up",
                          help: collapsed ? "Show the conversation" : "Shrink to just the box") { collapsed.toggle() }
            }
            GlassIcon(symbol: pinned ? "pin.fill" : "pin",
                      help: pinned ? "Stays on top (click to let go)" : "Keep on top") {
                pinned.toggle()
                pin(pinned)
            }
            GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
        }
    }
}

/// The model in use, as a pill; clicking it lists the models Ollama has.
struct ModelMenu: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 5) {
                Circle().fill(chat.problem == nil && !chat.model.isEmpty ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(chat.model.isEmpty ? "No model" : chat.model).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("The model (from Ollama)")
    }

    /// A plain AppKit menu at the pointer: it works the same in any window, borderless or not.
    func showMenu() {
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
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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

/// A round icon button on the glass, with a hover highlight and a tooltip.
struct GlassIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? (hover ? 1 : 0.75) : 0.3))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hover && enabled ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - The conversation

struct ChatMessages: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { m in
                        row(m).id(m.id)
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            .onChange(of: chat.messages) { _ in proxy.scrollTo(Self.end, anchor: .bottom) }
        }
    }

    static let end = "end"

    @ViewBuilder func row(_ m: ChatModel.Message) -> some View {
        switch m.role {
        case .user:
            UserBubble(text: m.text).equatable()
        case .assistant:
            AssistantMessage(text: m.text).equatable()
        case .note:
            Label(m.text, systemImage: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
        case .proposal:
            ProposalRow(chat: chat, message: m)
        }
    }
}

/// What you wrote, on the right. Equatable, so it's only drawn again when its text changes.
struct UserBubble: View, Equatable {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.6)))
        }
    }
}

/// The model's reply: text with inline Markdown, code in its own box, and a copy button.
/// Equatable, so it's only drawn (and parsed) again when its text changes.
struct AssistantMessage: View, Equatable {
    let text: String
    @State private var hover = false

    static func == (a: AssistantMessage, b: AssistantMessage) -> Bool { a.text == b.text }

    var body: some View {
        if text.isEmpty {
            ThinkingDots()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ReplyBlock.split(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let t):
                        Text(Self.markdown(t))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .code(let language, let code):
                        CodeBlock(language: language, code: code)
                    }
                }
                HStack {
                    CopyButton(text: text)
                    Spacer()
                }
                .opacity(hover ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }
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
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                CopyButton(text: code)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.5))
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// A fact the model wants to remember: nothing is written to MEMORY.md until you say yes.
struct ProposalRow: View {
    @ObservedObject var chat: ChatModel
    let message: ChatModel.Message

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "brain").font(.system(size: 11))
            Text("Remember “\(message.text)”?")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Remember") { chat.accept(message.id) }
            Button("No") { chat.dismiss(message.id) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
        .help("Adds it to MEMORY.md, which goes with every message (Glass reads it too)")
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.white.opacity(0.35 + 0.5 * max(0, sin(t * 4 - Double(i) * 0.7))))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// What went wrong (Ollama not running, a reply that failed), with a way to try again.
struct ProblemBanner: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Check again", action: retry)
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

// MARK: - The box you type in

struct ChatInput: View {
    @ObservedObject var chat: ChatModel
    let showHints: Bool
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var active

    var canSend: Bool { !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Glass…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { chat.send() }
                    .padding(.vertical, 6)
                if chat.phase == .idle {
                    RoundButton(symbol: "arrow.up", help: "Send (Return)", enabled: canSend) { chat.send() }
                } else {
                    RoundButton(symbol: "stop.fill", help: "Stop (Esc)", enabled: true) { chat.stop() }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(.white.opacity(focused ? 0.35 : 0.15), lineWidth: 0.75))
            if showHints {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.leading, 10)
            }
        }
        .onAppear { focused = true }
        .onChange(of: active) { if $0 == .key { focused = true } }
    }

    var hint: String {
        var s = "Return to send · ⌥Return for a new line · Esc stops a reply"
        if let u = chat.usage { s += " · \(u.prompt + u.output) tokens" }
        return s
    }
}

/// Send and stop: a filled circle when it can be used, a faint one when it can't.
struct RoundButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.35))
                .frame(width: 28, height: 28)
                .background(Circle().fill(enabled ? Color.white.opacity(0.92) : Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
