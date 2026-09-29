import AppKit
import SwiftUI

/// A borderless, see-through card that drops in under the menu bar to say how a tool went, then
/// fades away. It's an ordinary AppKit panel with a clear background and SwiftUI's material inside:
/// the pattern for any floating, frameless, transparent UI a future tool needs.
@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(title: String, message: String, ok: Bool, reveal: URL?) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = HUDView(title: title, message: message, ok: ok, reveal: reveal,
                           onReveal: { [weak self] in
                               if let reveal { NSWorkspace.shared.activateFileViewerSelecting([reveal]) }
                               self?.hide()
                           },
                           onClose: { [weak self] in self?.hide() })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrame(NSRect(x: v.maxX - size.width - 12, y: v.maxY - size.height - 8,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (ok ? 5 : 9) * 1_000_000_000)
            if !Task.isCancelled { self?.hide() }
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
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
                if reveal != nil {
                    Button("Show in Finder", action: onReveal)
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .padding(1)
    }
}
