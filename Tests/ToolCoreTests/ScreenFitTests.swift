import Foundation
import XCTest
@testable import ToolCore

final class ScreenFitTests: XCTestCase {
    // A laptop, and a bigger display to its right whose top is higher (AppKit's y goes up).
    let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let display = CGRect(x: 1440, y: -200, width: 2560, height: 1415)

    func testWindowOnScreenStaysPut() {
        XCTAssertNil(ScreenFit.corrected(CGRect(x: 100, y: 100, width: 800, height: 600), screens: [laptop]))
    }

    func testHangingOffASideStaysPut() {
        XCTAssertNil(ScreenFit.corrected(CGRect(x: 1200, y: 100, width: 800, height: 600), screens: [laptop]))
    }

    func testAcrossTwoDisplaysStaysPut() {
        XCTAssertNil(ScreenFit.corrected(CGRect(x: 1000, y: 100, width: 1000, height: 600), screens: [laptop, display]))
    }

    func testTopUnderTheMenuBarIsMovedDown() {
        let f = ScreenFit.corrected(CGRect(x: 100, y: 400, width: 800, height: 600), screens: [laptop])
        XCTAssertEqual(f, CGRect(x: 100, y: 275, width: 800, height: 600))
    }

    func testTallerThanTheScreenIsShrunkToFit() {
        let f = ScreenFit.corrected(CGRect(x: 100, y: -100, width: 800, height: 1200), screens: [laptop])
        XCTAssertEqual(f, CGRect(x: 100, y: 0, width: 800, height: 875))
    }

    func testOnAnUnpluggedDisplayComesBackToTheFallback() {
        let f = ScreenFit.corrected(CGRect(x: 5000, y: 300, width: 800, height: 600), screens: [laptop, display], fallback: 1)
        XCTAssertEqual(f, CGRect(x: 3200, y: 300, width: 800, height: 600))
    }

    func testOnlyACornerOfTheTopShowingIsMoved() {
        // Its top strip shows on the screen for only 40 points.
        let f = ScreenFit.corrected(CGRect(x: -760, y: 100, width: 800, height: 600), screens: [laptop])
        XCTAssertEqual(f, CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    func testNoScreensLeavesItAlone() {
        XCTAssertNil(ScreenFit.corrected(CGRect(x: 0, y: 0, width: 10, height: 10), screens: []))
    }
}
