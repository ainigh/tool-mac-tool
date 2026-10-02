import XCTest
@testable import ToolCore

final class SpeechTests: XCTestCase {
    func testCleanDropsMarkdownAndCode() {
        let reply = """
        # Plan
        Here is **bold**, *italic*, `code` and [a link](https://x.y).

        - first item
        2. second item
        > a quote
        ---
        ```swift
        let x = 1
        ```
        See https://example.com for more.
        """
        XCTAssertEqual(SpokenText.clean(reply), """
        Plan
        Here is bold, italic, code and a link.

        first item
        second item
        a quote

        See a link for more.
        """)
    }

    func testCleanKeepsSnakeCaseAndProducts() {
        XCTAssertEqual(SpokenText.clean("Set my_var_name to 2*3*4."), "Set my_var_name to 2*3*4.")
    }

    func testSentencesSplitAtEndsAndLines() {
        XCTAssertEqual(SpokenText.sentences("Hi there. How are you? Fine!\nNext line"),
                       ["Hi there.", "How are you?", "Fine!", "Next line"])
    }

    func testSentencesKeepAbbreviationsDecimalsAndQuotes() {
        XCTAssertEqual(SpokenText.sentences("Use e.g. butter. It costs 3.50 now. He said \"stop.\" Then left."),
                       ["Use e.g. butter.", "It costs 3.50 now.", "He said \"stop.\"", "Then left."])
        XCTAssertEqual(SpokenText.sentences("Ask J. Smith about it."), ["Ask J. Smith about it."])
    }

    func testSentencesSkipPunctuationOnly() {
        XCTAssertEqual(SpokenText.sentences("...\n- \nOk."), ["Ok."])
    }

    func testStreamHoldsBackTheLastSentence() {
        var s = SentenceStream()
        XCTAssertEqual(s.update("Hello"), [])
        XCTAssertEqual(s.update("Hello there. How"), ["Hello there."])
        XCTAssertEqual(s.update("Hello there. How are you"), [])
        XCTAssertEqual(s.update("Hello there. How are you? I'm"), ["How are you?"])
        XCTAssertEqual(s.finish("Hello there. How are you? I'm fine."), ["I'm fine."])
        XCTAssertEqual(s.finish("Hello there. How are you? I'm fine."), [])
    }

    func testStreamSkipsCodeWhileItStreams() {
        var s = SentenceStream()
        XCTAssertEqual(s.update("Try this.\n```\nprint(1). print(2). "), ["Try this."])
        XCTAssertEqual(s.finish("Try this.\n```\nprint(1). print(2).\n```\nDone."), ["Done."])
    }

    func testCaptions() {
        let segs = [TimedText(start: 0, end: 2.5, text: "Hello."), TimedText(start: 3661.2, end: 3662, text: "Bye.")]
        XCTAssertEqual(Captions.srt(segs), """
        1
        00:00:00,000 --> 00:00:02,500
        Hello.

        2
        01:01:01,200 --> 01:01:02,000
        Bye.

        """)
        XCTAssertEqual(Captions.vtt(segs), "WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nHello.\n\n01:01:01.200 --> 01:01:02.000\nBye.\n")
        XCTAssertEqual(Captions.plain(segs), "Hello. Bye.\n")
        XCTAssertEqual(Captions.clock(42), "0:42")
        XCTAssertEqual(Captions.clock(3723), "1:02:03")
    }

    func testQuietCut() {
        XCTAssertEqual(QuietCut.cut(levels: [5, 1, 4, 2, 3], from: 2), 3)
        XCTAssertEqual(QuietCut.cut(levels: [5, 1, 1, 4], from: 0), 2)   // the later of two
        XCTAssertEqual(QuietCut.cut(levels: [5, 1], from: 4), 2)
        XCTAssertEqual(QuietCut.cut(levels: [], from: 0), 0)
    }

    func testDictationFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 10, 2, 9, 5, 7)
        let date = Calendar.current.date(from: c)!
        let url = try Dictation.append("First note", folder: folder, at: date)
        try Dictation.append("Second", folder: folder, at: date)
        XCTAssertEqual(url.lastPathComponent, "glass-dictation-2026-10-02.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), """
        # Dictation, Friday 2 October 2026

        ### 09:05:07 · you (dictation)

        First note

        ### 09:05:07 · you (dictation)

        Second


        """)
    }
}
