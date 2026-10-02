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

    func testLiveTranscriptKeepsRevisions() {
        var t = LiveTranscript()
        t.heard("I scream")
        t.heard("Ice cream is")
        t.heard("Ice cream is great, isn't it")
        XCTAssertEqual(t.text, "Ice cream is great, isn't it")
        t.heard("Ice cream is great. Isn't it?")
        XCTAssertEqual(t.text, "Ice cream is great. Isn't it?")
    }

    func testLiveTranscriptKeepsWhatCameBeforeARestart() {
        var t = LiveTranscript()
        t.heard("The meeting is on Tuesday at noon.")
        t.heard("Bring")                                  // started over after a pause
        t.heard("Bring the slides")
        XCTAssertEqual(t.text, "The meeting is on Tuesday at noon. Bring the slides")
        t.heard("")                                       // and again, with nothing yet
        t.heard("Thanks")
        XCTAssertEqual(t.text, "The meeting is on Tuesday at noon. Bring the slides Thanks")
    }

    func testLiveTranscriptSettles() {
        var t = LiveTranscript()
        t.heard("One two three")
        t.settle()
        t.heard("Four")
        XCTAssertEqual(t.settled, "One two three")
        XCTAssertEqual(t.text, "One two three Four")
        t.clear()
        XCTAssertEqual(t.text, "")
    }

    func testVoiceLineupPicksTwoWomenAndTwoMen() {
        func v(_ name: String, _ lang: String, _ q: VoiceInfo.Quality, _ female: Bool? = nil) -> VoiceInfo {
            VoiceInfo(identifier: "\(lang).\(name).\(q)", name: name, language: lang, quality: q, female: female)
        }
        let voices = [
            v("Samantha", "en-US", .standard), v("Samantha", "en-US", .enhanced), v("Ava", "en-US", .premium),
            v("Zoe", "en-US", .enhanced), v("Allison", "en-US", .enhanced),
            v("Fred", "en-US", .standard), v("Daniel", "en-GB", .standard), v("Evan", "en-US", .enhanced),
            v("Jamie", "en-GB", .premium), v("Rocko", "en-US", .standard, false),
        ]
        XCTAssertEqual(VoiceLineup.pick(voices).map(\.identifier),
                       ["en-US.Ava.premium", "en-US.Zoe.enhanced", "en-GB.Jamie.premium", "en-US.Evan.enhanced"])
    }

    func testVoiceLineupFallsBackOnWhatTheSystemSays() {
        let voices = [
            VoiceInfo(identifier: "a", name: "Amélie", language: "fr-CA", quality: .enhanced, female: true),
            VoiceInfo(identifier: "t", name: "Thomas", language: "fr-FR", quality: .standard, female: false),
            VoiceInfo(identifier: "x", name: "Mystery", language: "fr-FR", quality: .premium, female: nil),
        ]
        XCTAssertEqual(VoiceLineup.pick(voices).map(\.identifier), ["a", "t"])
    }
}
