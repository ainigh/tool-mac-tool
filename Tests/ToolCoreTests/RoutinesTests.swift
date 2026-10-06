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

    func testDailyRemindsEveryHourFromEightUntilCompleted() {
        var box = Board.Box(text: "Stretch")
        box.setRepeat(.daily, now: date(6, 23, 30))
        // Nothing at night, nor before 8.
        XCTAssertNil(box.reminderDue(now: date(7, 3), calendar: cal))
        XCTAssertNil(box.reminderDue(now: date(7, 7, 30), calendar: cal))
        // 8 AM.
        XCTAssertEqual(box.reminderDue(now: date(7, 8, 0), calendar: cal), date(7, 8))
        box.remindedAt = date(7, 8)
        XCTAssertNil(box.reminderDue(now: date(7, 8, 40), calendar: cal))
        // Pending: again the next hour.
        box.toggle(.pending, now: date(7, 8, 41))
        XCTAssertEqual(box.reminderDue(now: date(7, 9, 0), calendar: cal), date(7, 9))
        box.remindedAt = date(7, 9)
        // Completed: nothing more until 8 AM tomorrow, back then as To do.
        box.toggle(.completed, now: date(7, 9, 5))
        XCTAssertNil(box.reminderDue(now: date(7, 10), calendar: cal))
        XCTAssertNil(box.reminderDue(now: date(7, 22), calendar: cal))
        XCTAssertFalse(box.rollOver(now: date(8, 0, 1), calendar: cal))
        XCTAssertFalse(box.rollOver(now: date(8, 7, 59), calendar: cal))
        XCTAssertTrue(box.rollOver(now: date(8, 8, 0), calendar: cal))
        XCTAssertEqual(box.status, .todo)
        XCTAssertFalse(box.rollOver(now: date(8, 8, 1), calendar: cal))
        XCTAssertEqual(box.reminderDue(now: date(8, 8, 2), calendar: cal), date(8, 8))
    }

    func testDayBeginsAtEightTheDayBefore() {
        // Completed in the small hours counts for the day begun at 8 AM the day before.
        var box = Board.Box()
        box.setRepeat(.daily, now: date(6, 9))
        box.toggle(.completed, now: date(7, 2))
        XCTAssertTrue(box.isDone(now: date(7, 7, 59), calendar: cal))
        XCTAssertFalse(box.isDone(now: date(7, 8), calendar: cal))
        XCTAssertEqual(NoteRepeat.daily.period(containing: date(7, 7, 59), calendar: cal),
                       DateInterval(start: date(6, 8), end: date(7, 8)))
        XCTAssertEqual(NoteRepeat.daily.period(containing: date(7, 8), calendar: cal),
                       DateInterval(start: date(7, 8), end: date(8, 8)))
    }

    func testWeekAndMonthBeginAtEightTheDayBefore() {
        // The week of Monday 5 Oct begins Sunday 4 Oct, 8 AM.
        XCTAssertEqual(NoteRepeat.weekly.period(containing: date(7, 12), calendar: cal),
                       DateInterval(start: date(4, 8), end: date(11, 8)))
        XCTAssertEqual(NoteRepeat.weekly.period(containing: date(4, 7), calendar: cal),
                       DateInterval(start: date(27, 8, month: 9), end: date(4, 8)))
        XCTAssertEqual(NoteRepeat.weekly.period(containing: date(11, 9), calendar: cal),
                       DateInterval(start: date(11, 8), end: date(18, 8)))
        // October begins 30 September, 8 AM, and ends 31 October, 8 AM.
        XCTAssertEqual(NoteRepeat.monthly.period(containing: date(15, 12), calendar: cal),
                       DateInterval(start: date(30, 8, month: 9), end: date(31, 8)))
        XCTAssertEqual(NoteRepeat.monthly.period(containing: date(30, 9, month: 9), calendar: cal),
                       DateInterval(start: date(30, 8, month: 9), end: date(31, 8)))
        XCTAssertEqual(NoteRepeat.monthly.period(containing: date(31, 9), calendar: cal),
                       DateInterval(start: date(31, 8), end: date(30, 8, month: 11)))
    }

    func testPeriodAcrossTheClocksGoingBack() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ hour: Int) -> Date {
            ny.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        // The clocks go back on Sunday 1 November: the day still runs 8 AM to 8 AM.
        XCTAssertEqual(NoteRepeat.daily.period(containing: at(1, 12), calendar: ny),
                       DateInterval(start: at(1, 8), end: at(2, 8)))
        let saturday = ny.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8))!
        XCTAssertEqual(NoteRepeat.daily.period(containing: at(1, 7), calendar: ny),
                       DateInterval(start: saturday, end: at(1, 8)))
        XCTAssertEqual(at(1, 8).timeIntervalSince(saturday), 25 * 3600)
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

    func testPartsOfTheDayRemindOnlyInTheirHours() {
        let parts: [(NoteRepeat, first: Int, last: Int)] = [(.mornings, 8, 11), (.afternoons, 12, 16), (.evenings, 17, 22)]
        for (r, first, last) in parts {
            var box = Board.Box()
            box.setRepeat(r, now: date(6, 23, 30))
            XCTAssertNil(box.reminderDue(now: date(7, first - 1, 30), calendar: cal), r.title)
            XCTAssertEqual(box.reminderDue(now: date(7, first), calendar: cal), date(7, first), r.title)
            XCTAssertEqual(box.reminderDue(now: date(7, last, 59), calendar: cal), date(7, last), r.title)
            XCTAssertNil(box.reminderDue(now: date(7, last + 1, 0), calendar: cal), r.title)
            // Completed: not again until its hours tomorrow, To do again from 8 AM.
            box.remindedAt = date(7, last)
            box.toggle(.completed, now: date(7, last, 10))
            XCTAssertNil(box.reminderDue(now: date(7, last, 30), calendar: cal), r.title)
            XCTAssertTrue(box.isDone(now: date(8, 7, 59), calendar: cal), r.title)
            XCTAssertTrue(box.rollOver(now: date(8, 8), calendar: cal), r.title)
            XCTAssertEqual(box.reminderDue(now: date(8, first), calendar: cal), date(8, first), r.title)
        }
        XCTAssertEqual(NoteRepeat.mornings.hoursText, "8 AM to 11 AM")
        XCTAssertEqual(NoteRepeat.afternoons.hoursText, "12 PM to 4 PM")
        XCTAssertEqual(NoteRepeat.evenings.hoursText, "5 PM to 10 PM")
        XCTAssertEqual(NoteRepeat.daily.hoursText, "8 AM to 10 PM")
    }

    func testPartsOfTheDayRoundTrip() throws {
        var box = Board.Box(text: "Walk")
        box.setRepeat(.evenings, now: date(7, 9))
        let data = try JSONEncoder().encode(box)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"evenings\""))
        XCTAssertEqual(try JSONDecoder().decode(Board.Box.self, from: data), box)
    }

    func testWeeklyCompletedLastsUntilSunday() {
        var box = Board.Box()
        box.setRepeat(.weekly, now: date(4, 7))          // Sunday 4 Oct, 7 AM
        XCTAssertNil(box.reminderDue(now: date(4, 7, 30), calendar: cal))
        XCTAssertEqual(box.reminderDue(now: date(4, 8), calendar: cal), date(4, 8))
        box.remindedAt = date(4, 8)
        box.toggle(.pending, now: date(4, 8, 1))
        // Not completed Sunday: it carries on Monday.
        XCTAssertEqual(box.reminderDue(now: date(5, 8), calendar: cal), date(5, 8))
        box.remindedAt = date(5, 8)
        box.toggle(.completed, now: date(5, 8, 2))
        XCTAssertNil(box.reminderDue(now: date(9, 12), calendar: cal))     // Friday
        XCTAssertNil(box.reminderDue(now: date(10, 22), calendar: cal))    // Saturday
        XCTAssertFalse(box.rollOver(now: date(11, 7, 59), calendar: cal))
        XCTAssertTrue(box.rollOver(now: date(11, 8, 0), calendar: cal))    // Sunday, 8 AM
        XCTAssertEqual(box.reminderDue(now: date(11, 8, 5), calendar: cal), date(11, 8))
    }

    func testMonthlyCompletedLastsUntilTheLastDayAtEight() {
        var box = Board.Box()
        box.setRepeat(.monthly, now: date(1, 5))
        box.toggle(.completed, now: date(2, 10))
        XCTAssertNil(box.reminderDue(now: date(30, 12), calendar: cal))
        XCTAssertFalse(box.rollOver(now: date(31, 7), calendar: cal))
        XCTAssertTrue(box.rollOver(now: date(31, 8), calendar: cal))
        XCTAssertEqual(box.reminderDue(now: date(31, 8, 30), calendar: cal), date(31, 8))
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
