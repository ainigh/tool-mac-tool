import Foundation
import XCTest
@testable import ToolCore

final class MatchTests: XCTestCase {
    func testExactNameWins() {
        XCTAssertEqual(ZipToDesktop.match(names: ["MyApp"], folders: ["My", "MyApp", "MyApp Old"]),
                       .found("MyApp", exact: true))
    }

    func testExactIgnoresCaseAndDuplicateSuffix() {
        XCTAssertEqual(ZipToDesktop.match(names: ["myapp (2)"], folders: ["MyApp"]), .found("MyApp", exact: true))
        XCTAssertEqual(ZipToDesktop.match(names: ["Report copy 2"], folders: ["report"]), .found("report", exact: true))
    }

    func testDesktopNameContainedInZipName() {
        XCTAssertEqual(ZipToDesktop.match(names: ["MyApp-main"], folders: ["MyApp", "Other"]),
                       .found("MyApp", exact: false))
    }

    func testLongestContainedNameWins() {
        XCTAssertEqual(ZipToDesktop.match(names: ["client-site-assets-v2"], folders: ["client", "client-site", "site"]),
                       .found("client-site", exact: false))
    }

    func testZipNameInsideDesktopNameDoesNotMatch() {
        XCTAssertNil(ZipToDesktop.match(names: ["App"], folders: ["MyApp"]))
    }

    func testShortNamesOnlyMatchExactly() {
        XCTAssertNil(ZipToDesktop.match(names: ["photos-ab"], folders: ["ab"]))
        XCTAssertEqual(ZipToDesktop.match(names: ["ab"], folders: ["ab"]), .found("ab", exact: true))
    }

    func testContainedNamesMatchWholeWordsOnly() {
        XCTAssertNil(ZipToDesktop.match(names: ["newsletter-q3"], folders: ["new"]))
        XCTAssertNil(ZipToDesktop.match(names: ["chart-data"], folders: ["art"]))
        XCTAssertNil(ZipToDesktop.match(names: ["whatsapp-backup"], folders: ["app"]))
        XCTAssertNil(ZipToDesktop.match(names: ["MyAppNext"], folders: ["MyApp"]))
        XCTAssertEqual(ZipToDesktop.match(names: ["old docs v2 final"], folders: ["docs v2"]),
                       .found("docs v2", exact: false))
        XCTAssertEqual(ZipToDesktop.match(names: ["MyApp_main.v2"], folders: ["MyApp"]), .found("MyApp", exact: false))
    }

    func testTieIsAmbiguous() {
        XCTAssertEqual(ZipToDesktop.match(names: ["alpha-gamma"], folders: ["alpha", "gamma"]),
                       .ambiguous(["alpha", "gamma"]))
    }

    func testFolderInsideZipIsASecondChance() {
        XCTAssertEqual(ZipToDesktop.match(names: ["download", "Website"], folders: ["Website"]),
                       .found("Website", exact: true))
    }
}

final class RunTests: XCTestCase {
    var root: URL!
    var downloads: URL { root.appendingPathComponent("Downloads") }
    var desktop: URL { root.appendingPathComponent("Desktop") }
    var trashed: URL { root.appendingPathComponent("Trash") }
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ztd-\(UUID().uuidString)")
        for d in [downloads, desktop, trashed] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// A tool whose zips are fakes: what's "in" Downloads/X.zip is the folder zips/X.zip.contents, so the
    /// tests don't need a zip program. Its Trash is a folder we can look in.
    func tool() -> ZipToDesktop {
        let trashed = self.trashed, zips = root.appendingPathComponent("zips")
        return ZipToDesktop(
            downloads: downloads, desktop: desktop, scratch: root.appendingPathComponent("scratch"),
            unzip: { zip, into in
                let src = zips.appendingPathComponent(zip.lastPathComponent + ".contents")
                for item in try FileManager.default.contentsOfDirectory(atPath: src.path) {
                    try FileManager.default.copyItem(at: src.appendingPathComponent(item),
                                                     to: into.appendingPathComponent(item))
                }
            },
            trash: { url in
                try FileManager.default.moveItem(
                    at: url, to: trashed.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            })
    }

    /// A fake zip in Downloads with these files ("a/b.txt": "text"), `age` seconds old (negative: newer).
    @discardableResult
    func download(_ name: String, _ files: [String: String] = [:], age: TimeInterval) throws -> URL {
        let zip = downloads.appendingPathComponent(name)
        try Data("zip".utf8).write(to: zip)
        let contents = root.appendingPathComponent("zips").appendingPathComponent(name + ".contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        for (path, text) in files { try write(contents.appendingPathComponent(path), text) }
        try setAge(zip, age)
        return zip
    }

    func setAge(_ url: URL, _ age: TimeInterval) throws {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: desktop.appendingPathComponent(path))).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Runs the newest zip in Downloads.
    func runTool(_ t: ZipToDesktop? = nil) throws -> ZipToDesktop.Report {
        let t = t ?? tool()
        let newest = try t.recentZips(within: .infinity, now: .distantFuture).first
        return try t.run(zip: XCTUnwrap(newest))
    }

    func testMergesIntoContainedMatchAndTrashesReplacedFiles() throws {
        try write(desktop.appendingPathComponent("MyApp/keep.txt"), "mine")
        try write(desktop.appendingPathComponent("MyApp/src/main.txt"), "old")
        try write(desktop.appendingPathComponent("MyApp/src/local.txt"), "mine")
        try download("Old.zip", ["x.txt": "x"], age: 500)
        try download("MyApp-main (1).zip", ["src/main.txt": "new", "src/extra.txt": "new", "README": "new"], age: 10)

        let r = try runTool()
        XCTAssertEqual(r.target.lastPathComponent, "MyApp")
        XCTAssertFalse(r.matchedExactly)
        XCTAssertEqual(read("MyApp/keep.txt"), "mine")
        XCTAssertEqual(read("MyApp/src/local.txt"), "mine")
        XCTAssertEqual(read("MyApp/src/main.txt"), "new")
        XCTAssertEqual(read("MyApp/src/extra.txt"), "new")
        XCTAssertEqual(read("MyApp/README"), "new")
        XCTAssertEqual(r.added.sorted(), ["README", "src/extra.txt"])
        XCTAssertEqual(r.replaced, ["src/main.txt"])
        let inTrash = try fm.contentsOfDirectory(atPath: trashed.path)
        XCTAssertEqual(inTrash.count, 1)
        XCTAssertTrue(inTrash[0].hasSuffix("-main.txt"))
        // The scratch folder is cleaned up; the zip stays in Downloads.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("scratch").path), [])
        XCTAssertTrue(fm.fileExists(atPath: downloads.appendingPathComponent("MyApp-main (1).zip").path))
    }

    func testWrapperFolderIsUnwrapped() throws {
        try fm.createDirectory(at: desktop.appendingPathComponent("MyApp"), withIntermediateDirectories: true)
        try download("MyApp-main.zip", ["MyApp-main/index.html": "new", "__MACOSX/._index.html": "junk"], age: 0)
        let r = try runTool()
        XCTAssertEqual(read("MyApp/index.html"), "new")
        XCTAssertFalse(fm.fileExists(atPath: desktop.appendingPathComponent("MyApp/MyApp-main").path))
        XCTAssertFalse(fm.fileExists(atPath: desktop.appendingPathComponent("MyApp/__MACOSX").path))
        XCTAssertEqual(r.added, ["index.html"])
    }

    func testUnrelatedSingleFolderIsKept() throws {
        try fm.createDirectory(at: desktop.appendingPathComponent("Project"), withIntermediateDirectories: true)
        try download("Project.zip", ["src/app.txt": "new"], age: 0)
        _ = try runTool()
        XCTAssertEqual(read("Project/src/app.txt"), "new")
    }

    func testMatchByTheFolderInsideTheZip() throws {
        try fm.createDirectory(at: desktop.appendingPathComponent("Website"), withIntermediateDirectories: true)
        try download("download.zip", ["Website/index.html": "new"], age: 0)
        let r = try runTool()
        XCTAssertTrue(r.matchedExactly)
        XCTAssertEqual(read("Website/index.html"), "new")
    }

    func testHiddenFilesBesideAFolderMeanItIsNotAWrapper() throws {
        // Both ways of looking agree: .gitignore counts, so "src" isn't the one folder in it.
        try fm.createDirectory(at: desktop.appendingPathComponent("src"), withIntermediateDirectories: true)
        try download("download.zip", [".gitignore": "x", "src/a.txt": "new"], age: 0)
        XCTAssertThrowsError(try runTool()) { e in
            XCTAssertEqual(e as? ZipToDesktop.Failure, .noMatch(zip: "download.zip"))
        }
        XCTAssertNil(ZipToDesktop.wrapper(in: [".gitignore", "src/", "src/a.txt"]))
        XCTAssertEqual(ZipToDesktop.wrapper(in: [".DS_Store", "__MACOSX/._src", "src/", "src/a.txt"]), "src")
    }

    func testDotfilesAreMovedToo() throws {
        try fm.createDirectory(at: desktop.appendingPathComponent("MyApp"), withIntermediateDirectories: true)
        try download("MyApp.zip", [".env": "secret", "index.html": "new", "._index.html": "junk"], age: 0)
        let r = try runTool()
        XCTAssertEqual(read("MyApp/.env"), "secret")
        XCTAssertEqual(r.added.sorted(), [".env", "index.html"])
    }

    func testStoppingPartwayReportsWhatWasDone() throws {
        try write(desktop.appendingPathComponent("MyApp/a.txt"), "old")
        try write(desktop.appendingPathComponent("MyApp/b.txt"), "old")
        try download("MyApp.zip", ["a.txt": "new", "b.txt": "new"], age: 0)
        var t = tool()
        var calls = 0
        let trashed = self.trashed
        t.trash = { url in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trashed.appendingPathComponent(url.lastPathComponent))
        }
        XCTAssertThrowsError(try runTool(t)) { e in
            guard case .interrupted(let done, _)? = e as? ZipToDesktop.Failure else { return XCTFail("\(e)") }
            XCTAssertEqual(done.replaced, ["a.txt"])
            XCTAssertTrue(e.localizedDescription.hasPrefix("Stopped partway into Desktop/MyApp after 0 added, 1 replaced"),
                          e.localizedDescription)
        }
        XCTAssertEqual(read("MyApp/a.txt"), "new")
        XCTAssertEqual(read("MyApp/b.txt"), "old")
    }

    func testRefusesPathsThatPointOutside() throws {
        try fm.createDirectory(at: desktop.appendingPathComponent("MyApp"), withIntermediateDirectories: true)
        try download("MyApp.zip", ["a.txt": "new"], age: 0)
        var t = tool()
        t.list = { _ in ["a.txt", "../../.zshrc"] }
        t.unzip = { _, _ in XCTFail("shouldn't unzip") }
        XCTAssertThrowsError(try runTool(t)) { e in
            XCTAssertEqual(e as? ZipToDesktop.Failure, .unsafePaths(name: "MyApp.zip", example: "../../.zshrc"))
        }
        XCTAssertTrue(ZipToDesktop.isUnsafe("/etc/passwd"))
        XCTAssertFalse(ZipToDesktop.isUnsafe("a..b/c.txt"))
    }

    func testNoMatchTouchesNothing() throws {
        try write(desktop.appendingPathComponent("Other/a.txt"), "mine")
        try write(desktop.appendingPathComponent("MyApp.txt"), "a file, not a folder")
        try download("MyApp.zip", ["a.txt": "new"], age: 0)
        XCTAssertThrowsError(try runTool()) { e in
            XCTAssertEqual(e as? ZipToDesktop.Failure, .noMatch(zip: "MyApp.zip"))
        }
        XCTAssertEqual(read("Other/a.txt"), "mine")
    }

    func testFileReplacesFolderAndFolderReplacesFile() throws {
        try write(desktop.appendingPathComponent("Site/thing/inner.txt"), "was a folder")
        try write(desktop.appendingPathComponent("Site/other"), "was a file")
        try download("Site.zip", ["thing": "now a file", "other/x.txt": "now a folder"], age: 0)
        let r = try runTool()
        XCTAssertEqual(read("Site/thing"), "now a file")
        XCTAssertEqual(read("Site/other/x.txt"), "now a folder")
        XCTAssertEqual(r.replaced.sorted(), ["other", "thing"])
    }

    func testSystemUnzipWithARealZip() throws {
        let zipTool = ["/usr/bin/zip", "/bin/zip"].first { fm.isExecutableFile(atPath: $0) }
        let unzipTool = ["/usr/bin/ditto", "/usr/bin/unzip"].first { fm.isExecutableFile(atPath: $0) }
        guard let zipTool, unzipTool != nil else { throw XCTSkip("no zip/unzip here") }
        let src = root.appendingPathComponent("src")
        try write(src.appendingPathComponent("Notes-v3/today.md"), "hello")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: zipTool)
        p.currentDirectoryURL = src
        p.arguments = ["-qr", downloads.appendingPathComponent("Notes-v3.zip").path, "Notes-v3"]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try fm.createDirectory(at: desktop.appendingPathComponent("Notes"), withIntermediateDirectories: true)

        var t = ZipToDesktop(downloads: downloads, desktop: desktop, scratch: root.appendingPathComponent("scratch"))
        t.trash = { _ in XCTFail("nothing to replace") }
        let r = try runTool(t)
        XCTAssertEqual(read("Notes/today.md"), "hello")
        XCTAssertEqual(r.summary, "Notes-v3.zip → Desktop/Notes (1 added)")
    }
}

final class PlanTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        for d in ["Downloads", "Desktop/MyApp", "Desktop/Website"] {
            try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func tool(listing: [String: [String]]) -> ZipToDesktop {
        ZipToDesktop(downloads: root.appendingPathComponent("Downloads"), desktop: root.appendingPathComponent("Desktop"),
                     scratch: root.appendingPathComponent("scratch"),
                     unzip: { _, _ in }, trash: { _ in },
                     list: { zip in
                         guard let l = listing[zip.lastPathComponent] else { throw ZipToDesktop.Failure.unzipFailed("bad") }
                         return l
                     })
    }

    func file(_ name: String, minutesAgo: Double) throws -> URL {
        let url = root.appendingPathComponent("Downloads").appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
        return url
    }

    func testRecentZipsAreNewestFirstAndOnlyZips() throws {
        let t = tool(listing: [:])
        // On the Mac a file's date includes when it was added (now), so the files are dated in the
        // future and we look from an hour ahead: "a.zip" arrived 5 minutes before that moment.
        let now = Date().addingTimeInterval(3600)
        _ = try file("old.zip", minutesAgo: -30)
        _ = try file("a.zip", minutesAgo: -55)
        _ = try file("b.zip", minutesAgo: -58)
        _ = try file("photo.jpg", minutesAgo: -59)
        XCTAssertEqual(try t.recentZips(within: 10 * 60, now: now).map(\.lastPathComponent), ["b.zip", "a.zip"])
    }

    func testPlanFindsTheFolderAndTheWrapper() throws {
        let t = tool(listing: ["MyApp-main.zip": ["MyApp-main/", "MyApp-main/a.txt", "MyApp-main/src/b.txt", "__MACOSX/._a.txt"]])
        let p = t.plan(for: try file("MyApp-main.zip", minutesAgo: 1))
        XCTAssertEqual(p.target, "MyApp")
        XCTAssertFalse(p.exact)
        XCTAssertEqual(p.wrapper, "MyApp-main")
        XCTAssertEqual(p.files, 2)
        XCTAssertEqual(p.destination, "→ Desktop/MyApp (name contains it)")
    }

    func testPlanUsesTheInnerFolderName() throws {
        let t = tool(listing: ["download.zip": ["Website/index.html"]])
        let p = t.plan(for: try file("download.zip", minutesAgo: 1))
        XCTAssertEqual(p.target, "Website")
        XCTAssertTrue(p.exact)
    }

    func testPlanFromAKeptListing() throws {
        let zip = try file("download.zip", minutesAgo: 1)
        let t = tool(listing: [:])     // reading it would fail: the listing passed in is used
        let p = t.plan(for: zip, entries: ["Website/", "Website/a.html", ".DS_Store"], folders: ["Website"])
        XCTAssertEqual(p.target, "Website")
        XCTAssertEqual(p.files, 1)
        XCTAssertEqual(t.stamp(zip), t.stamp(zip))
    }

    func testPlanWithUnsafePaths() throws {
        let t = tool(listing: ["MyApp.zip": ["a.txt", "../evil"]])
        let p = t.plan(for: try file("MyApp.zip", minutesAgo: 1))
        XCTAssertEqual(p.unsafe, "../evil")
        XCTAssertEqual(p.destination, "has paths pointing outside it: won't unzip")
    }

    func testPlanWithoutAMatchOrAListing() throws {
        let p = tool(listing: [:]).plan(for: try file("Other.zip", minutesAgo: 1))
        XCTAssertNil(p.target)
        XCTAssertNil(p.files)
        XCTAssertEqual(p.destination, "no matching Desktop folder")
    }
}
