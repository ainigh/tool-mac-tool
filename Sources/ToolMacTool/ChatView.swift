import AppKit
import SwiftUI
import ToolCore

/// The chat's own window: borderless and clear, so all you see is the glass shape.
@MainActor
enum ChatWindow {
    static let size = NSSize(width: 560, height: 720)

    static func show(_ chat: ChatModel) {
        Windows.show("chat") {
            let panel = GlassPanel(size: size)
            panel.level = .floating
            panel.contentView = NSHostingView(rootView: ChatView(chat: chat, close: { panel.orderOut(nil) },
                                                                 pin: { on in panel.level = on ? .floating : .normal }))
            if !panel.setFrameUsingName("ToolMacTool.chat"), let screen = NSScreen.main {
                let v = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 20, y: v.maxY - size.height - 10))
            }
            panel.setFrameAutosaveName("ToolMacTool.chat")
            return panel
        }
        chat.loadModels()
    }
}

/// The chat: a glass blob that is small when there's nothing to show and grows as you talk. It
/// ripples while the model thinks, tilts toward the pointer, and dims a little when you're elsewhere.
struct ChatView: View {
    @ObservedObject var chat: ChatModel
    let close: () -> Void
    let pin: (Bool) -> Void

    @State private var tilt = CGSize.zero
    @State private var collapsed = false
    @State private var pinned = true
    @Environment(\.controlActiveState) private var active

    static let compact = CGSize(width: 420, height: 118)
    static let open = CGSize(width: 460, height: 600)

    var mood: GlassMood {
        switch chat.phase {
        case .idle: return .calm
        case .thinking: return .thinking
        case .streaming: return .speaking
        }
    }

    var small: Bool { collapsed || chat.messages.isEmpty }

    var body: some View {
        let size = small ? Self.compact : Self.open
        VStack {
            TimelineView(.animation(minimumInterval: 1 / 45)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    GlassSurface(mood: mood, time: t)
                    ChatContent(chat: chat, small: small, collapsed: $collapsed, pinned: $pinned,
                                close: close, pin: pin)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                }
                .scaleEffect(breath(t))
            }
            .frame(width: size.width, height: size.height)
            .rotation3DEffect(.degrees(Double(-tilt.height) * 7), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(tilt.width) * 7), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .scaleEffect(active == .inactive ? 0.97 : 1)
            .opacity(active == .inactive ? 0.9 : 1)
            .onContinuousHover { phase in hover(phase, size: size) }
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: small)
            .animation(.spring(response: 0.6, dampingFraction: 0.6), value: tilt)
            .animation(.easeInOut(duration: 0.3), value: active)
            Spacer(minLength: 0)
        }
        .padding(.top, 40)
        .frame(width: ChatWindow.size.width, height: ChatWindow.size.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Tilts toward the pointer: -0.5...0.5 on each axis.
    func hover(_ phase: HoverPhase, size: CGSize) {
        switch phase {
        case .active(let p):
            let x = p.x / size.width - 0.5
            let y = p.y / size.height - 0.5
            tilt = CGSize(width: x, height: y)
        case .ended:
            tilt = .zero
        }
    }

    /// A slow breath while it's thinking.
    func breath(_ t: Double) -> CGFloat {
        chat.phase == .thinking ? 1 + 0.012 * CGFloat(sin(t * 3)) : 1
    }
}

/// What's inside the glass: the controls, the conversation, the box you type in.
struct ChatContent: View {
    @ObservedObject var chat: ChatModel
    let small: Bool
    @Binding var collapsed: Bool
    @Binding var pinned: Bool
    let close: () -> Void
    let pin: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ChatHeader(chat: chat, collapsed: $collapsed, pinned: $pinned, close: close, pin: pin)
            if !small {
                ChatMessages(chat: chat)
            }
            if let problem = chat.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ChatInput(chat: chat)
        }
    }
}

struct ChatHeader: View {
    @ObservedObject var chat: ChatModel
    @Binding var collapsed: Bool
    @Binding var pinned: Bool
    let close: () -> Void
    let pin: (Bool) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ModelMenu(chat: chat)
            ZStack { WindowDragArea() }            // the empty middle moves the window
                .frame(maxWidth: .infinity, maxHeight: 22)
            GlassIcon(symbol: "brain", help: "Memory (MEMORY.md)") { MemoryWindow.show() }
            GlassIcon(symbol: "square.and.pencil", help: "New chat") { chat.newChat() }
                .keyboardShortcut("n")
            GlassIcon(symbol: collapsed ? "chevron.down" : "chevron.up",
                      help: collapsed ? "Show the conversation" : "Shrink to just the box") { collapsed.toggle() }
            GlassIcon(symbol: pinned ? "pin.fill" : "pin", help: pinned ? "Stays on top (click to let go)" : "Keep on top") {
                pinned.toggle()
                pin(pinned)
            }
            GlassIcon(symbol: "xmark", help: "Close (⌘W)") { close() }
                .keyboardShortcut("w")
        }
    }
}

struct ModelMenu: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        Menu {
            ForEach(chat.models, id: \.self) { name in
                Button {
                    chat.model = name
                } label: {
                    if name == chat.model { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            Divider()
            Button("Look again") { chat.loadModels() }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(chat.problem == nil && !chat.model.isEmpty ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(chat.model.isEmpty ? "no model" : chat.model).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 0.5))
        .help("The model (from Ollama)")
    }
}

struct GlassIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
                .frame(width: 26, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct ChatMessages: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { m in
                        MessageRow(message: m, waiting: chat.phase == .thinking)
                            .id(m.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: chat.messages) { messages in
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04),
                                     .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

struct MessageRow: View {
    let message: ChatModel.Message
    let waiting: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 0.5))
            }
        case .assistant:
            if message.text.isEmpty {
                ThinkingDots()
            } else {
                Text(Self.markdown(message.text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .note:
            Label(message.text, systemImage: "brain")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
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

struct ChatInput: View {
    @ObservedObject var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Glass…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { chat.send() }
                .padding(.vertical, 3)
            if chat.phase == .idle {
                GlassIcon(symbol: "arrow.up.circle.fill", help: "Send (Return)") { chat.send() }
                    .disabled(chat.input.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                GlassIcon(symbol: "stop.circle.fill", help: "Stop (Esc)") { chat.stop() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 0.5))
        .onAppear { focused = true }
        .onExitCommand { chat.stop() }
    }
}
