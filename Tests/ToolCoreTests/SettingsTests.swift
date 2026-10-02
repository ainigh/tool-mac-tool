import Foundation
import XCTest
@testable import ToolCore

final class SettingsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDefaultsAreSensible() {
        let s = AppSettings()
        XCTAssertEqual(s.prompts.count, SystemPrompt.defaults.count)
        XCTAssertLessThanOrEqual(s.prompts.count, SystemPrompt.limit)
        XCTAssertEqual(s.prompt(nil).id, "glass")
        XCTAssertEqual(Set(s.personas.map(\.voice)), Set(NeuralVoice.all.map(\.id)))
        XCTAssertTrue(s.memoryPrompt.contains(MemoryStore.placeholder))
        XCTAssertTrue(s.memoryOn)
        XCTAssertEqual(s.replyTokens, 2048)
    }

    func testSavesAndLoads() throws {
        let url = root.appendingPathComponent("settings.json")
        var s = AppSettings()
        s.model = "llama3.2"
        s.location = "Lagos, Nigeria"
        s.prompts.append(SystemPrompt(id: "pirate", name: "Pirate", text: "Arr."))
        try s.save(to: url)
        XCTAssertEqual(AppSettings.load(from: url), s)
        XCTAssertNil(AppSettings.load(from: root.appendingPathComponent("missing.json")))
    }

    func testOldFilesKeepTheirValuesAndGetNewDefaults() throws {
        let json = #"{"model": "qwen3", "contextTokens": 999999, "promptID": "gone", "prompts": [], "futureKey": 1}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.model, "qwen3")
        XCTAssertEqual(s.contextTokens, 131_072)
        XCTAssertEqual(s.prompts.map(\.id), ["glass"])
        XCTAssertEqual(s.promptID, "glass")
        XCTAssertTrue(s.autoRemember)
        XCTAssertEqual(s.personas.count, NeuralVoice.all.count)
    }

    func testNoMoreThanNinePrompts() {
        var s = AppSettings()
        s.prompts = (0..<12).map { SystemPrompt(name: "p\($0)", text: "") }
        XCTAssertEqual(s.tidied().prompts.count, 9)
    }

    func testPersonaPrompt() {
        let p = Persona.for("am_fenrir", in: [])
        XCTAssertEqual(p.name, "Fenrir")
        XCTAssertTrue(p.prompt.hasPrefix("You are speaking in the voice called Fenrir. Your persona: "))
        XCTAssertEqual(Persona(voice: "x", name: "X", text: "  ").prompt, "")
        let mine = Persona(voice: "af_heart", name: "Heart", text: "Mine")
        XCTAssertEqual(Persona.for("af_heart", in: [mine]), mine)
    }

    // MARK: - Now

    func testPartsOfTheDay() {
        XCTAssertEqual(NowContext.partOfDay(hour: 2), "late night")
        XCTAssertEqual(NowContext.partOfDay(hour: 6), "early morning")
        XCTAssertEqual(NowContext.partOfDay(hour: 9), "morning")
        XCTAssertEqual(NowContext.partOfDay(hour: 12, minute: 10), "midday")
        XCTAssertEqual(NowContext.partOfDay(hour: 15), "afternoon")
        XCTAssertEqual(NowContext.partOfDay(hour: 19), "evening")
        XCTAssertEqual(NowContext.partOfDay(hour: 23), "night")
    }

    func testOffsets() {
        XCTAssertEqual(NowContext.offset(0), "UTC")
        XCTAssertEqual(NowContext.offset(3600), "UTC+1")
        XCTAssertEqual(NowContext.offset(-4 * 3600), "UTC−4")
        XCTAssertEqual(NowContext.offset(5 * 3600 + 1800), "UTC+5:30")
    }

    func testDescribesTheMoment() {
        // Friday 2 October 2026, 19:42 UTC = 3:42 PM in New York (EDT).
        let date = ISO8601DateFormatter().date(from: "2026-10-02T19:42:00Z")!
        let zone = TimeZone(identifier: "America/New_York")!
        let text = NowContext.describe(date, zone: zone)
        XCTAssertTrue(text.contains("it is Friday afternoon, Friday 2 October 2026, at 3:42 PM (15:42)"), text)
        XCTAssertTrue(text.contains("America/New_York"), text)
        XCTAssertTrue(text.contains("UTC−4"), text)
        XCTAssertTrue(text.contains("a weekday; tomorrow is Saturday 3 October"), text)
        XCTAssertTrue(text.contains("week 40"), text)
        XCTAssertTrue(text.contains("day 275 of 2026"), text)
        XCTAssertTrue(text.contains("near New York"), text)
        let there = NowContext.describe(date, zone: zone, location: "Brooklyn", clock24: true)
        XCTAssertTrue(there.contains("at 15:42 (3:42 PM)"), there)
        XCTAssertTrue(there.contains("The user is in Brooklyn."), there)
    }

    // MARK: - Diagrams

    func testExtractsMermaid() {
        XCTAssertEqual(Diagram.extract("Here:\n```mermaid\ngraph TD\nA-->B\n```\nDone"), "graph TD\nA-->B")
        XCTAssertEqual(Diagram.extract("```\nflowchart LR\nA-->B\n```"), "flowchart LR\nA-->B")
        XCTAssertEqual(Diagram.extract("Sure!\nsequenceDiagram\nA->>B: hi"), "sequenceDiagram\nA->>B: hi")
        XCTAssertEqual(Diagram.extract("<think>graph TD is best</think>```mermaid\nstateDiagram-v2\n[*] --> A\n```"),
                       "stateDiagram-v2\n[*] --> A")
        XCTAssertNil(Diagram.extract("I can't draw that."))
        XCTAssertNil(Diagram.extract("The graphics are nice."))
    }

    func testRequestCarriesTheCurrentDiagram() {
        let r = Diagram.request(" add C ", current: "graph TD\nA-->B")
        XCTAssertTrue(r.contains("```mermaid\ngraph TD\nA-->B\n```"))
        XCTAssertTrue(r.hasSuffix("Request: add C"))
        XCTAssertTrue(Diagram.request("x", current: "").contains("nothing drawn yet"))
    }

    func testSwiftVersions() {
        let old = SwiftToolchain.parse("swift-driver version: 1.90.11.1 Apple Swift version 5.10 (swiftlang-5.10.0.13 clang-1500.3.9.4)\nTarget: arm64-apple-macosx14.0")
        XCTAssertEqual(old, SwiftToolchain(major: 5, minor: 10))
        XCTAssertEqual(old?.isNewEnough, false)
        XCTAssertEqual(SwiftToolchain.parse("Swift version 6.1 (swift-6.1-RELEASE)")?.isNewEnough, true)
        XCTAssertNil(SwiftToolchain.parse("command not found"))
    }
}
