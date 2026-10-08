import Foundation

/// Keeps a window where it can be grabbed: its top strip (where you drag it from) on a screen.
///
/// A window whose top is on a screen is left alone, even one hanging off a side or across two
/// displays (you put it there). One whose top is hidden (above a screen, under the menu bar, on a
/// display that's been unplugged) is moved, and shrunk if it's bigger than the screen, to sit inside
/// the screen it's mostly on (else the one given as `fallback`, the pointer's).
public enum ScreenFit {
    /// How deep the strip along the top is that must be on a screen.
    public static let strip: CGFloat = 32
    /// How much of the strip's width must be on a screen (or all of it, for a narrower window).
    public static let reach: CGFloat = 120

    /// The frame the window should have, or nil when it's fine where it is. `screens` are the
    /// screens' visible frames (without the menu bar and the Dock), in the same coordinates
    /// (AppKit's: y goes up).
    public static func corrected(_ frame: CGRect, screens: [CGRect], fallback: Int? = nil) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        if fine(frame, screens: screens) { return nil }
        let v = screens[home(frame, screens: screens) ?? fallback ?? 0]
        var f = frame
        f.size.width = min(f.width, v.width)
        f.size.height = min(f.height, v.height)
        f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
        f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
        return CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(.down), height: f.height.rounded(.down))
    }

    /// Its top strip is on a screen (whatever else of it isn't).
    static func fine(_ frame: CGRect, screens: [CGRect]) -> Bool {
        let top = CGRect(x: frame.minX, y: frame.maxY - strip, width: frame.width, height: strip)
        return screens.contains { v in
            let part = top.intersection(v)
            return !part.isNull && part.height >= strip - 0.5 && part.width >= min(reach, frame.width) - 0.5
        }
    }

    /// The screen with most of the window on it (nil: it's on none).
    static func home(_ frame: CGRect, screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, v) in screens.enumerated() {
            let part = frame.intersection(v)
            guard !part.isNull, part.width > 0, part.height > 0 else { continue }
            let area = part.width * part.height
            if area > (best?.area ?? 0) { best = (i, area) }
        }
        return best?.index
    }
}
