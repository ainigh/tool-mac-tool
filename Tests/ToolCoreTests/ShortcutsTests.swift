import Foundation
import XCTest
@testable import ToolCore

final class ShortcutsTests: XCTestCase {
    func testFunctionNames() {
        XCTAssertEqual(ShortcutTool.functionName("Get Weather (UK)"), "get_weather_uk")
        XCTAssertEqual(ShortcutTool.functionName("  Add to   Notes! "), "add_to_notes")
        XCTAssertEqual(ShortcutTool.functionName("1Password lookup"), "run_1password_lookup")
        XCTAssertEqual(ShortcutTool.functionName("☕️"), "shortcut")
        XCTAssertEqual(ShortcutTool.functionName("Café Hours"), "caf_hours")
    }

    func testCallableSkipsDisabledAndKeepsNamesUnique() {
        let tools = [ShortcutTool(shortcut: "Weather"), ShortcutTool(shortcut: "weather"),
                     ShortcutTool(shortcut: "Off", enabled: false), ShortcutTool(shortcut: "")]
        XCTAssertEqual(ShortcutTool.callable(tools).map(\.name), ["weather", "weather_2"])
    }

    func testSpecIsWhatOllamaTakes() throws {
        let t = ShortcutTool(shortcut: "Add Reminder", description: "Use it when the user wants a reminder.",
                             input: "The reminder's text", returnsText: false)
        let data = try JSONEncoder().encode(t.spec(name: "add_reminder"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "function")
        let f = try XCTUnwrap(json["function"] as? [String: Any])
        XCTAssertEqual(f["name"] as? String, "add_reminder")
        XCTAssertEqual(f["description"] as? String,
                       "Use it when the user wants a reminder. It returns nothing: you're only told that it ran.")
        let p = try XCTUnwrap(f["parameters"] as? [String: Any])
        XCTAssertEqual(p["required"] as? [String], ["input"])
        let input = try XCTUnwrap((p["properties"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertEqual(input["description"] as? String, "The reminder's text")
        XCTAssertTrue(ShortcutTool(shortcut: "X").spec(name: "x").function.description.contains("\"X\" shortcut"))
    }

    func testParsesToolCalls() throws {
        let line = #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"weather","arguments":{"input":"Lagos","days":3}}}]},"done":false}"#
        let call = try XCTUnwrap(OllamaChunk.parse(line)?.message?.toolCalls?.first)
        XCTAssertEqual(call.function.name, "weather")
        XCTAssertEqual(call.function.arguments, ["input": "Lagos", "days": "3"])
        XCTAssertEqual(ShortcutTool.input(from: call), "Lagos")
        // Arguments as a JSON string, and a lone argument under another name.
        let other = #"{"message":{"content":"","tool_calls":[{"function":{"name":"x","arguments":"{\"city\":\"Accra\"}"}}]},"done":false}"#
        let c2 = try XCTUnwrap(OllamaChunk.parse(other)?.message?.toolCalls?.first)
        XCTAssertEqual(ShortcutTool.input(from: c2), "Accra")
        // A plain line still parses, without tool calls.
        XCTAssertNil(OllamaChunk.parse(#"{"message":{"content":"Hi"},"done":false}"#)?.message?.toolCalls)
    }

    func testTurnsCarryToolCallsAndResults() throws {
        let turns = [ChatTurn(role: "assistant", content: "", toolCalls: [ToolCall(name: "weather", arguments: ["input": "Lagos"])]),
                     ChatTurn(role: "tool", content: "31°C", toolName: "weather"),
                     ChatTurn(role: "user", content: "hi")]
        let json = String(decoding: try JSONEncoder().encode(turns), as: UTF8.self)
        XCTAssertTrue(json.contains(#""tool_calls":[{"function":{"#), json)
        XCTAssertTrue(json.contains(#""tool_name":"weather""#), json)
        XCTAssertFalse(json.contains(#""role":"user","tool"#), json)
        // A window never opens with a tool's result.
        XCTAssertEqual(ChatTurn.window(Array(turns.dropFirst()), budget: 100).map(\.role), ["user"])
    }

    func testSettingsKeepShortcuts() throws {
        var s = AppSettings()
        s.shortcuts = [ShortcutTool(shortcut: "Weather", description: "for weather")]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.shortcuts, s.shortcuts)
        XCTAssertTrue(back.toolsOn)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"model":"m"}"#.utf8))
        XCTAssertEqual(old.shortcuts, [])
    }
}
