import XCTest
@testable import ToolCore

final class NoteTextTests: XCTestCase {
    func testLinesTakeTheirSizes() {
        XCTAssertEqual(NoteText.scales(["Title", "About", "Body", "More"], titleScale: 2), [2, 1.5, 1, 1])
        XCTAssertEqual(NoteText.scales([""], titleScale: 2), [2])
    }

    func testAPointIsALittleSmallerThanTheLineAboveIt() {
        let s = NoteText.scales(["Title", "About", "- one", "  - two", "Body", "- three"], titleScale: 2)
        XCTAssertEqual(s[1], 1.5, accuracy: 0.0001)
        XCTAssertEqual(s[2], 1.5 * NoteText.pointScale, accuracy: 0.0001)  // under the second line
        XCTAssertEqual(s[3], 1.5 * NoteText.pointScale, accuracy: 0.0001)  // a point under a point: the same
        XCTAssertEqual(s[4], 1, accuracy: 0.0001)
        XCTAssertEqual(s[5], NoteText.pointScale, accuracy: 0.0001)
        // A point right under the title is a little smaller than the title.
        XCTAssertEqual(NoteText.scales(["Title", "- under the title"], titleScale: 2)[1], 2 * NoteText.pointScale, accuracy: 0.0001)
    }

    func testTheFirstLineIsTheTitleEvenAsAPoint() {
        XCTAssertEqual(NoteText.scales(["- Title", "- a"], titleScale: 2)[0], 2)
        XCTAssertFalse(NoteText.isPoint("-not a point"))
        XCTAssertTrue(NoteText.isPoint("\t- tabbed"))
    }

    func testTheRuleWaitsForAThirdLine() {
        XCTAssertFalse(NoteText.hasRule("Title\nAbout"))
        XCTAssertTrue(NoteText.hasRule("Title\nAbout\n"))
        XCTAssertTrue(NoteText.hasRule("Title\nAbout\nBody"))
    }

    func testAppendingGoesOnALineOfItsOwn() {
        XCTAssertEqual(NoteText.appending(" hello ", to: ""), "hello")
        XCTAssertEqual(NoteText.appending("hello", to: "  \n"), "hello")
        XCTAssertEqual(NoteText.appending("hello", to: "Title"), "Title\nhello")
        XCTAssertEqual(NoteText.appending("hello", to: "Title\n"), "Title\nhello")
        XCTAssertEqual(NoteText.appending("   ", to: "Title"), "Title")
    }
}
