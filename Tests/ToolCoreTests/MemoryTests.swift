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
        XCTAssertEqual(MemoryStore.hideTags("Sure ["), "Sure ")
        XCTAssertEqual(MemoryStore.hideTags("a [[x]] b"), "a  b")
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
}
