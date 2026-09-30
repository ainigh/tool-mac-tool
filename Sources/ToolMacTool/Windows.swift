import AppKit
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
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
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

/// A borderless, see-through window that can still take the keyboard (plain borderless windows
/// can't), for UI that draws its own shape.
final class GlassPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // the view draws its own glow
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Drag here to move the window (SwiftUI views don't move a borderless window by themselves).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override var mouseDownCanMoveWindow: Bool { true }
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
