import Foundation
import XCTest
@testable import ToolCore

final class ModelToolsTests: XCTestCase {
    func testSpecs() {
        let alarm = BuiltinTool(kind: .soundAlarm).spec()
        XCTAssertEqual(alarm.function.name, "sound_alarm")
        XCTAssertEqual(alarm.function.parameters.properties["seconds"]?.type, "integer")
        XCTAssertEqual(alarm.function.parameters.required, ["seconds"])
        let close = BuiltinTool(kind: .closeWindow).spec()
        XCTAssertTrue(close.function.parameters.properties.isEmpty)
        XCTAssertEqual(close.function.parameters.required, [])
        XCTAssertEqual(BuiltinTool(kind: .openURL, description: "  ").spec().function.description,
                       BuiltinTool.Kind.openURL.defaultDescription)
    }

    func testArguments() {
        XCTAssertEqual(BuiltinTool.argument(ToolCall(name: "sound_alarm", arguments: ["seconds": "30"]), .soundAlarm), "30")
        XCTAssertEqual(BuiltinTool.argument(ToolCall(name: "open_url", arguments: ["link": "x.com"]), .openURL), "x.com")
        XCTAssertEqual(BuiltinTool.seconds("30"), 30)
        XCTAssertEqual(BuiltinTool.seconds("12.6"), 13)
        XCTAssertEqual(BuiltinTool.seconds("5000"), 600)
        XCTAssertEqual(BuiltinTool.seconds("soon"), 10)
        XCTAssertEqual(BuiltinTool.webURL("example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(BuiltinTool.webURL(" <https://apple.com> ")?.absoluteString, "https://apple.com")
        XCTAssertNil(BuiltinTool.webURL("file:///etc/passwd"))
        XCTAssertNil(BuiltinTool.webURL("javascript:alert(1)"))
        XCTAssertNil(BuiltinTool.webURL("not a url"))
    }

    func testSettingsHaveEveryBuiltin() throws {
        let s = try JSONDecoder().decode(AppSettings.self,
                                         from: Data(#"{"builtins":[{"kind":"open_url","enabled":false,"description":"mine"}]}"#.utf8))
        XCTAssertEqual(s.builtins.map(\.kind), BuiltinTool.Kind.allCases)
        XCTAssertEqual(s.builtins.first { $0.kind == .openURL }?.enabled, false)
        XCTAssertEqual(s.builtins.first { $0.kind == .openURL }?.description, "mine")
        XCTAssertTrue(s.shareMacInfo)
        // A shortcut can't take a built-in tool's name.
        XCTAssertEqual(ShortcutTool.callable([ShortcutTool(shortcut: "Open URL")], reserved: ["open_url"]).map(\.name), ["open_url_2"])
    }

    func testVoiceCommands() {
        for said in ["Close", "exit.", "Close the window", "OK, bye!", "Go away", "quit please", "Good bye", "close it now"] {
            XCTAssertEqual(VoiceCommand.parse(said), .close, said)
        }
        for said in ["close the door when you leave", "how do I exit vim", "", "Is it close to lunch time?", "thanks"] {
            XCTAssertNil(VoiceCommand.parse(said), said)
        }
    }

    func testMacInfo() {
        XCTAssertEqual(MacInfo.duration(12 * 60 + 5), "12 minutes")
        XCTAssertEqual(MacInfo.duration(3600 + 60), "1 hour, 1 minute")
        XCTAssertEqual(MacInfo.duration(3 * 86400 + 4 * 3600 + 7), "3 days, 4 hours")
        let boot = ISO8601DateFormatter().date(from: "2026-09-29T09:12:00Z")!
        let now = boot.addingTimeInterval(3 * 86400 + 4 * 3600)
        let text = MacInfo.describe(model: "MacBook Pro", chip: "Apple M3 Pro", memoryGB: 18, cores: 12,
                                    system: "macOS 14.6.1", bootedAt: boot, now: now, zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(text, "This Mac: MacBook Pro, Apple M3 Pro, 18 GB of memory, 12 cores, macOS 14.6.1. "
                       + "It has been on for 3 days, 4 hours (since it started up on Tuesday 29 September at 9:12 AM).")
    }
}
