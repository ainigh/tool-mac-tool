import AppKit
import Combine
import SwiftUI

/// The tools' windows: one of each, made on first use and brought back after that.
@MainActor
enum Windows {
    private static var windows: [String: NSWindow] = [:]

    /// A normal titled window holding a SwiftUI view.
    static func show<Content: View>(_ id: String, title: String, size: NSSize,
                                    content: () -> Content) {
        if let w = windows[id] {
            bringForward(w)
            return
        }
        let w = ToolWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = FirstClickHostingView(rootView: content())
        w.center()
        w.setFrameAutosaveName("ToolMacTool.\(id)")
        windows[id] = w
        bringForward(w)
    }

    /// A window made elsewhere (the chat's glass panel), kept and brought back the same way.
    static func show(_ id: String, make: () -> NSWindow) {
        let w = windows[id] ?? make()
        windows[id] = w
        bringForward(w)
    }

    static func window(_ id: String) -> NSWindow? { windows[id] }

    static func bringForward(_ w: NSWindow) {
        // A menu bar app isn't frontmost by itself: come forward, or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// The keys a text field needs from an Edit menu (cut, copy, paste, select all, undo, redo). This
/// app has no menu bar, so nothing would carry them: its windows send them on themselves.
enum EditKeys {
    static func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector
        switch (key, flags.contains(.shift)) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: return false
        }
        return NSApp.sendAction(action, to: nil, from: nil)
    }

    /// ⌘ plus a letter, nothing else held.
    static func command(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
        return event.charactersIgnoringModifiers?.lowercased()
    }
}

/// A tool's titled window: the edit keys work, and ⌘W closes it.
final class ToolWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditKeys.command(event) == "w" {
            performClose(nil)
            return true
        }
        return EditKeys.handle(event) || super.performKeyEquivalent(with: event)
    }
}

/// A hosting view whose first click counts even while the app is in the background (a menu bar
/// app nearly always is): otherwise that click only brings the window forward.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless, see-through window that can still take the keyboard (plain borderless windows
/// can't), for UI that draws its own shape. It's moved only by a `WindowDragArea`: with "move by
/// the background" on, a click on a SwiftUI button can turn into a drag and never reach it.
class GlassPanel: NSPanel {
    /// ⌘ shortcuts, by letter (the edit keys are built in).
    var commands: [String: () -> Void] = [:]
    /// Esc: return true if it was used (e.g. to stop a reply), else it goes on as usual.
    var onEscape: (() -> Bool)?
    /// Any other key with no modifier held (the characters it types): return true if it was used.
    var onKey: ((String) -> Bool)?

    init(size: NSSize, resizable: Bool = false) {
        var style: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // the view draws its own glow
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let key = EditKeys.command(event), let command = commands[key] {
            command()
            return true
        }
        return EditKeys.handle(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Caught here, before the text field (which would take Esc for word completion).
        if event.type == .keyDown, event.keyCode == 53, onEscape?() == true { return }
        if event.type == .keyDown, let onKey, let key = event.characters,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
           onKey(key) { return }
        super.sendEvent(event)
    }
}

/// Drag here to move the window (SwiftUI views don't move a borderless window by themselves).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSWorkspace {
    /// Opens a folder in Finder, or shows a file selected in its folder.
    func show(_ url: URL) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            open(url)
        } else {
            activateFileViewerSelecting([url])
        }
    }
}

/// Hands over the window a view is in (nil once it leaves it).
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    final class ReaderView: NSView {
        var found: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { self.found?(w) }
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.found = found
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.found = found }
}

/// Runs an action every few seconds, but only while the view's window is on screen: a closed
/// window's views live on (so it comes back as it was), and a plain timer would keep going with them.
struct VisibleTick: ViewModifier {
    let action: () -> Void
    @State private var timer: Publishers.Autoconnect<Timer.TimerPublisher>
    @State private var window: NSWindow? = nil

    init(every seconds: TimeInterval, action: @escaping () -> Void) {
        self.action = action
        _timer = State(initialValue: Timer.publish(every: seconds, on: .main, in: .common).autoconnect())
    }

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onReceive(timer) { _ in
                if let window, window.isVisible, window.occlusionState.contains(.visible) { action() }
            }
    }
}

extension View {
    func onVisibleTick(every seconds: TimeInterval, perform action: @escaping () -> Void) -> some View {
        modifier(VisibleTick(every: seconds, action: action))
    }
}
