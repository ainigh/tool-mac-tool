import Foundation
import XCTest
@testable import ToolCore

final class RoutinesTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// 2026-10-07 is a Wednesday.
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func testOldFilesHaveNoRepeatOrStatus() throws {
        let json = #"{"text":"hi","tint":1}"#
        let box = try JSONDecoder().decode(Board.Box.self, from: Data(json.utf8))
        XCTAssertNil(box.repeats)
        XCTAssertNil(box.status)
        let unknown = #"{"text":"hi","repeats":"yearly","status":"maybe"}"#
        let other = try JSONDecoder().decode(Board.Box.self, from: Data(unknown.utf8))
        XCTAssertNil(other.repeats)
        XCTAssertNil(other.status)
    }

    func testRoundTrip() throws {
        var box = Board.Box(text: "Pay rent")
        box.setRepeat(.monthly, now: date(7, 9))
        let back = try JSONDecoder().decode(Board.Box.self, from: JSONEncoder().encode(box))
        XCTAssertEqual(back, box)
        XCTAssertEqual(back.status, .todo)
    }

    func testStatusIsAtMostOne() {
        var box = Board.Box()
        box.toggle(.pending, now: date(7, 9))
        XCTAssertEqual(box.status, .pending)
        box.toggle(.completed, now: date(7, 9))
        XCTAssertEqual(box.status, .completed)
        box.toggle(.completed, now: date(7, 9))
        XCTAssertNil(box.status)
    }

    func testDailyRemindsEveryHourFromSixUntilCompleted() {
        var box = Board.Box(text: "Stretch")
        box.setRepeat(.daily, now: date(6, 23, 30))
        // Nothing at night.
        XCTAssertNil(box.reminderDue(now: date(7, 3), calendar: cal))
        // 6 AM.
        XCTAssertEqual(box.reminderDue(now: date(7, 6, 0), calendar: cal), date(7, 6))
        box.remindedAt = date(7, 6)
        XCTAssertNil(box.reminderDue(now: date(7, 6, 40), calendar: cal))
        // Pending: again the next hour.
        box.toggle(.pending, now: date(7, 6, 41))
        XCTAssertEqual(box.reminderDue(now: date(7, 7, 0, ), calendar: cal), date(7, 7))
        box.remindedAt = date(7, 7)
        // Completed: nothing more today, back tomorrow at 6 as To do.
        box.toggle(.completed, now: date(7, 7, 5))
        XCTAssertNil(box.reminderDue(now: date(7, 8), calendar: cal))
        XCTAssertNil(box.reminderDue(now: date(7, 22), calendar: cal))
        XCTAssertTrue(box.rollOver(now: date(8, 0, 1), calendar: cal))
        XCTAssertEqual(box.status, .todo)
        XCTAssertFalse(box.rollOver(now: date(8, 0, 2), calendar: cal))
        XCTAssertEqual(box.reminderDue(now: date(8, 6, 2), calendar: cal), date(8, 6))
    }

    func testLastHourIsTenPM() {
        var box = Board.Box()
        box.setRepeat(.daily, now: date(7, 5))
        XCTAssertEqual(box.reminderDue(now: date(7, 22, 59), calendar: cal), date(7, 22))
        XCTAssertNil(box.reminderDue(now: date(7, 23, 1), calendar: cal))
    }

    func testTurnedOnMidHourWaitsForTheNextHour() {
        var box = Board.Box()
        box.setRepeat(.daily, now: date(7, 14, 30))
        XCTAssertNil(box.reminderDue(now: date(7, 14, 45), calendar: cal))
        XCTAssertEqual(box.reminderDue(now: date(7, 15, 0), calendar: cal), date(7, 15))
    }

    func testWeeklyCompletedLastsUntilMonday() {
        var box = Board.Box()
        box.setRepeat(.weekly, now: date(5, 5))          // Monday 5 Oct, 5 AM
        XCTAssertEqual(box.reminderDue(now: date(5, 6), calendar: cal), date(5, 6))
        box.remindedAt = date(5, 6)
        box.toggle(.pending, now: date(5, 6, 1))
        // Not completed Monday: it carries on Tuesday.
        XCTAssertEqual(box.reminderDue(now: date(6, 6), calendar: cal), date(6, 6))
        box.remindedAt = date(6, 6)
        box.toggle(.completed, now: date(6, 6, 2))
        XCTAssertNil(box.reminderDue(now: date(9, 12), calendar: cal))     // Friday
        XCTAssertNil(box.reminderDue(now: date(11, 22), calendar: cal))    // Sunday
        XCTAssertFalse(box.rollOver(now: date(11, 23), calendar: cal))
        XCTAssertTrue(box.rollOver(now: date(12, 0, 5), calendar: cal))    // Monday
        XCTAssertEqual(box.reminderDue(now: date(12, 6), calendar: cal), date(12, 6))
    }

    func testMonthlyCompletedLastsUntilTheFirst() {
        var box = Board.Box()
        box.setRepeat(.monthly, now: date(1, 5))
        box.toggle(.completed, now: date(2, 10))
        XCTAssertNil(box.reminderDue(now: date(31, 12), calendar: cal))
        XCTAssertTrue(box.rollOver(now: date(1, 1, month: 11), calendar: cal))
        XCTAssertEqual(box.reminderDue(now: date(1, 6, month: 11), calendar: cal), date(1, 6, month: 11))
    }

    func testNoRepeatNoReminder() {
        var box = Board.Box()
        XCTAssertNil(box.reminderDue(now: date(7, 9), calendar: cal))
        XCTAssertFalse(box.rollOver(now: date(7, 9), calendar: cal))
        box.setRepeat(.daily, now: date(7, 5))
        box.setRepeat(nil, now: date(7, 5))
        XCTAssertNil(box.reminderDue(now: date(7, 9), calendar: cal))
    }

    // MARK: Modes and the test clock

    func testTestClockRunsSixtyTimesFaster() {
        let start = date(7, 9)
        let s = ModeState.entering(.test, at: start)
        XCTAssertEqual(s.mode, .test)
        let warp = try! XCTUnwrap(s.warp)
        // 24 real minutes is a day.
        XCTAssertEqual(warp.time(at: start.addingTimeInterval(24 * 60)), date(8, 9))
        XCTAssertEqual(warp.realSeconds(3600), 60)
        XCTAssertFalse(s.isOver(at: start.addingTimeInterval(29 * 60)))
        XCTAssertTrue(s.isOver(at: start.addingTimeInterval(30 * 60)))
    }

    func testQuietLastsAnHour() {
        let start = date(7, 9)
        let s = ModeState.entering(.quiet, at: start)
        XCTAssertNil(s.warp)
        XCTAssertEqual(s.remaining(at: start.addingTimeInterval(600)), 3000)
        XCTAssertTrue(s.isOver(at: start.addingTimeInterval(3600)))
        XCTAssertFalse(ModeState().isOver(at: start))
    }

    func testClockFollowsTheWarp() {
        defer { AppClock.warp = nil }
        let real = Date()
        AppClock.warp = ClockWarp(real: real, virtual: real, speed: 60)
        XCTAssertEqual(AppClock.time(at: real.addingTimeInterval(10)).timeIntervalSince(real), 600, accuracy: 0.001)
        AppClock.warp = nil
        XCTAssertEqual(AppClock.time(at: real), real)
    }
}

final class LinkPreviewTests: XCTestCase {
    let base = URL(string: "https://example.com/blog/post?x=1")!

    func testReadsOpenGraphTitleSiteAndIcons() {
        let html = """
            <html><head><title>Fallback &amp; title</title>
            <meta property="og:title" content="The &quot;Real&quot; Title">
            <meta property='og:site_name' content='Example'>
            <meta name="description" content="A page   about
              things">
            <link rel="icon" href="/favicon-32.png" sizes="32x32">
            <link rel="apple-touch-icon" href="https://cdn.example.com/touch.png">
            <link rel="stylesheet" href="/a.css">
            </head><body><meta property="og:title" content="not this"></body></html>
            """
        let m = LinkMeta.parse(html: html, base: base)
        XCTAssertEqual(m.title, "The \"Real\" Title")
        XCTAssertEqual(m.siteName, "Example")
        XCTAssertEqual(m.summary, "A page about things")
        XCTAssertEqual(m.icons.map(\.absoluteString), [
            "https://example.com/favicon-32.png",
            "https://cdn.example.com/touch.png",
            "https://example.com/favicon.ico",
        ])
    }

    func testFallsBackToTitleTagAndFavicon() {
        let m = LinkMeta.parse(html: "<HTML><HEAD><TITLE lang=en>\n  Hello &#8211; World &#x2014; ok\n</TITLE></HEAD>", base: base)
        XCTAssertEqual(m.title, "Hello – World — ok")
        XCTAssertEqual(m.icons, [URL(string: "https://example.com/favicon.ico")!])
        XCTAssertNil(m.siteName)
    }

    func testEmptyPage() {
        let m = LinkMeta.parse(html: "", base: base)
        XCTAssertNil(m.title)
        XCTAssertEqual(m.icons.count, 1)
    }

    func testDecodeLeavesStrayAmpersands() {
        XCTAssertEqual(LinkMeta.decode("Tom & Jerry &amp; co &bogus; &#39;x&#39;"), "Tom & Jerry & co &bogus; 'x'")
    }

    func testYouTubeIDs() {
        let id = "dQw4w9WgXcQ"
        for s in ["https://www.youtube.com/watch?v=\(id)", "https://youtube.com/watch?feature=share&v=\(id)",
                  "https://youtu.be/\(id)?t=42", "https://m.youtube.com/watch?v=\(id)",
                  "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/embed/\(id)",
                  "https://www.youtube.com/live/\(id)?si=abc", "https://music.youtube.com/watch?v=\(id)&list=x"] {
            XCTAssertEqual(YouTube.videoID(URL(string: s)!), id, s)
        }
        for s in ["https://www.youtube.com/", "https://www.youtube.com/@channel", "https://youtu.be/short",
                  "https://example.com/watch?v=\(id)", "https://www.youtube.com/watch?v=bad!id12345"] {
            XCTAssertNil(YouTube.videoID(URL(string: s)!), s)
        }
    }

    func testYouTubeStart() {
        XCTAssertEqual(YouTube.start(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=90")!), 90)
        XCTAssertEqual(YouTube.start(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=90s")!), 90)
        XCTAssertEqual(YouTube.start(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=1h2m3s")!), 3723)
        XCTAssertNil(YouTube.start(URL(string: "https://youtu.be/dQw4w9WgXcQ")!))
        XCTAssertNil(YouTube.start(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=abc")!))
    }

    func testPlayerPageEmbedsTheVideo() {
        let page = YouTube.playerPage("dQw4w9WgXcQ", start: 30)
        XCTAssertTrue(page.contains("https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0&start=30"))
        XCTAssertTrue(page.contains("referrerpolicy"))
    }
}
