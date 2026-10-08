import XCTest
@testable import ToolCore

final class NoteComponentsTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    func testANoteReadsBackExactlyAsItWas() {
        let texts = [
            "",
            "Just a note\nwith two lines",
            "Shopping\n::: checklist Groceries\n[x] Milk\n[ ] Bread\n:::\nafter",
            "  ::: table  \n| a | b |\n  :::  ",
            "::: divider\n:::\n::: divider\n:::",
            "Not closed\n::: checklist\n[ ] a",
            "::: \n:::",
            ":::nope\n:::",
            "trailing\n",
        ]
        for t in texts { XCTAssertEqual(NoteDocument(t).text, t, t) }
    }

    func testBlocksAreFoundAndUnclosedOnesStayText() throws {
        let doc = NoteDocument("Title\n::: checklist Groceries\n[x] Milk\n:::\nAfter\n::: callout warning\nCareful\n:::")
        XCTAssertEqual(doc.components.map(\.kind), ["checklist", "callout"])
        XCTAssertEqual(doc.components[0].args, "Groceries")
        XCTAssertEqual(doc.components[0].body, ["[x] Milk"])
        XCTAssertEqual(doc.components[0].type, .checklist)
        XCTAssertEqual(doc.plainText, "Title\nAfter")
        XCTAssertEqual(doc.title, "Title")
        XCTAssertTrue(NoteDocument.hasComponents(doc.text))
        XCTAssertFalse(NoteDocument.hasComponents("::: checklist\n[ ] never closed"))
        XCTAssertFalse(NoteDocument.hasComponents("a ::: b"))
        // An unknown kind is kept as it is.
        let unknown = NoteDocument("::: sparkle shiny\nx\n:::")
        XCTAssertNil(unknown.components.first?.type)
        XCTAssertEqual(unknown.text, "::: sparkle shiny\nx\n:::")
    }

    func testEditingAComponentKeepsTheRest() {
        var doc = NoteDocument("Top\n  ::: checklist A\n[ ] x\n:::\nmiddle\n::: divider\n:::\nend")
        var c = doc.components[0]
        c.body = NoteComponents.checklistBody([.init(done: true, text: "x")])
        doc.setComponent(0, c)
        XCTAssertEqual(doc.text, "Top\n  ::: checklist A\n[x] x\n:::\nmiddle\n::: divider\n:::\nend")
        c.args = "B"
        doc.setComponent(0, c)
        XCTAssertTrue(doc.text.contains("::: checklist B\n"))
        doc.moveComponent(0, by: 1)
        XCTAssertEqual(doc.components.map(\.kind), ["divider", "checklist"])
        doc.duplicateComponent(1)
        XCTAssertEqual(doc.components.count, 3)
        doc.removeComponent(0)
        doc.removeComponent(0)
        doc.removeComponent(0)
        XCTAssertEqual(doc.text, "Top\nmiddle\nend")
        XCTAssertEqual(NoteDocument("::: divider\n:::").title, "Divider")
    }

    func testABoxStartingWithAComponentIsCalledByIt() {
        XCTAssertEqual(Board.Box(text: "::: checklist Groceries\n[ ] a\n:::\nmore").title, "Groceries")
        XCTAssertEqual(Board.Box(text: "\n  Plain title \nbody").title, "Plain title")
    }

    func testEveryTemplateIsOneComponentOfItsKind() {
        for t in NoteComponentType.allCases {
            let doc = NoteDocument(t.template(calendar: calendar))
            XCTAssertEqual(doc.components.map(\.type), [t], t.rawValue)
            XCTAssertEqual(NoteDocument(t.sample(calendar: calendar).text).components.first?.type, t)
            XCTAssertFalse(t.summary.isEmpty)
        }
        XCTAssertEqual(NoteComponentType.matching("todo").first, .checklist)
        XCTAssertEqual(NoteComponentType.matching("tab").first, .table)
        XCTAssertEqual(NoteComponentType.matching("").count, NoteComponentType.allCases.count)
        XCTAssertTrue(NoteComponentType.matching("zzzz").isEmpty)
    }

    func testChecklistsTablesAndFields() {
        let items = NoteComponents.checklist(["[x] Milk", "- [ ] Bread", "plain", "[X] Eggs"])
        XCTAssertEqual(items.map(\.done), [true, false, false, true])
        XCTAssertEqual(items.map(\.text), ["Milk", "Bread", "plain", "Eggs"])
        XCTAssertEqual(NoteComponents.checklistBody(items), ["[x] Milk", "[ ] Bread", "[ ] plain", "[x] Eggs"])

        let rows = NoteComponents.table(["| Item | Cost |", "|---|---|", "| A \\| B | 1,200 |", "| C | $3.50 |", "| D |"])
        XCTAssertEqual(rows, [["Item", "Cost"], ["A | B", "1,200"], ["C", "$3.50"], ["D", ""]])
        XCTAssertEqual(NoteComponents.table(NoteComponents.tableBody(rows)), rows)
        let totals = NoteComponents.totals(rows)
        XCTAssertNil(totals[0])
        XCTAssertEqual(totals[1], 1203.5)
        XCTAssertEqual(NoteComponents.format(1203.5), "1,203.5")

        let body = ["Name: Ada", "Email: ada@x.com", "loose line", "URL: https://a.b/c"]
        XCTAssertEqual(NoteComponents.value("email", in: body), "ada@x.com")
        XCTAssertEqual(NoteComponents.value("URL", in: body), "https://a.b/c")
        XCTAssertEqual(NoteComponents.setting("Phone", "123", in: body).last, "Phone: 123")
        XCTAssertEqual(NoteComponents.setting("Name", "Grace", in: body).first, "Name: Grace")
        XCTAssertEqual(NoteComponents.number("total", in: ["total: 12"], fallback: 1), 12)
        XCTAssertEqual(NoteComponents.number("total", in: ["total: lots"], fallback: 1), 1)
    }

    func testKanbanProsConsAndQuotes() {
        let cols = NoteComponents.kanban(["stray", "# Doing", "- A", "## Done", "- B", "- C"])
        XCTAssertEqual(cols.map(\.title), ["To do", "Doing", "Done"])
        XCTAssertEqual(cols.map(\.cards), [["stray"], ["A"], ["B", "C"]])
        XCTAssertEqual(NoteComponents.kanban(NoteComponents.kanbanBody(cols)), cols)
        let pc = NoteComponents.prosCons(["+ Sun", "- Far", "+Cheap"])
        XCTAssertEqual(pc.pros, ["Sun", "Cheap"])
        XCTAssertEqual(pc.cons, ["Far"])
        let q = NoteComponents.quote(["Keep it simple.", "— Someone"])
        XCTAssertEqual(q.text, "Keep it simple.")
        XCTAssertEqual(q.author, "Someone")
        XCTAssertEqual(NoteComponents.quote(NoteComponents.quoteBody(text: "a\nb", author: "C")).text, "a\nb")
    }

    func testDatesSpansAndStreaks() throws {
        let d = try XCTUnwrap(NoteComponents.date("2026-10-08 09:30", calendar: calendar))
        XCTAssertEqual(NoteComponents.dateString(d, calendar: calendar, time: true), "2026-10-08 09:30")
        XCTAssertNotNil(NoteComponents.date("2026-10-08", calendar: calendar))
        XCTAssertNil(NoteComponents.date("2026-13-08", calendar: calendar))
        XCTAssertNil(NoteComponents.date("soon", calendar: calendar))
        let now = d
        XCTAssertEqual(NoteComponents.span(from: now, to: now.addingTimeInterval(3 * 86_400 + 2 * 3600)).text, "3 days 2 h")
        XCTAssertEqual(NoteComponents.span(from: now, to: now.addingTimeInterval(-5400)).text, "1 h 30 min")
        XCTAssertTrue(NoteComponents.span(from: now, to: now.addingTimeInterval(-5400)).past)
        XCTAssertEqual(NoteComponents.span(from: now, to: now.addingTimeInterval(20)).text, "now")

        let days: Set<String> = ["2026-10-08", "2026-10-07", "2026-10-06", "2026-10-04"]
        XCTAssertEqual(NoteComponents.streak(days, now: now, calendar: calendar), 3)
        // Today not ticked yet: the streak up to yesterday still counts.
        XCTAssertEqual(NoteComponents.streak(days.subtracting(["2026-10-08"]), now: now, calendar: calendar), 2)
        XCTAssertEqual(NoteComponents.habitDays(["2026-10-08", "junk", "2026-10-07 x"]), ["2026-10-08", "2026-10-07"])
    }

    func testTheCalculatorWorksLineByLine() {
        let lines = NoteComponents.calc(["rent = 1,200", "food = 400", "# a comment", "travel = 90 * 2", "total",
                                         "2 ^ 3 ^ 2", "(1 + 2) * -3", "10% * 50", "nope + 1", "1 / 0", "(1 + 2", "", "Monthly savings = 5000 - rent"])
        XCTAssertEqual(lines[0].value, 1200)
        XCTAssertEqual(lines[0].name, "rent")
        XCTAssertNil(lines[2].value)
        XCTAssertEqual(lines[3].value, 180)
        XCTAssertEqual(lines[4].value, 1780)
        XCTAssertEqual(lines[5].value, 512)
        XCTAssertEqual(lines[6].value, -9)
        XCTAssertEqual(lines[7].value, 5)
        XCTAssertNotNil(lines[8].error)
        XCTAssertNotNil(lines[9].error)
        XCTAssertNotNil(lines[10].error)
        XCTAssertNil(lines[11].value)
        XCTAssertEqual(lines[12].value, 3800)
        XCTAssertEqual(lines[12].name, "monthly_savings")
        // Nothing it's given makes it crash.
        for junk in ["((((", "*", "1e999999", ")", "$", "x x", String(repeating: "(", count: 500) + "1"] {
            _ = NoteComponents.calc([junk])
        }
    }
}

final class NoteSlashTests: XCTestCase {
    func testASlashAtAWordsStartIsAQuery() {
        func q(_ text: String) -> String? {
            NoteSlash.query(in: text, caret: (text as NSString).length)?.query
        }
        XCTAssertEqual(q("/"), "")
        XCTAssertEqual(q("Title\n/chec"), "chec")
        XCTAssertEqual(q("buy /pros co"), "pros co")
        XCTAssertNil(q("https://x"))
        XCTAssertNil(q("1/2"))
        XCTAssertNil(q("/ten?"))
        XCTAssertNil(q("/ space"))
        XCTAssertNil(q("/abc\nmore"))
        XCTAssertEqual(NoteSlash.query(in: "a /tab", caret: 6)?.location, 2)
        XCTAssertEqual(NoteSlash.query(in: "a /tab", caret: 6)?.length, 4)
    }

    func testAPickedComponentGoesOnLinesOfItsOwn() {
        let block = "::: divider\n:::"
        XCTAssertEqual(NoteSlash.replacement(block, in: "/div", location: 0, length: 4), block)
        XCTAssertEqual(NoteSlash.replacement(block, in: "Title\nsee /div", location: 10, length: 4), "\n" + block)
        XCTAssertEqual(NoteSlash.replacement(block, in: "/div and more", location: 0, length: 4), block + "\n")
        XCTAssertEqual(NoteSlash.replacement(block, in: "/div\nnext", location: 0, length: 4), block)
    }

    func testAComponentEditedAsTextCanBecomeAnything() {
        var doc = NoteDocument("A\n::: divider\n:::\nB")
        doc.replaceComponent(0, withText: "plain now")
        XCTAssertEqual(doc.text, "A\nplain now\nB")
        XCTAssertTrue(doc.components.isEmpty)
    }
}

final class NoteColumnsTests: XCTestCase {
    func testColumnsSplitAtTheirBreakAndReadBack() {
        XCTAssertEqual(NoteComponents.columns(["Left", "more", "|||", "Right"]), ["Left\nmore", "Right"])
        XCTAssertEqual(NoteComponents.columns(["Only one"]), ["Only one", ""])
        XCTAssertEqual(NoteComponents.columns([]), ["", ""])
        let cols = ["a\nb", "c", "d"]
        XCTAssertEqual(NoteComponents.columns(NoteComponents.columnsBody(cols)), cols)
        // A line that would end a column or the component is kept as text.
        let tricky = NoteComponents.columnsBody(["x\n|||\n:::", "y"])
        let doc = NoteDocument(NoteComponent(kind: "columns", body: tricky).text)
        XCTAssertEqual(doc.components.count, 1)
        XCTAssertEqual(NoteComponents.columns(doc.components[0].body).count, 2)
    }
}
