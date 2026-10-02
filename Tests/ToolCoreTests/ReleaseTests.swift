import Foundation
import XCTest
@testable import ToolCore

final class ReleaseTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(Version("0.1.9")!, Version("0.1.12")!)
        XCTAssertLessThan(Version("v0.1")!, Version("0.1.1")!)
        XCTAssertEqual(Version("v1.2.0")!, Version("1.2")!)
        XCTAssertNil(Version("dev"))
        XCTAssertNil(Version("1.2-beta"))
    }

    func testDecodesGitHubsAnswer() throws {
        let json = """
        {"tag_name": "v0.1.14", "target_commitish": "abc123", "body": "Faster", "html_url": "https://github.com/o/r/releases/tag/v0.1.14",
         "assets": [{"name": "ToolMacTool.zip", "browser_download_url": "https://github.com/o/r/releases/download/v0.1.14/ToolMacTool.zip", "size": 1}]}
        """
        let r = try Release.decode(Data(json.utf8))
        XCTAssertEqual(r.version, Version("0.1.14"))
        XCTAssertEqual(r.asset(named: "ToolMacTool.zip")?.browserDownloadURL.lastPathComponent, "ToolMacTool.zip")
        XCTAssertEqual(r.target, "abc123")
    }

    func testDecodesACommit() throws {
        let json = """
        {"sha": "0123456789abcdef", "commit": {"message": "Add a tool\\n\\nLonger text", "author": {}}, "files": []}
        """
        let c = try Commit.decode(Data(json.utf8))
        XCTAssertEqual(c.short, "0123456")
        XCTAssertEqual(c.title, "Add a tool")
    }

    func testFindsTheNewestCommandLineTools() {
        let list = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: Command Line Tools for Xcode-15.3
        \tTitle: Command Line Tools for Xcode, Version: 15.3, Size: 707415KiB, Recommended: YES,
        * Label: Command Line Tools for Xcode-16.2
        \tTitle: Command Line Tools for Xcode, Version: 16.2, Size: 856000KiB, Recommended: YES,
        * Label: macOS Sonoma 14.7-23H124
        """
        let found = SoftwareUpdate.commandLineTools(in: list)
        XCTAssertEqual(found?.label, "Command Line Tools for Xcode-16.2")
        XCTAssertEqual(found?.version, Version("16.2"))
        XCTAssertNil(SoftwareUpdate.commandLineTools(in: "No new software available."))
    }
}
