import Foundation
import XCTest
@testable import ToolCore

final class RedactionTests: XCTestCase {
    func testParsesOneWordPerLineWhateverTheModelSends() {
        let answer = """
            <think>let me see</think>
            1. Ada Lovelace
            - Charles Babbage's
            * "Mary"
            Dr. Watson,
            ada
            NONE
            """
        XCTAssertEqual(Redaction.parseNames(answer), ["Ada", "Lovelace", "Charles", "Babbage", "Mary", "Watson"])
        XCTAssertEqual(Redaction.parseNames("NONE"), [])
        XCTAssertEqual(Redaction.parseNames("O'Brien\nJean-Luc\nJosé"), ["O'Brien", "Jean-Luc", "José"])
    }

    func testLearnAddsPlaceholdersAndCountsRepeats() {
        var map = RedactionMap()
        XCTAssertEqual(map.learn(["Ada", "Lovelace"]), ["Ada", "Lovelace"])
        XCTAssertEqual(map.entries.map(\.substitute), ["Person1", "Person2"])
        XCTAssertTrue(map.entries.allSatisfy(\.isNew))
        XCTAssertEqual(map.learn(["ADA", "Mary"]), ["Mary"])
        XCTAssertEqual(map.entry(for: "ada")?.seen, 2)
        XCTAssertEqual(map.entry(for: "Mary")?.substitute, "Person3")
        // A renamed placeholder isn't reused.
        map.entries[0].substitute = "Alex"
        XCTAssertEqual(map.nextPlaceholder(), "Person4")
    }

    func testSwapsWholeWordsKeepingCaseAndPossessives() {
        let pairs = [("John", "Person1"), ("Smith", "Person2"), ("Jo", "Person3")]
        let r = Redaction.apply("John Smith met JOHN and john's friend Johnny. Jo said hi to Smithson.", pairs: pairs)
        XCTAssertEqual(r.text, "Person1 Person2 met PERSON1 and person1's friend Johnny. Person3 said hi to Smithson.")
        XCTAssertEqual(r.used.map(\.original), ["John", "Smith", "Jo"])
        XCTAssertEqual(r.used.first?.count, 3)
    }

    func testOnePassNeverSwapsASubstituteAgain() {
        // A → B and B → C must not turn A into C.
        let r = Redaction.apply("Ann and Bea", pairs: [("Ann", "Bea"), ("Bea", "Cal")])
        XCTAssertEqual(r.text, "Bea and Cal")
    }

    func testLongestFirstForMultiWordEntries() {
        let r = Redaction.apply("Acme Corp and Acme", pairs: [("Acme", "Org1"), ("Acme Corp", "Org2")])
        XCTAssertEqual(r.text, "Org2 and Org1")
    }

    func testKeptAndSharedEntries() {
        var map = RedactionMap()
        map.learn(["May", "Robert", "Bob"])
        map.entries[0].keep = true                         // "May" is a month here
        map.entries[2].substitute = map.entries[1].substitute   // Bob is Robert
        XCTAssertEqual(map.shared, ["Person2"])
        let r = Redaction.apply("In May, Robert (Bob) called.", pairs: map.pairs)
        XCTAssertEqual(r.text, "In May, Person2 (Person2) called.")
        // Restoring gives back the first original of a shared substitute.
        XCTAssertEqual(Redaction.restore(r.text, map: map).text, "In May, Robert (Robert) called.")
    }

    func testRestoreRoundTrips() {
        var map = RedactionMap()
        map.learn(["Ada", "Lovelace"])
        let text = "Ada Lovelace wrote to ADA's friend."
        let red = Redaction.apply(text, pairs: map.pairs)
        XCTAssertEqual(Redaction.restore(red.text, map: map).text, text)
    }

    func testFrontMatter() {
        let r = Redaction.apply("Ada met \"Bo\"", pairs: [("Ada", "Person1")])
        let out = Redaction.withFrontMatter(r, at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(out.hasPrefix("---\nredacted: 1970-01-01T00:00:00Z\nsubstitutions:\n  \"Ada\": \"Person1\"\n---\n\n"))
        XCTAssertTrue(out.hasSuffix("Person1 met \"Bo\""))
        XCTAssertTrue(Redaction.withFrontMatter(Redaction.apply("x", pairs: [])).contains("substitutions: {}"))
    }

    func testChunksAtParagraphs() {
        let para = String(repeating: "word ", count: 30) // 150 characters
        let text = Array(repeating: para, count: 5).joined(separator: "\n\n")
        let pieces = Redaction.chunks(text, size: 400)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 400 })
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertEqual(Redaction.chunks("short"), ["short"])
        XCTAssertEqual(Redaction.chunks(""), [])
    }

    func testMapRoundTripsOnDisk() throws {
        var map = RedactionMap()
        map.learn(["Ada"])
        map.entries[0].note = "aunt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("redaction-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try map.save(to: url)
        let back = RedactionMap.load(from: url)
        XCTAssertEqual(back.entries.map(\.original), ["Ada"])
        XCTAssertEqual(back.entries.first?.note, "aunt")
    }
}

final class RedactionBucketsTests: XCTestCase {
    func testOldMapsLoadWithEverythingEveryday() throws {
        let json = #"{"entries":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","original":"Ada","substitute":"Person1","keep":false,"isNew":true,"seen":1,"added":"2026-10-06T12:00:00Z","note":""}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let map = try decoder.decode(RedactionMap.self, from: Data(json.utf8))
        XCTAssertEqual(map.entries.first?.critical, false)
        XCTAssertEqual(map.entries.first?.original, "Ada")
    }

    func testBothBucketsRedactAsOne() {
        var map = RedactionMap()
        map.learn(["Ada", "Bob"])
        map.entries[0].critical = true
        XCTAssertEqual(Redaction.apply("Ada and Bob", pairs: map.pairs).text, "Person1 and Person2")
        XCTAssertEqual(map.critical.map(\.original), ["Ada"])
    }

    func testLeakCheckFindsCriticalWordsAnywhere() {
        var map = RedactionMap()
        map.learn(["Ann", "Bob"])
        map.entries[0].critical = true
        map.entries[0].substitute = "Annabel"      // a stand-in that contains the name
        let red = Redaction.apply("Ann met Bob. Mail ann.smith@x.com or Mary-Ann.", pairs: map.pairs)
        XCTAssertEqual(red.text, "Annabel met Person2. Mail annabel.smith@x.com or Mary-Annabel.")
        // Every Ann went (the stand-in itself doesn't count).
        XCTAssertEqual(Redaction.leaks(in: red.text, map: map), [])
        // One the whole-word swap can't see: joined to another word.
        XCTAssertEqual(Redaction.leaks(in: "AnnSmith wrote", map: map), ["Ann"])
        // Only critical words are checked; kept ones never.
        XCTAssertEqual(Redaction.leaks(in: "Bobby", map: map), [])
        map.entries[0].keep = true
        XCTAssertEqual(Redaction.leaks(in: "AnnSmith", map: map), [])
    }
}
