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
