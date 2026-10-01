import XCTest
@testable import ToolCore

final class ProseTests: XCTestCase {
    func testHeadingsListsQuotesAndRules() {
        let blocks = ProseBlock.parse("""
            ## Steps ##
            1. Open it
            2) Run **it**
              - nested
            * star
            - [ ] todo
            - [x] done
            > a quote
            > goes on
            ---
            Plain
            text
            """)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 2, text: "Steps"),
            .numbered(depth: 0, number: "1", text: "Open it"),
            .numbered(depth: 0, number: "2", text: "Run **it**"),
            .bullet(depth: 1, text: "nested"),
            .bullet(depth: 0, text: "star"),
            .task(depth: 0, done: false, text: "todo"),
            .task(depth: 0, done: true, text: "done"),
            .quote("a quote\ngoes on"),
            .rule,
            .paragraph("Plain\ntext"),
        ])
        XCTAssertEqual(blocks.map(\.spaced), [false, true, false, false, false, false, false, true, false, false])
    }

    func testBlankLinesSplitParagraphsButNotLists() {
        let blocks = ProseBlock.parse("One\n\nTwo\n\n- a\n\n- b\nAfter")
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph("One"), .paragraph("Two"),
            .bullet(depth: 0, text: "a"), .bullet(depth: 0, text: "b"),
            .paragraph("After"),
        ])
        XCTAssertEqual(blocks.map(\.spaced), [false, true, true, false, true])
    }

    func testThingsThatOnlyLookLikeMarkdown() {
        XCTAssertEqual(ProseBlock.parse("#hashtag").map(\.kind), [.paragraph("#hashtag")])
        XCTAssertEqual(ProseBlock.parse("**bold** start").map(\.kind), [.paragraph("**bold** start")])
        XCTAssertEqual(ProseBlock.parse("2024. A year").map(\.kind), [.numbered(depth: 0, number: "2024", text: "A year")])
        XCTAssertEqual(ProseBlock.parse("-not a bullet").map(\.kind), [.paragraph("-not a bullet")])
        XCTAssertEqual(ProseBlock.parse("").map(\.kind), [])
    }
}
