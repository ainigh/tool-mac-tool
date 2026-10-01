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
            // Esc stops a reply; with nothing streaming and nothing typed, it puts the chat away.
            panel.onEscape = {
                if chat.phase != .idle {
                    chat.stop()
                } else if chat.input.isEmpty {
                    panel.orderOut(nil)
                } else {
                    return false
                }
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
        small ? CGSize(width: 460, height: problem ? 156 : 104) : CGSize(width: 500, height: 660)
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
                    .padding(.bottom, small ? 4 : 6)
                if !small {
                    HairLine()
                    ChatMessages(chat: chat)
                }
                if let problem = chat.problem {
                    problemBanner(problem)
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .transition(.opacity)
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
        .animation(.easeOut(duration: 0.2), value: chat.problem)
        .environment(\.colorScheme, .dark)
        .onChange(of: cardSize) { resize($0) }
        // Sending from the shrunken card opens it up again, so the reply can be seen.
        .onChange(of: chat.phase) { if $0 == .thinking { collapsed = false } }
    }

    /// When a reply failed outright (your message is the last thing), it offers to ask again;
    /// otherwise to look for Ollama again.
    func problemBanner(_ text: String) -> some View {
        let retry = chat.messages.last?.role == .user && chat.canRetry
        return ProblemBanner(text: text, action: retry ? "Try again" : "Check again", dismiss: { chat.clearProblem() }) {
            chat.clearProblem()
            chat.loadModels()
            if retry { chat.retry() }
        }
    }
}

/// A thin line that fades out at both ends.
struct HairLine: View {
    var body: some View {
        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 0.5)
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
        HStack(spacing: 1) {
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
                          help: collapsed ? "Show the conversation" : "Shrink to just the box") {
                    collapsed.toggle()
                }
            }
            GlassIcon(symbol: pinned ? "pin.fill" : "pin",
                      help: pinned ? "Stays on top (click to let go)" : "Keep on top") {
                pinned.toggle()
                pin(pinned)
            }
            GlassIcon(symbol: "xmark", help: "Close (⌘W, or Esc when the box is empty)", action: close)
        }
    }
}

/// The model in use, as a pill; clicking it lists the models Ollama has.
struct ModelMenu: View {
    @ObservedObject var chat: ChatModel
    @State private var hover = false

    /// Green when ready, blue while replying, orange when something's wrong.
    var status: Color {
        if chat.problem != nil || chat.model.isEmpty { return .orange }
        return chat.phase == .idle ? .green : Color(red: 0.4, green: 0.7, blue: 1)
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 6) {
                Circle().fill(status)
                    .frame(width: 6, height: 6)
                    .shadow(color: status.opacity(0.8), radius: 3)
                Text(chat.model.isEmpty ? "No model" : Self.shortName(chat.model))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 190, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.55)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(hover ? 0.16 : 0.09)))
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(chat.model.isEmpty ? "Pick a model (from Ollama)" : "\(chat.model) (from Ollama): click to switch")
    }

    /// "llama3.2:latest" reads as "llama3.2": the tag only shows when it says something.
    static func shortName(_ model: String) -> String {
        model.hasSuffix(":latest") ? String(model.dropLast(":latest".count)) : model
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? (hover ? 1 : 0.7) : 0.28))
                .frame(width: 27, height: 27)
                .background(Circle().fill(.white.opacity(hover && enabled ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

// MARK: - The conversation

struct ChatMessages: View {
    @ObservedObject var chat: ChatModel
    /// Whether the end of the conversation is in view. While it is, a reply streaming in keeps it
    /// there; scroll up and it stops following (a button brings you back down).
    @State private var atBottom = true

    static let end = "end"
    static let space = "chatScroll"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        let lastReply = chat.messages.last(where: { $0.role == .assistant })?.id
                        ForEach(chat.messages) { m in
                            row(m, isLastReply: m.id == lastReply).id(m.id)
                        }
                        Color.clear.frame(height: 1).id(Self.end)
                            .background(GeometryReader { g in
                                let bottom = g.frame(in: .named(Self.space)).maxY <= outer.size.height + 40
                                Color.clear
                                    .onAppear { atBottom = bottom }
                                    .onChange(of: bottom) { b in
                                        withAnimation(.easeOut(duration: 0.15)) { atBottom = b }
                                    }
                            })
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .coordinateSpace(name: Self.space)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                             .init(color: .black, location: 0.03),
                                             .init(color: .black, location: 0.96),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    if !atBottom {
                        JumpDownButton {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                        }
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
                .onChange(of: chat.messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
                .onChange(of: chat.messages.last?.text) { _ in
                    if atBottom { proxy.scrollTo(Self.end, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder func row(_ m: ChatModel.Message, isLastReply: Bool) -> some View {
        switch m.role {
        case .user:
            UserBubble(text: m.text).equatable()
        case .assistant:
            AssistantMessage(text: m.text, note: m.note,
                             live: isLastReply && chat.phase != .idle,
                             isLast: isLastReply,
                             retry: isLastReply && chat.canRetry ? { chat.retry() } : nil)
                .equatable()
        case .note:
            Label(m.text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        case .proposal:
            ProposalRow(chat: chat, message: m)
        }
    }
}

/// Back to the newest message, when you've scrolled up.
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
        .help("Jump to the newest message")
    }
}

/// What you wrote, on the right. Equatable, so it's only drawn again when its text changes.
struct UserBubble: View, Equatable {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 64)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 0.5))
        }
    }
}

/// The model's reply: Markdown (headings, lists, quotes, inline styles), code in its own box,
/// and Copy / Retry under it (always on the newest reply, on hover for older ones). Equatable,
/// so it's only drawn (and parsed) again when it changes.
struct AssistantMessage: View, Equatable {
    let text: String
    /// "stopped" or "failed" for a reply that didn't finish.
    let note: String
    /// Still streaming in: no buttons yet.
    let live: Bool
    let isLast: Bool
    let retry: (() -> Void)?
    @State private var hover = false

    static func == (a: AssistantMessage, b: AssistantMessage) -> Bool {
        a.text == b.text && a.note == b.note && a.live == b.live && a.isLast == b.isLast
            && (a.retry == nil) == (b.retry == nil)
    }

    var body: some View {
        if text.isEmpty {
            ThinkingDots()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ReplyBlock.split(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let t):
                        ProseView(text: t)
                    case .code(let language, let code):
                        CodeBlock(language: language, code: code)
                    }
                }
                if !live {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            CopyButton(text: text)
                            if let retry {
                                ActionChip(title: "Retry", symbol: "arrow.clockwise",
                                           help: "Ask for this reply again", action: retry)
                            }
                        }
                        .opacity(isLast || hover ? 1 : 0)
                        if !note.isEmpty {
                            Label(note == "stopped" ? "Stopped" : "Didn't finish",
                                  systemImage: note == "stopped" ? "stop.circle" : "exclamationmark.circle")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer()
                    }
                    .animation(.easeOut(duration: 0.12), value: hover)
                }
            }
            .tint(Color(red: 0.55, green: 0.78, blue: 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A reply's prose: paragraphs, headings, lists, quotes and rules, each line with its inline Markdown.
struct ProseView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(ProseBlock.parse(text).enumerated()), id: \.offset) { _, block in
                line(block.kind)
                    .padding(.top, block.spaced ? 7 : 0)
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(.white.opacity(0.92))
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder func line(_ kind: ProseBlock.Kind) -> some View {
        switch kind {
        case .paragraph(let t):
            styled(t)
        case .heading(let level, let t):
            styled(t)
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15.5 : 14, weight: .semibold))
                .foregroundStyle(.white)
        case .bullet(let depth, let t):
            item(depth: depth, marker: Text(depth % 2 == 0 ? "•" : "◦"), styled(t))
        case .numbered(let depth, let number, let t):
            item(depth: depth, marker: Text(number + ".").monospacedDigit(), styled(t))
        case .task(let depth, let done, let t):
            item(depth: depth,
                 marker: Text(Image(systemName: done ? "checkmark.square.fill" : "square")).font(.system(size: 11.5)),
                 styled(t).strikethrough(done, color: Color.white.opacity(0.4)))
        case .quote(let t):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.28)).frame(width: 2.5)
                styled(t).foregroundStyle(.white.opacity(0.7))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            HairLine().padding(.vertical, 4)
        }
    }

    func styled(_ t: String) -> Text { Text(AssistantMessage.markdown(t)) }

    /// A list item: its marker in a gutter (so the text lines up), indented by depth.
    func item(depth: Int, marker: Text, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker
                .foregroundColor(Color.white.opacity(0.5))
                .frame(minWidth: 16, alignment: .trailing)
            text
        }
        .padding(.leading, CGFloat(depth) * 18)
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
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// A small capsule button with an icon and a word, for actions under a reply.
struct ActionChip: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.62))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(hover ? 0.15 : 0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        ActionChip(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc",
                   help: "Copy to the clipboard") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        }
    }
}

/// A capsule button with a word on it: filled white for the main choice, faint for the other.
struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(prominent ? Color.white.opacity(hover ? 1 : 0.88)
                                                     : Color.white.opacity(hover ? 0.2 : 0.11)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A fact the model wants to remember: nothing is written to MEMORY.md until you say yes.
struct ProposalRow: View {
    @ObservedObject var chat: ChatModel
    let message: ChatModel.Message

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember this?")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Text(message.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            PillButton(title: "Not now") { chat.dismiss(message.id) }
            PillButton(title: "Remember", prominent: true) { chat.accept(message.id) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
        .help("Adds it to MEMORY.md, which goes with every message (Glass reads it too)")
    }
}

/// Three dots in a soft wave, while the model hasn't said anything yet.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let wave = max(0, sin(t * 5 - Double(i) * 0.8))
                    Circle()
                        .fill(.white.opacity(0.3 + 0.55 * wave))
                        .frame(width: 6, height: 6)
                        .offset(y: -2.5 * wave)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(.white.opacity(0.07)))
        }
        .help("Thinking… (Esc stops it)")
    }
}

/// What went wrong (Ollama not running, a reply that failed), with a way to try again.
struct ProblemBanner: View {
    let text: String
    let action: String
    let dismiss: () -> Void
    let run: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            PillButton(title: action, action: run)
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
        .font(.system(size: 11))
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - The box you type in

struct ChatInput: View {
    @ObservedObject var chat: ChatModel
    let showHints: Bool
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var active

    var canSend: Bool { !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var busy: Bool { chat.phase != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.messages.isEmpty ? "Ask Glass anything…" : "Reply…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { chat.send() }
                    .padding(.vertical, 6)
                ZStack {
                    if busy {
                        RoundButton(symbol: "stop.fill", help: "Stop (Esc)", enabled: true) { chat.stop() }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        RoundButton(symbol: "arrow.up", help: "Send (Return)", enabled: canSend) { chat.send() }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: busy)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.black.opacity(focused ? 0.34 : 0.26)))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(.white.opacity(focused ? 0.3 : 0.13), lineWidth: 0.75))
            .animation(.easeOut(duration: 0.15), value: focused)
            if showHints {
                HStack(spacing: 10) {
                    if busy {
                        KeyHint(key: "esc", does: "stop")
                    } else {
                        KeyHint(key: "⏎", does: "send")
                        KeyHint(key: "⌥⏎", does: "new line")
                    }
                    Spacer()
                    if let u = chat.usage {
                        Text("\((u.prompt + u.output).formatted()) tokens")
                            .monospacedDigit()
                            .help("The last reply read \(u.prompt.formatted()) tokens (memory and conversation) and wrote \(u.output.formatted())")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 8)
            }
        }
        .onAppear { focused = true }
        .onChange(of: active) { if $0 == .key { focused = true } }
    }
}

/// "⏎ send": a key in a faint box and what it does.
struct KeyHint: View {
    let key: String
    let does: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 15)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.08)))
            Text(does)
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
                .frame(width: 28, height: 28)
                .background(Circle().fill(enabled ? Color.white.opacity(hover ? 1 : 0.9) : Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: enabled)
        .help(help)
    }
}
