import AppKit
import SwiftUI

/// A borderless, see-through card that drops in under the menu bar to say how a tool went. It
/// stays until you close it (nothing pops up and then goes by itself); several stack up. It's an
/// ordinary AppKit panel with a clear background and SwiftUI's material inside: the pattern for
/// any floating, frameless, transparent UI a future tool needs. In quiet mode it waits.
@MainActor
final class HUD {
    static let shared = HUD()

    enum Place { case topRight, center }

    func show(title: String, message: String, ok: Bool, reveal: URL?, at place: Place = .topRight) {
        if ModeCenter.shared.hold("hud-\(UUID().uuidString)", { [weak self] in
            self?.show(title: title, message: message, ok: ok, reveal: reveal, at: place)
        }) { return }
        StackedCards.shared.show(place == .center ? .center : .topRight, level: .statusBar) { close in
            HUDView(title: title, message: message, ok: ok, reveal: reveal,
                    onReveal: {
                        if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                        close()
                    },
                    onClose: close)
        }
    }
}

/// Small cards that stay on screen until they're closed: at the top right, stacked down from the
/// menu bar (a new column to the left when one fills), or in the middle, each a little below the
/// last. Closing one closes the gap.
@MainActor
final class StackedCards {
    static let shared = StackedCards()

    enum Place { case topRight, center }

    private struct Card {
        let id: Int
        let panel: NSPanel
        let place: Place
    }

    private var cards: [Card] = []
    private var count = 0

    /// Shows a card made by `make` (given what closes it), and returns what closes it.
    @discardableResult
    func show<V: View>(_ place: Place, level: NSWindow.Level, make: (_ close: @escaping () -> Void) -> V) -> () -> Void {
        count += 1
        let id = count
        let close: () -> Void = { [weak self] in self?.close(id) }
        let panel = Self.makePanel(level: level)
        let host = FirstClickHostingView(rootView: make(close))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        cards.append(Card(id: id, panel: panel, place: place))
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        return close
    }

    func close(_ id: Int) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards.remove(at: i)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            card.panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in card.panel.orderOut(nil) }
        })
        layout()
    }

    /// Every card in its place: the newest at the top.
    private func layout() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var x = v.maxX - 12, y = v.maxY - 8, columnWidth: CGFloat = 0
        for card in cards.reversed() where card.place == .topRight {
            let size = card.panel.frame.size
            if y - size.height < v.minY + 8, columnWidth > 0 {
                x -= columnWidth + 10
                y = v.maxY - 8
                columnWidth = 0
            }
            card.panel.setFrameOrigin(NSPoint(x: x - size.width, y: y - size.height))
            y -= size.height + 8
            columnWidth = max(columnWidth, size.width)
        }
        let middle = cards.filter { $0.place == .center }
        for (n, card) in middle.enumerated() {
            let size = card.panel.frame.size
            let step = CGFloat(n) * 28
            card.panel.setFrameOrigin(NSPoint(x: v.midX - size.width / 2 + step, y: v.midY - size.height / 2 - step))
        }
    }

    private static func makePanel(level: NSWindow.Level) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = level
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

struct HUDView: View {
    let title: String
    let message: String
    let ok: Bool
    let reveal: URL?
    let onReveal: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if reveal != nil {
                        Button("Show in Finder", action: onReveal)
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                    Button("OK", action: onClose)
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(14)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .padding(1)
    }
}
