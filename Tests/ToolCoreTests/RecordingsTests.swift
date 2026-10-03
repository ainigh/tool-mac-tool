import XCTest
@testable import ToolCore

final class RecordingsTests: XCTestCase {
    private var date: Date {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 3, 14, 5, 7)
        return Calendar.current.date(from: c)!
    }

    func testFileNames() {
        XCTAssertEqual(Recordings.fileName(.screen, at: date), "glass-recording-2026-10-03-14.05.07.mp4")
        XCTAssertEqual(Recordings.fileName(.screenOnly, at: date), "glass-screen-2026-10-03-14.05.07.mp4")
        XCTAssertEqual(Recordings.fileName(.audio, at: date), "glass-audio-2026-10-03-14.05.07.m4a")
    }

    func testTranscriptSitsBesideIt() {
        let video = URL(fileURLWithPath: "/a/b/glass-recording-2026-10-03-14.05.07.mp4")
        XCTAssertEqual(Recordings.transcriptURL(for: video).path, "/a/b/glass-recording-2026-10-03-14.05.07.txt")
        XCTAssertEqual(Recordings.transcriptURL(for: URL(fileURLWithPath: "/x/talk.m4a")).lastPathComponent, "talk.txt")
    }

    func testNewURLAvoidsTakenNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = Recordings.newURL(.audio, folder: folder, at: date)
        XCTAssertEqual(first.lastPathComponent, "glass-audio-2026-10-03-14.05.07.m4a")
        try Data().write(to: first)
        XCTAssertEqual(Recordings.newURL(.audio, folder: folder, at: date).lastPathComponent,
                       "glass-audio-2026-10-03-14.05.07 2.m4a")
    }

    func testListsVideosAndAudioNewestFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fm = FileManager.default
        let minutes = ["old.mp4": 0, "notes.md": 1, "mid.MOV": 2, "clip.txt": 3, "new.m4a": 4]
        for (name, minute) in minutes {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(minute) * 60)],
                                 ofItemAtPath: url.path)
        }
        try fm.createDirectory(at: folder.appendingPathComponent("sub.mp4"), withIntermediateDirectories: true)
        let items = try Recordings.list(in: folder)
        XCTAssertEqual(items.map(\.name), ["new.m4a", "mid.MOV", "old.mp4"])
        XCTAssertEqual(items.map(\.isVideo), [false, true, true])
    }

    func testBoxEitherWayAndClamped() {
        let screen = Recordings.Box(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(Recordings.box(from: (80, 40), to: (20, 10), within: screen),
                       Recordings.Box(x: 20, y: 10, width: 60, height: 30))
        XCTAssertEqual(Recordings.box(from: (-10, 20), to: (150, 70), within: screen),
                       Recordings.Box(x: 0, y: 20, width: 100, height: 30))
    }

    func testSourceRectIsFromTheTopLeft() {
        // A second screen to the right, 1000 × 800, its bottom at y = 0.
        let screen = Recordings.Box(x: 1440, y: 0, width: 1000, height: 800)
        let box = Recordings.Box(x: 1540, y: 600, width: 300, height: 150)
        XCTAssertEqual(Recordings.sourceRect(box, screen: screen), Recordings.Box(x: 100, y: 50, width: 300, height: 150))
    }

    func testPixelSizeIsEvenAndFitsH264() {
        XCTAssertEqual(Recordings.pixelSize(width: 401, height: 301, scale: 1).width, 400)
        XCTAssertEqual(Recordings.pixelSize(width: 401, height: 301, scale: 1).height, 300)
        XCTAssertEqual(Recordings.pixelSize(width: 640.5, height: 360, scale: 2).width, 1280)
        let big = Recordings.pixelSize(width: 2560, height: 1440, scale: 2)       // a 5K screen
        XCTAssertLessThanOrEqual(big.width, 4096)
        XCTAssertLessThanOrEqual(big.width * big.height, 4096 * 2304)
        XCTAssertEqual(big.width % 2, 0)
        XCTAssertEqual(big.height % 2, 0)
        let tall = Recordings.pixelSize(width: 1000, height: 5000, scale: 1)
        XCTAssertLessThanOrEqual(tall.height, 4096)
        XCTAssertEqual(Recordings.pixelSize(width: 0, height: 0, scale: 2).width, 2)
    }
}
