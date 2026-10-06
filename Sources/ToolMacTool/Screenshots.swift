import AppKit
import ScreenCaptureKit
import SwiftUI
import ToolCore

// Screenshot: drag a box on the screen (or click for the whole screen) and a picture of what's
// in it goes on the clipboard, ready to paste. The same box-picking as Record screen.

@MainActor
final class Screenshots {
    private var picker: RegionPicker?
    private var busy = false

    /// The tile: choose a box, then take it.
    func take() {
        guard !busy else { return }
        guard ScreenRecorder.mayCapture() else { return }
        busy = true
        // A moment for the menu bar's panel to go away first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let picker = RegionPicker(hint: "Drag a box around what to copy  ·  click for the whole screen  ·  Esc to cancel") { [weak self] picked in
                guard let self else { return }
                self.picker = nil
                guard let picked else {
                    self.busy = false
                    return
                }
                Task { @MainActor in
                    await self.capture(picked.rect, on: picked.screen)
                    self.busy = false
                }
            }
            self.picker = picker
            picker.show()
        }
    }

    private func capture(_ rect: CGRect, on screen: NSScreen) async {
        do {
            let image = try await Self.image(of: rect, on: screen)
            let size = NSSize(width: rect.width, height: rect.height)
            let picture = NSImage(cgImage: image, size: size)
            let board = NSPasteboard.general
            board.clearContents()
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            board.writeObjects([picture])
            if let png { board.setData(png, forType: .png) }
            NSSound(named: NSSound.Name("Tink"))?.play()
            HUD.shared.show(title: "Screenshot on the clipboard",
                            message: "\(image.width) × \(image.height) pixels, ready to paste (⌘V).", ok: true, reveal: nil)
        } catch {
            HUD.shared.show(title: "Couldn't take the screenshot", message: error.localizedDescription, ok: false, reveal: nil)
        }
    }

    /// What's in `rect` (AppKit's screen coordinates, on `screen`), at the screen's full resolution.
    static func image(of rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let display = content.displays.first(where: { $0.displayID == number?.uint32Value }) ?? content.displays.first else {
            throw ScreenCapture.Problem("No screen to take it from")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let f = screen.frame
        let source = Recordings.sourceRect(Recordings.Box(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                                           screen: Recordings.Box(x: f.minX, y: f.minY, width: f.width, height: f.height))
        let scale = Double(screen.backingScaleFactor)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: source.x, y: source.y, width: source.width, height: source.height)
        config.width = max(1, Int((source.width * scale).rounded()))
        config.height = max(1, Int((source.height * scale).rounded()))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
