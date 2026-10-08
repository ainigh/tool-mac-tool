import AppKit
import ApplicationServices
import Combine
import SwiftUI
import ToolCore

/// Talk to type: hold a key anywhere (a browser's text box, a chat, a document), talk, and let go:
/// what you said is written down on this Mac (Parakeet, as Dictate does) and typed where the
/// cursor is. A tap instead of a hold listens hands-free until the next tap; Esc drops it. A small
/// pill near the bottom of the screen shows it listening, without taking the keyboard from the
/// app you're typing in.
///
/// Watching the key in other apps and typing into them takes macOS's Accessibility permission;
/// what's said goes in by the clipboard and ⌘V (put back as it was a moment later), which every
/// text field takes.
@MainActor
final class TalkToType: ObservableObject {
    static let shared = TalkToType()

    /// The key to hold. Each is one you seldom use by itself.
    enum Key: String, CaseIterable, Identifiable {
        case rightOption, rightCommand, fn
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rightOption: return "Right Option (⌥)"
            case .rightCommand: return "Right Command (⌘)"
            case .fn: return "Fn (🌐)"
            }
        }

        var short: String {
            switch self {
            case .rightOption: return "right ⌥"
            case .rightCommand: return "right ⌘"
            case .fn: return "Fn"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .rightOption: return 61
            case .rightCommand: return 54
            case .fn: return 63
            }
        }

        /// Held, in a key change: the right-hand key itself (the left one sets the same flag).
        func isDown(_ event: NSEvent) -> Bool {
            switch self {
            case .rightOption: return event.modifierFlags.rawValue & 0x40 != 0      // NX_DEVICERALTKEYMASK
            case .rightCommand: return event.modifierFlags.rawValue & 0x10 != 0     // NX_DEVICERCMDKEYMASK
            case .fn: return event.modifierFlags.contains(.function)
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        /// Let go: the last words are being written down.
        case writing
    }

    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "talkToType.on")
    @Published var key = Key(rawValue: UserDefaults.standard.string(forKey: "talkToType.key") ?? "") ?? .rightOption {
        didSet { UserDefaults.standard.set(key.rawValue, forKey: "talkToType.key") }
    }
    /// macOS lets it watch the key and type: System Settings → Privacy & Security → Accessibility.
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var phase = Phase.idle
    /// What it typed lately, newest first (to copy again).
    @Published private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "talkToType.recent") ?? []
    @Published var problem: String?

    let listener = Listener()
    private var gesture = TalkKey()
    private var monitors: [Any] = []
    private var trustTimer: Timer?
    private var waiting: Timer?
    private var pill: NSPanel?
    private var watchingMic: AnyCancellable?

    init() {
        // The microphone opens a moment after the key goes down (macOS is asked first): if the
        // key was let go meanwhile, it's closed again straight away.
        watchingMic = listener.$on.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.listener.on, self.phase == .idle else { return }
                self.listener.stop()
                self.listener.clear()
            }
        }
    }

    /// At launch: listening for the key, if it's on.
    func start() {
        if enabled { install() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "talkToType.on")
        if on {
            askForTrust()
            install()
        } else {
            removeMonitors()
            trustTimer?.invalidate()
            trustTimer = nil
            cancel()
        }
    }

    /// macOS's question (it opens System Settings at Accessibility, with the app in the list).
    func askForTrust() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: The key

    private func install() {
        removeMonitors()
        trusted = AXIsProcessTrusted()
        let handle: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handle(event)
            return event
        }) { monitors.append(m) }
        // Other apps' keys only reach it once it's allowed: watch for that, then listen afresh.
        if !trusted, trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    if self.enabled { self.install() }
                }
            }
        }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
    }

    private func handle(_ event: NSEvent) {
        guard enabled else { return }
        // The last words being written down: only Esc counts (it drops them).
        if phase == .writing {
            if event.type == .keyDown, event.keyCode == 53 { cancel() }
            return
        }
        let now = Date()
        let effect: TalkKey.Effect
        switch event.type {
        case .flagsChanged:
            // Another modifier with ours held makes a shortcut of it.
            guard event.keyCode == key.keyCode else {
                effect = gesture.otherKey()
                break
            }
            effect = key.isDown(event) ? gesture.down(at: now) : gesture.up(at: now)
        case .keyDown:
            effect = event.keyCode == 53 ? gesture.escape() : gesture.otherKey()
        default:
            effect = .none
        }
        apply(effect)
    }

    private func apply(_ effect: TalkKey.Effect) {
        switch effect {
        case .none:
            if case .listening = phase, gesture.state == .handsFree { phase = .listening(handsFree: true) }
        case .start: begin()
        case .finish: finish()
        case .cancel: cancel()
        }
    }

    // MARK: Listening

    private func begin() {
        problem = nil
        listener.pauseToEnd = nil
        listener.clear()
        listener.start()
        phase = .listening(handsFree: false)
        showPill()
    }

    /// Stops; once the last words are written down, they're typed where the cursor is.
    private func finish() {
        listener.stop()
        phase = .writing
        waiting?.invalidate()
        waiting = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWritten() }
        }
    }

    private func checkWritten() {
        // The microphone opened only after the key went up: closed now, its words written down.
        if listener.on {
            listener.stop()
            return
        }
        // Speech recognition still downloading (the first time): the words wait for it; Esc drops them.
        guard !listener.finishing else { return }
        waiting?.invalidate()
        waiting = nil
        let heard = TalkKey.text(listener.text)
        listener.clear()
        problem = listener.problem
        phase = .idle
        hidePill()
        guard let heard else { return }
        recent.insert(heard, at: 0)
        recent = Array(recent.prefix(20))
        UserDefaults.standard.set(recent, forKey: "talkToType.recent")
        Self.type(heard)
    }

    /// Esc, a shortcut with the key, or turned off: nothing goes in.
    private func cancel() {
        gesture.reset()
        waiting?.invalidate()
        waiting = nil
        listener.stop()
        listener.clear()
        phase = .idle
        hidePill()
    }

    // MARK: Typing it

    /// Puts `text` where the cursor is, in whatever app has it: on the clipboard, then ⌘V, then the
    /// clipboard as it was (unless something else was copied meanwhile).
    static func type(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    // MARK: The pill

    private func showPill() {
        let panel = pill ?? makePill()
        pill = panel
        let v = Windows.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: (v.midX - size.width / 2).rounded(), y: v.minY + 40))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hidePill() {
        pill?.orderOut(nil)
    }

    private func makePill() -> NSPanel {
        // Never takes the keyboard: the text field you're typing in keeps it.
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TalkPill(talk: self, listener: listener))
        host.sizingOptions = []
        p.contentView = host
        return p
    }
}

/// Listening: the level, what's been heard so far, and how to finish.
struct TalkPill: View {
    @ObservedObject var talk: TalkToType
    @ObservedObject var listener: Listener
    @ObservedObject private var neural = Neural.shared

    var hint: String {
        switch talk.phase {
        case .listening(handsFree: true): return "Tap \(talk.key.short) to type it · Esc to drop it"
        case .listening: return "Let go to type it · tap for hands-free · Esc to drop it"
        case .writing: return "Writing it down…"
        case .idle: return ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Bars(level: talk.phase == .writing ? 0 : listener.level)
            VStack(alignment: .leading, spacing: 2) {
                Text(listener.problem ?? Neural.status(neural.ears, what: "speech recognition")
                     ?? (listener.text.isEmpty ? "Listening…" : listener.text))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 64)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    private struct Bars: View {
        let level: Float

        var body: some View {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let shape: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: 6 + 22 * CGFloat(level) * shape[i])
                }
            }
            .frame(width: 32, height: 30)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }
}

/// The tool's window: on or off, which key, the Accessibility permission, and what it typed lately.
enum TalkToTypeWindow {
    @MainActor
    static func show() {
        Windows.show("talk-to-type", title: "Talk to type", size: NSSize(width: 480, height: 520)) {
            TalkToTypeView(talk: TalkToType.shared)
        }
    }
}

struct TalkToTypeView: View {
    @ObservedObject var talk: TalkToType

    var body: some View {
        Form {
            Section {
                Toggle("Talk to type", isOn: Binding(get: { talk.enabled }, set: { talk.setEnabled($0) }))
                Picker("Key", selection: $talk.key) {
                    ForEach(TalkToType.Key.allCases) { Text($0.title).tag($0) }
                }
                Text("Hold \(talk.key.short) anywhere, talk, and let go: what you said is typed where the cursor is (a browser's text box, a chat, a document). Tap it instead to keep listening hands-free until you tap it again. Esc drops it. It's written down on this Mac, as Dictate does.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if talk.key == .fn {
                    Text("If Fn opens the emoji picker or starts macOS's own dictation, set System Settings → Keyboard → \"Press 🌐 key to\" to Do Nothing.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section("Permission") {
                HStack {
                    Image(systemName: talk.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(talk.trusted ? Color.green : Color.orange)
                    Text(talk.trusted ? "Accessibility is on: it can hear the key in other apps and type there."
                                      : "Turn on Tool Mac Tool in System Settings → Privacy & Security → Accessibility, so it can hear the key in other apps and type there. (After an update macOS may want it turned off and on again.)")
                        .font(.callout)
                }
                if !talk.trusted {
                    HStack {
                        Button("Open Settings") { talk.openAccessibilitySettings() }
                        Button("Ask again") { talk.askForTrust() }
                    }
                }
                if let problem = talk.problem {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
            Section("Typed lately") {
                if talk.recent.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(Array(talk.recent.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .top) {
                        Text(text).lineLimit(3).textSelection(.enabled)
                        Spacer()
                        Button { talk.copy(text) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onVisibleTick(every: 2) {
            if !talk.trusted { talk.refreshTrust() }
        }
    }
}

extension TalkToType {
    /// Looks again (the window shows whether it's allowed, and it may have just been allowed).
    func refreshTrust() {
        let now = AXIsProcessTrusted()
        if now != trusted { trusted = now }
    }
}
