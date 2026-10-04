import Foundation
import XCTest
@testable import ToolCore

final class MemoryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRememberAddsDatedLinesOnce() throws {
        let m = MemoryStore(url: root.appendingPathComponent("MEMORY/MEMORY.md"))
        let day = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
        XCTAssertEqual(try m.remember("Likes   tea", today: day), "- Likes tea _(2026-09-30)_\n")
        XCTAssertNil(try m.remember("likes tea"))
        XCTAssertNil(try m.remember("   "))
        let text = m.read()
        XCTAssertTrue(text.hasPrefix("# Memory"))
        XCTAssertTrue(text.hasSuffix("- Likes tea _(2026-09-30)_\n"))
        XCTAssertEqual(MemoryStore.facts(in: text), ["likes tea"])
    }

    func testExtractHidesTagsAndCollectsFacts() {
        let r = MemoryStore.extract("Noted! [[remember: Sam lives in Lagos]] Anything else?[[REMEMBER:  has a cat ]]")
        XCTAssertEqual(r.facts, ["Sam lives in Lagos", "has a cat"])
        XCTAssertEqual(r.shown, "Noted!  Anything else?")
    }

    func testHideTagsHoldsBackAnUnfinishedTag() {
        XCTAssertEqual(MemoryStore.hideTags("Sure [[remember: half"), "Sure ")
        XCTAssertEqual(MemoryStore.hideTags("Sure [[rem"), "Sure ")
        XCTAssertEqual(MemoryStore.hideTags("Sure [["), "Sure ")
        XCTAssertEqual(MemoryStore.hideTags("Sure ["), "Sure ")
        // Once it's finished, nothing is held back.
        XCTAssertEqual(MemoryStore.hideTags("Sure [", streaming: false), "Sure [")
        XCTAssertEqual(MemoryStore.hideTags("Sure [[remember: half", streaming: false), "Sure [[remember: half")
    }

    func testOnlyRememberTagsAreHidden() {
        XCTAssertEqual(MemoryStore.hideTags("a [[x]] b"), "a [[x]] b")
        XCTAssertEqual(MemoryStore.hideTags("if [[ -f \"$x\" ]]; then"), "if [[ -f \"$x\" ]]; then")
        // Still streaming, but "[[ -f" can't turn into a tag: shown as it comes.
        XCTAssertEqual(MemoryStore.hideTags("if [[ -f x"), "if [[ -f x")
        // An unclosed [[ doesn't swallow the rest of a finished reply.
        let lua = "In Lua, s = [[ a long\nstring and more text"
        XCTAssertEqual(MemoryStore.extract(lua).shown, lua)
    }

    func testTagsInCodeAreLeftAlone() {
        let reply = """
            Here:
            ```bash
            if [[ -z "$x" ]]; then echo "[[remember: not me]]"; fi
            ```
            Also `[[remember: nor me]]`. [[remember: likes bash]]
            """
        let r = MemoryStore.extract(reply)
        XCTAssertEqual(r.facts, ["likes bash"])
        XCTAssertTrue(r.shown.contains(#"if [[ -z "$x" ]]; then echo "[[remember: not me]]"; fi"#), r.shown)
        XCTAssertTrue(r.shown.contains("`[[remember: nor me]]`"), r.shown)
        XCTAssertFalse(r.shown.contains("likes bash"))
        // An open code block while streaming: nothing inside it is held back.
        XCTAssertEqual(MemoryStore.hideTags("```\nx = [["), "```\nx = [[")
    }

    func testReplySplitsIntoTextAndCode() {
        let reply = "Try this:\n\n```bash\nif [[ -f x ]]; then\n  echo hi\nfi\n```\n\nThat's it."
        XCTAssertEqual(ReplyBlock.split(reply), [
            .text("Try this:"),
            .code(language: "bash", body: "if [[ -f x ]]; then\n  echo hi\nfi"),
            .text("That's it."),
        ])
        // Still streaming: the open block is code already.
        XCTAssertEqual(ReplyBlock.split("Here:\n```\nx = 1"), [.text("Here:"), .code(language: "", body: "x = 1")])
        XCTAssertEqual(ReplyBlock.split("Just `inline` text"), [.text("Just `inline` text")])
        XCTAssertEqual(ReplyBlock.split(""), [])
    }

    func testBudgetLeavesRoomForTheSystemAndTheReply() {
        XCTAssertEqual(ChatTurn.budget(contextTokens: 8192, system: String(repeating: "s", count: 6000), replyTokens: 2048),
                       (8192 - 2048) * 3 - 6000)
        XCTAssertEqual(ChatTurn.budget(contextTokens: 2048, system: String(repeating: "s", count: 9000), replyTokens: 2048), 1000)
    }

    func testPromptKeepsTheEnd() {
        let p = MemoryStore.prompt(memory: String(repeating: "a", count: 7000) + "END")
        XCTAssertTrue(p.contains("END"))
        XCTAssertFalse(p.contains(String(repeating: "a", count: 6000)))
        XCTAssertTrue(MemoryStore.prompt(memory: "  ").contains("(empty)"))
    }

    func testGlassFolderFromConfig() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(MemoryStore.glassFolder(home: home, config: .init()).path, "/Users/me/Documents/Glass")
        XCTAssertEqual(MemoryStore.glassFolder(home: home, config: .init(folder: "~/Notes")).path, "/Users/me/Notes")
        XCTAssertEqual(MemoryStore.glassFolder(home: home, config: .init(folder: "/tmp/g")).path, "/tmp/g")
    }

    func testWindowKeepsTheNewestTurnsAndStartsWithTheUser() {
        let turns = [ChatTurn(role: "user", content: "aaaa"), ChatTurn(role: "assistant", content: "bbbb"),
                     ChatTurn(role: "user", content: "cccc"), ChatTurn(role: "assistant", content: "dddd"),
                     ChatTurn(role: "user", content: "eeee")]
        XCTAssertEqual(ChatTurn.window(turns, budget: 100).count, 5)
        XCTAssertEqual(ChatTurn.window(turns, budget: 12).map(\.content), ["cccc", "dddd", "eeee"])
        XCTAssertEqual(ChatTurn.window(turns, budget: 8).map(\.content), ["eeee"])
        XCTAssertEqual(ChatTurn.window([ChatTurn(role: "user", content: String(repeating: "x", count: 50))], budget: 10).count, 1)
    }

    func testParsesOllamaLines() {
        let a = OllamaChunk.parse(#"{"model":"m","message":{"role":"assistant","content":"Hi"},"done":false}"#)
        XCTAssertEqual(a?.message?.content, "Hi")
        XCTAssertEqual(a?.done, false)
        let b = OllamaChunk.parse(#"{"done":true,"prompt_eval_count":120,"eval_count":30}"#)
        XCTAssertEqual(b?.done, true)
        XCTAssertEqual(b?.promptTokens, 120)
        XCTAssertEqual(OllamaChunk.parse(#"{"error":"model not found"}"#)?.error, "model not found")
        XCTAssertNil(OllamaChunk.parse("not json"))
    }

    func testTranscriptIsGlassFormat() throws {
        let t = Transcript(folder: root)
        XCTAssertTrue(t.url.lastPathComponent.hasPrefix("glass-chat-"))
        try t.append(Transcript.block(who: "you", text: " hello \n"))
        try t.append(Transcript.block(who: "llama3.2", text: "hi", note: "stopped"))
        let text = try String(contentsOf: t.url, encoding: .utf8)
        XCTAssertTrue(text.range(of: #"^### \d\d:\d\d:\d\d · you\n\nhello\n\n### \d\d:\d\d:\d\d · llama3.2 \(stopped\)\n\nhi\n\n$"#,
                                 options: .regularExpression) != nil, text)
    }

    func testForgetTagsAreHiddenAndCollected() {
        let r = MemoryStore.extractAll("Done. [[forget: Lives in Lagos]][[remember: Lives in Accra]]")
        XCTAssertEqual(r.shown, "Done.")
        XCTAssertEqual(r.remember, ["Lives in Accra"])
        XCTAssertEqual(r.forget, ["Lives in Lagos"])
        XCTAssertEqual(MemoryStore.hideTags("Ok [[forg"), "Ok ")
        XCTAssertEqual(MemoryStore.hideTags("Ok [[forget: half"), "Ok ")
    }

    func testRememberIgnoresAFinalFullStop() throws {
        let m = MemoryStore(url: root.appendingPathComponent("MEMORY/MEMORY.md"))
        XCTAssertNotNil(try m.remember("Likes tea."))
        XCTAssertNil(try m.remember("likes  tea"))
        XCTAssertEqual(MemoryStore.facts(in: m.read()).count, 1)
    }

    func testForgetRemovesTheLine() throws {
        let m = MemoryStore(url: root.appendingPathComponent("MEMORY/MEMORY.md"))
        try m.remember("Lives in Lagos")
        try m.remember("Has a cat called Mo")
        try m.remember("Likes green tea")
        XCTAssertEqual(try m.forget("lives in  lagos."), ["Lives in Lagos"])
        XCTAssertEqual(MemoryStore.facts(in: m.read()), ["has a cat called mo", "likes green tea"])
        // Part of a single line is enough; nothing that matches, nothing goes.
        XCTAssertEqual(try m.forget("cat called Mo"), ["Has a cat called Mo"])
        XCTAssertEqual(try m.forget("dogs"), [])
        XCTAssertTrue(m.read().hasPrefix("# Memory"))
        XCTAssertEqual(MemoryStore.facts(in: m.read()), ["likes green tea"])
    }

    func testPromptUsesTheInstruction() {
        let p = MemoryStore.prompt(memory: "- Likes tea", instruction: "Rules.\n<m>{{memory}}</m>")
        XCTAssertEqual(p, "Rules.\n<m>- Likes tea</m>")
        XCTAssertEqual(MemoryStore.prompt(memory: "", instruction: "Rules."), "Rules.\n\nYour memory:\n\n(empty)")
        XCTAssertTrue(MemoryStore.prompt(memory: "x").contains("[[forget:"))
    }
}
