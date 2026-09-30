import Foundation

/// The "Unzip to Desktop" tool, for one zip from Downloads.
///
///  1. Refuses a zip with paths that would land outside the folder it's unzipped into.
///  2. Unzips it into a scratch folder.
///  3. Finds the Desktop folder it belongs to: the one with the same name as the zip (or as the one
///     folder inside it), else the one whose name appears as whole words in the zip's name
///     (Desktop "MyApp" matches "MyApp-main (2).zip", not "MyAppNext.zip"); the longest such name wins.
///  4. Moves what was in the zip into that folder. Folders merge; a file that's already there is
///     replaced, and the old one goes to the Trash, so nothing is lost.
///
/// When the zip holds just one folder named like the zip or the target (GitHub's "MyApp-main/"),
/// that folder's contents are moved, not the folder itself.
public struct ZipToDesktop {
    public var downloads: URL
    public var desktop: URL
    public var scratch: URL
    /// Unzips `zip` into the (existing, empty) folder `into`.
    public var unzip: (_ zip: URL, _ into: URL) throws -> Void
    /// Moves a replaced item out of the way (the Trash on the Mac).
    public var trash: (URL) throws -> Void
    /// The paths inside a zip, without unzipping it (for the preview).
    public var list: (URL) throws -> [String]
    public var fileManager = FileManager.default

    public init(downloads: URL, desktop: URL, scratch: URL,
                unzip: @escaping (URL, URL) throws -> Void = ZipToDesktop.systemUnzip,
                trash: @escaping (URL) throws -> Void = ZipToDesktop.systemTrash,
                list: @escaping (URL) throws -> [String] = ZipToDesktop.systemList) {
        self.downloads = downloads
        self.desktop = desktop
        self.scratch = scratch
        self.unzip = unzip
        self.trash = trash
        self.list = list
    }

    /// The real folders: ~/Downloads, ~/Desktop, and a scratch folder in Caches.
    public static func forCurrentUser() -> ZipToDesktop {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Caches")
        return ZipToDesktop(downloads: home.appendingPathComponent("Downloads"),
                            desktop: home.appendingPathComponent("Desktop"),
                            scratch: caches.appendingPathComponent("ToolMacTool/unzip"))
    }

    public enum Failure: LocalizedError, Equatable {
        case emptyZip(name: String)
        case unsafePaths(name: String, example: String)
        case noMatch(zip: String)
        case ambiguous(zip: String, folders: [String])
        case unzipFailed(String)
        /// Moving stopped partway: `done` says what had already been added and replaced.
        case interrupted(done: Report, why: String)

        public var errorDescription: String? {
            switch self {
            case .emptyZip(let name): return "“\(name)” is empty."
            case .unsafePaths(let name, let example):
                return "“\(name)” has paths that point outside it (like “\(example)”), so it wasn't unzipped."
            case .noMatch(let zip): return "No folder on the Desktop matches “\(zip)”."
            case .ambiguous(let zip, let folders):
                return "“\(zip)” matches more than one Desktop folder: \(folders.joined(separator: ", "))."
            case .unzipFailed(let why): return "Couldn't unzip it: \(why)"
            case .interrupted(let done, let why):
                var parts = ["\(done.added.count) added", "\(done.replaced.count) replaced"]
                if !done.replaced.isEmpty { parts[1] += " (the old ones are in the Trash)" }
                return "Stopped partway into Desktop/\(done.target.lastPathComponent) after \(parts.joined(separator: ", ")): \(why)"
            }
        }
    }

    public struct Report: Equatable {
        public var zip: URL
        public var target: URL
        public var matchedExactly: Bool
        /// Paths (relative to the target) that are new.
        public var added: [String]
        /// Paths (relative to the target) that replaced something; the old one is in the Trash.
        public var replaced: [String]

        public var summary: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("\(added.count) added") }
            if !replaced.isEmpty { parts.append("\(replaced.count) replaced") }
            return "\(zip.lastPathComponent) → Desktop/\(target.lastPathComponent)"
                + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
        }
    }

    // MARK: - Running it

    public func run(zip: URL) throws -> Report {
        if let entries = try? list(zip), let bad = entries.first(where: Self.isUnsafe) {
            throw Failure.unsafePaths(name: zip.lastPathComponent, example: bad)
        }
        let work = scratch.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        do {
            try unzip(zip, work)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unzipFailed(error.localizedDescription)
        }

        let entries = try children(of: work).filter { !Self.isJunk($0.lastPathComponent) }
        if entries.isEmpty { throw Failure.emptyZip(name: zip.lastPathComponent) }
        let zipName = zip.deletingPathExtension().lastPathComponent
        let wrapper = entries.count == 1 && isFolder(entries[0]) ? entries[0].lastPathComponent : nil

        let folders = try desktopFolders()
        guard let match = Self.match(names: [zipName] + (wrapper.map { [$0] } ?? []), folders: folders) else {
            throw Failure.noMatch(zip: zip.lastPathComponent)
        }
        if case .ambiguous(let names) = match {
            throw Failure.ambiguous(zip: zip.lastPathComponent, folders: names)
        }
        guard case .found(let name, let exact) = match else { throw Failure.noMatch(zip: zip.lastPathComponent) }
        let target = desktop.appendingPathComponent(name)

        // One folder named like the zip or the target: it's a wrapper, move what's inside it.
        var source = work
        if let wrapper, Self.related(wrapper, zipName) || Self.related(wrapper, name) {
            source = work.appendingPathComponent(wrapper)
        }
        var report = Report(zip: zip, target: target, matchedExactly: exact, added: [], replaced: [])
        do {
            try merge(source, into: target, prefix: "", report: &report)
        } catch {
            throw Failure.interrupted(done: report, why: error.localizedDescription)
        }
        return report
    }

    /// A path in a zip that would land outside the folder it's unzipped into.
    static func isUnsafe(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~") || path.split(separator: "/").contains("..")
            || path.split(separator: "\\").contains("..")
    }

    /// What a Mac or a zip program leaves in a zip that isn't part of it.
    static func isJunk(_ name: String) -> Bool {
        name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
    }

    // MARK: - Looking before running

    /// What running a zip would do, worked out from its name and listing (nothing is unzipped).
    public struct Plan: Equatable, Identifiable {
        public var zip: URL
        public var added: Date
        public var size: Int64
        /// The Desktop folder it goes into, if exactly one matches.
        public var target: String?
        public var exact: Bool
        /// The folders that tie, when more than one matches.
        public var ambiguous: [String]
        /// The one folder the zip wraps everything in, if any.
        public var wrapper: String?
        /// How many files it holds (folders not counted); nil if it couldn't be read.
        public var files: Int?
        /// A path in it that points outside it, if any: then it won't be run.
        public var unsafe: String? = nil

        public var id: URL { zip }

        /// Where it would go, in a few words.
        public var destination: String {
            if unsafe != nil { return "has paths pointing outside it: won't unzip" }
            if let target { return "→ Desktop/\(target)" + (exact ? "" : " (name contains it)") }
            if !ambiguous.isEmpty { return "matches \(ambiguous.joined(separator: ", ")): pick by renaming one" }
            return "no matching Desktop folder"
        }
    }

    /// Zips in Downloads that arrived in the last `seconds`, newest first.
    public func recentZips(within seconds: TimeInterval, now: Date = Date()) throws -> [URL] {
        try visibleChildren(of: downloads)
            .filter { $0.pathExtension.lowercased() == "zip" && !isFolder($0) }
            .map { ($0, date($0)) }
            .filter { now.timeIntervalSince($0.1) <= seconds }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Reads the zip's listing and the Desktop, then works out the plan.
    public func plan(for zip: URL) -> Plan {
        plan(for: zip, entries: try? list(zip), folders: (try? desktopFolders()) ?? [])
    }

    /// The plan from a listing (nil: it couldn't be read) and the Desktop's folders, so a caller can
    /// keep listings instead of reading every zip again.
    public func plan(for zip: URL, entries: [String]?, folders: [String]) -> Plan {
        let wrapper = entries.flatMap(Self.wrapper(in:))
        let zipName = zip.deletingPathExtension().lastPathComponent
        let files = entries.map { list in
            list.filter { path in
                !path.hasSuffix("/") && !path.split(separator: "/").contains(where: { Self.isJunk(String($0)) })
            }.count
        }
        var plan = Plan(zip: zip, added: date(zip), size: size(zip), target: nil, exact: false, ambiguous: [],
                        wrapper: wrapper, files: files)
        switch Self.match(names: [zipName] + (wrapper.map { [$0] } ?? []), folders: folders) {
        case .found(let name, let exact)?:
            plan.target = name
            plan.exact = exact
        case .ambiguous(let names)?:
            plan.ambiguous = names
        case nil:
            break
        }
        if let entries, let bad = entries.first(where: Self.isUnsafe) {
            plan.unsafe = bad
        }
        return plan
    }

    /// The one folder everything in a zip sits in, going by its listing (the same rule running it
    /// uses: only a Mac's leftovers like __MACOSX and .DS_Store don't count).
    static func wrapper(in entries: [String]) -> String? {
        let tops = Set(entries.compactMap { $0.split(separator: "/").first.map(String.init) }.filter { !isJunk($0) })
        guard tops.count == 1, let top = tops.first, entries.contains(where: { $0.hasPrefix(top + "/") }) else {
            return nil
        }
        return top
    }

    /// When a file arrived and how big it is: if neither changed, neither did its listing.
    public func stamp(_ url: URL) -> String { "\(date(url).timeIntervalSince1970)-\(size(url))" }

    func size(_ url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Matching

    public enum Match: Equatable {
        case found(String, exact: Bool)
        case ambiguous([String])
    }

    /// Which Desktop folder the zip goes into.
    ///
    /// `names` are what the zip is called, in order of preference (its name, then the one folder in it).
    /// Same name (ignoring case and a browser's " (2)") beats a Desktop name found in the zip's as
    /// whole words ("MyApp" in "MyApp-main", not in "MyAppNext"; "docs v2" in "old docs v2 final");
    /// among those, the longest wins. Names shorter than 3 characters only match exactly.
    public static func match(names: [String], folders: [String]) -> Match? {
        let keys = names.map(normalize).filter { !$0.isEmpty }
        for key in keys {
            let exact = folders.filter { normalize($0) == key }
            if exact.count == 1 { return .found(exact[0], exact: true) }
            if exact.count > 1 { return .ambiguous(exact.sorted()) }
        }
        var best: [String] = []
        var bestLength = 0
        for folder in folders {
            let f = normalize(folder)
            let w = words(f)
            guard f.count >= 3, !w.isEmpty, keys.contains(where: { contains(words($0), w) }) else { continue }
            if f.count > bestLength {
                best = [folder]
                bestLength = f.count
            } else if f.count == bestLength {
                best.append(folder)
            }
        }
        if best.count == 1 { return .found(best[0], exact: false) }
        return best.isEmpty ? nil : .ambiguous(best.sorted())
    }

    /// Lowercased, trimmed, and without the " (2)" / " copy" a browser or Finder adds to duplicates.
    public static func normalize(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = s.range(of: #"\s*\(\d+\)$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"\s+copy(\s+\d+)?$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A name's words: runs of letters and digits.
    static func words(_ name: String) -> [Substring] {
        name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    }

    /// Whether `part` appears in `whole`, word for word, in a row.
    static func contains(_ whole: [Substring], _ part: [Substring]) -> Bool {
        guard !part.isEmpty, part.count <= whole.count else { return false }
        return (0...(whole.count - part.count)).contains { Array(whole[$0..<($0 + part.count)]) == part }
    }

    static func related(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }

    public func desktopFolders() throws -> [String] {
        try visibleChildren(of: desktop).filter(isFolder).map(\.lastPathComponent)
    }

    // MARK: - Moving

    /// Moves everything in `source` into `target`: folders merge, files replace (old one to the Trash).
    func merge(_ source: URL, into target: URL, prefix: String, report: inout Report) throws {
        for item in try children(of: source) {
            let name = item.lastPathComponent
            if Self.isJunk(name) { continue }
            let dest = target.appendingPathComponent(name)
            let rel = prefix + name
            if !exists(dest) {
                try fileManager.moveItem(at: item, to: dest)
                report.added.append(rel)
            } else if isFolder(item) && isFolder(dest) {
                try merge(item, into: dest, prefix: rel + "/", report: &report)
            } else {
                try trash(dest)
                do {
                    try fileManager.moveItem(at: item, to: dest)
                } catch {
                    throw Stranded(path: rel, why: error.localizedDescription)
                }
                report.replaced.append(rel)
            }
        }
    }

    /// The old copy of `path` went to the Trash, but the new one couldn't be moved in.
    struct Stranded: LocalizedError {
        let path: String
        let why: String
        var errorDescription: String? {
            "the old \(path) is in the Trash, but the new one couldn't be moved in (\(why))"
        }
    }

    // MARK: - Files

    func children(of dir: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.keys, options: [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func visibleChildren(of dir: URL) throws -> [URL] {
        try children(of: dir).filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// A real folder: not a file, not an app or other package, not a link.
    func isFolder(_ url: URL) -> Bool {
        #if os(macOS)
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
        #else
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
        #endif
    }

    func exists(_ url: URL) -> Bool {
        // A broken link still takes the name, so ask without following links.
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    /// When a file arrived: the latest of added-to-folder, created and modified.
    func date(_ url: URL) -> Date {
        let v = try? url.resourceValues(forKeys: Set(Self.keys))
        #if os(macOS)
        let added = v?.addedToDirectoryDate
        #else
        let added: Date? = nil
        #endif
        return [added, v?.creationDate, v?.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
    }

    #if os(macOS)
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
                                         .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
    #else
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
    #endif

    // MARK: - The system's unzip and Trash

    /// ditto on the Mac (keeps resource forks, handles every name Finder does), unzip elsewhere.
    public static func systemUnzip(_ zip: URL, into dir: URL) throws {
        let p = Process()
        #if os(macOS)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        #else
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-q", zip.path, "-d", dir.path]
        #endif
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure.unzipFailed(msg.isEmpty ? "exit code \(p.terminationStatus)" : msg)
        }
    }

    /// `zipinfo -1`: one path per line.
    public static func systemList(_ zip: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", zip.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw Failure.unzipFailed("can't read \(zip.lastPathComponent)") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    public static func systemTrash(_ url: URL) throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }
}
