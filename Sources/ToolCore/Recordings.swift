import Foundation

/// Screen and audio recordings, kept in the Glass folder next to the dictations and chats:
/// glass-recording-<time>.mp4 (screen with sound), glass-screen-<time>.mp4 (screen only) and
/// glass-audio-<time>.m4a. A recording's transcript is the same name with .txt in place of its
/// extension.
public enum Recordings {
    public enum Kind: String, CaseIterable {
        /// A box of the screen, with the microphone.
        case screen
        /// A box of the screen, no sound.
        case screenOnly
        /// The microphone only.
        case audio

        public var prefix: String {
            switch self {
            case .screen: return "glass-recording"
            case .screenOnly: return "glass-screen"
            case .audio: return "glass-audio"
            }
        }

        public var fileExtension: String { self == .audio ? "m4a" : "mp4" }
    }

    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf"]

    public static func fileName(_ kind: Kind, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return "\(kind.prefix)-\(f.string(from: date)).\(kind.fileExtension)"
    }

    /// Where a new recording goes: its name for `date`, with " 2", " 3"… added if that's taken.
    public static func newURL(_ kind: Kind, folder: URL, at date: Date = Date()) -> URL {
        let first = folder.appendingPathComponent(fileName(kind, at: date))
        let fm = FileManager.default
        guard fm.fileExists(atPath: first.path) else { return first }
        let base = first.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let url = folder.appendingPathComponent("\(base) \(n).\(kind.fileExtension)")
            if !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    public static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    public static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }

    /// clip.mp4 → clip.txt, beside it.
    public static func transcriptURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("txt")
    }

    /// A recording in the folder.
    public struct Item: Identifiable, Hashable, Sendable {
        public let url: URL
        public let date: Date
        public let size: Int64
        public var id: String { url.path }
        public var name: String { url.lastPathComponent }
        public var isVideo: Bool { Recordings.isVideo(url) }
        public var transcript: URL { Recordings.transcriptURL(for: url) }

        public init(url: URL, date: Date, size: Int64) {
            self.url = url
            self.date = date
            self.size = size
        }
    }

    /// The videos and audio files in `folder` (not its subfolders), newest first.
    public static func list(in folder: URL) throws -> [Item] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        return urls.compactMap { url -> Item? in
            guard isVideo(url) || isAudio(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == false { return nil }
            let date = values?.contentModificationDate ?? .distantPast
            return Item(url: url, date: date, size: Int64(values?.fileSize ?? 0))
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name > $1.name }
    }

    // MARK: - The box on the screen

    /// A rectangle in points.
    public struct Box: Equatable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    /// The box dragged from `a` to `b` (either way round), kept inside `bounds`.
    public static func box(from a: (x: Double, y: Double), to b: (x: Double, y: Double), within bounds: Box) -> Box {
        let x0 = min(max(min(a.x, b.x), bounds.x), bounds.maxX)
        let x1 = min(max(max(a.x, b.x), bounds.x), bounds.maxX)
        let y0 = min(max(min(a.y, b.y), bounds.y), bounds.maxY)
        let y1 = min(max(max(a.y, b.y), bounds.y), bounds.maxY)
        return Box(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// A box on screen (AppKit's coordinates: global, y up) as ScreenCaptureKit wants it: relative
    /// to that screen's top-left corner, y down.
    public static func sourceRect(_ box: Box, screen: Box) -> Box {
        Box(x: box.x - screen.x, y: screen.maxY - box.maxY, width: box.width, height: box.height)
    }

    /// The video's size in pixels for a box of `width` × `height` points on a screen with `scale`
    /// pixels a point: both even (H.264 needs that), and scaled down to fit H.264's largest frame
    /// (4096 wide, 2304 high, or as many pixels as that).
    public static func pixelSize(width: Double, height: Double, scale: Double) -> (width: Int, height: Int) {
        var w = max(1, width * scale), h = max(1, height * scale)
        let maxSide = 4096.0, maxArea = 4096.0 * 2304
        let fit = min(1, maxSide / max(w, h), (maxArea / (w * h)).squareRoot())
        w *= fit
        h *= fit
        let even = { (v: Double) in max(2, Int(v / 2) * 2) }
        return (even(w), even(h))
    }
}
