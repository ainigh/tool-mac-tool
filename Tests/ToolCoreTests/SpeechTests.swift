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

    /// `seconds` of a steady tone at `level` (rms), or silence.
    private func audio(_ seconds: Double, level: Float = 0) -> [Float] {
        let n = Int(seconds * Double(PhraseCutter.rate))
        return (0..<n).map { i in level == 0 ? 0 : (i % 2 == 0 ? level : -level) }
    }

    func testPhraseCutterEndsAPhraseAtThePause() {
        var c = PhraseCutter(pause: 0.6)
        XCTAssertEqual(c.add(audio(2)), [])                      // quiet: nothing yet
        XCTAssertEqual(c.add(audio(1.5, level: 0.1)).count, 0)   // speaking
        let done = c.add(audio(1))                               // a pause
        XCTAssertEqual(done.count, 1)
        // The speech, a little quiet in front of it and the pause: 0.3 + 1.5 + 0.6 s.
        XCTAssertEqual(Double(done[0].samples.count) / 16_000, 2.4, accuracy: 0.03)
        XCTAssertEqual(done[0].samples.filter { $0 != 0 }.count, Int(1.5 * 16_000))
        XCTAssertTrue(done[0].paused)
        XCTAssertFalse(c.spoke)
    }

    func testPhraseCutterKeepsEverySpokenSampleInOddSizedPieces() {
        var c = PhraseCutter(pause: 0.5, longest: 4)
        var stream = audio(0.4)
        for _ in 0..<3 { stream += audio(3.3, level: 0.2) + audio(0.2) }   // runs on past `longest`
        stream += audio(1.1, level: 0.05) + audio(0.8)
        var phrases: [[Float]] = []
        var i = 0
        while i < stream.count {
            let n = min(777, stream.count - i)
            phrases += c.add(Array(stream[i..<(i + n)])).map(\.samples)
            i += n
        }
        if let rest = c.flush() { phrases.append(rest) }
        XCTAssertGreaterThan(phrases.count, 1)
        XCTAssertTrue(phrases.allSatisfy { Double($0.count) / 16_000 <= 4.05 })
        let spoken = stream.filter { $0 != 0 }.count
        XCTAssertEqual(phrases.reduce(0) { $0 + $1.filter { $0 != 0 }.count }, spoken)
    }

    func testPhraseCutterFlushesOnlyWhenSomethingWasSaid() {
        var c = PhraseCutter(pause: 1)
        _ = c.add(audio(2))
        XCTAssertNil(c.flush())
        _ = c.add(audio(0.5, level: 0.1))
        XCTAssertEqual(c.flush().map { Double($0.count) / 16_000 } ?? 0, 0.8, accuracy: 0.03)
    }

    func testTimedSentences() {
        let words = [TimedWord(word: "Hi", start: 0.1, end: 0.3), TimedWord(word: "there.", start: 0.3, end: 0.6),
                     TimedWord(word: "Bye.", start: 1.0, end: 1.4)]
        XCTAssertEqual(Captions.sentences("Hi there. Bye.", words: words, offset: 10),
                       [TimedText(start: 10.1, end: 10.6, text: "Hi there."), TimedText(start: 11, end: 11.4, text: "Bye.")])
        XCTAssertEqual(Captions.sentences("Hi.", words: [], offset: 0), [])
    }

    func testWordRange() {
        let s = "I don't know, really."
        XCTAssertEqual(SpokenText.wordRange(in: s, at: 0).map { (s as NSString).substring(with: $0) }, "I")
        XCTAssertEqual(SpokenText.wordRange(in: s, at: 0.3).map { (s as NSString).substring(with: $0) }, "don't")
        XCTAssertEqual(SpokenText.wordRange(in: s, at: 1).map { (s as NSString).substring(with: $0) }, "really")
        XCTAssertNil(SpokenText.wordRange(in: "...", at: 0.5))
    }

    func testNeuralVoices() {
        XCTAssertEqual(NeuralVoice.all.filter(\.female).count, 2)
        XCTAssertEqual(NeuralVoice.all.filter { !$0.female }.count, 2)
        XCTAssertEqual(NeuralVoice.named("am_fenrir").name, "Fenrir")
        XCTAssertEqual(NeuralVoice.named("nope").id, "af_heart")
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
