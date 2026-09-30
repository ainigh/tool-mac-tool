import Foundation

/// The "Unzip latest download to Desktop" tool.
///
///  1. Takes the single most recent file in Downloads. It has to be a .zip, or nothing happens.
///  2. Unzips it into a scratch folder.
///  3. Finds the Desktop folder it belongs to: the one with the same name as the zip (or as the one
///     folder inside it), else the one whose name is contained in the zip's name
///     (Desktop "MyApp" matches "MyApp-main (2).zip"); the longest such name wins.
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
        case noFiles(folder: String)
        case notZip(name: String)
        case stillDownloading(name: String)
        case emptyZip(name: String)
        case noMatch(zip: String)
        case ambiguous(zip: String, folders: [String])
        case unzipFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noFiles(let folder): return "There are no files in \(folder)."
            case .notZip(let name): return "The latest download, “\(name)”, isn't a zip file."
            case .stillDownloading(let name): return "“\(name)” is still downloading. Try again when it's done."
            case .emptyZip(let name): return "“\(name)” is empty."
            case .noMatch(let zip): return "No folder on the Desktop matches “\(zip)”."
            case .ambiguous(let zip, let folders):
                return "“\(zip)” matches more than one Desktop folder: \(folders.joined(separator: ", "))."
            case .unzipFailed(let why): return "Couldn't unzip it: \(why)"
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

    /// The latest download, if it's a zip.
    public func run() throws -> Report {
        try run(zip: latestZip())
    }

    /// One particular zip.
    public func run(zip: URL) throws -> Report {
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

        let entries = try visibleChildren(of: work).filter { $0.lastPathComponent != "__MACOSX" }
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
        try merge(source, into: target, prefix: "", report: &report)
        return report
    }

    /// The most recent visible file in Downloads, if it's a zip. Folders are not looked at.
    public func latestZip() throws -> URL {
        let files = try visibleChildren(of: downloads).filter { !isFolder($0) }
        guard let newest = files.max(by: { date($0) < date($1) }) else {
            throw Failure.noFiles(folder: downloads.lastPathComponent)
        }
        let ext = newest.pathExtension.lowercased()
        if Self.partialExtensions.contains(ext) { throw Failure.stillDownloading(name: newest.lastPathComponent) }
        if ext != "zip" { throw Failure.notZip(name: newest.lastPathComponent) }
        return newest
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

        public var id: URL { zip }

        /// Where it would go, in a few words.
        public var destination: String {
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

    public func plan(for zip: URL) -> Plan {
        let entries = try? list(zip)
        var wrapper: String?
        if let entries {
            let tops = Set(entries.compactMap { $0.split(separator: "/").first.map(String.init) }
                .filter { $0 != "__MACOSX" && $0 != ".DS_Store" })
            if tops.count == 1, let top = tops.first, entries.contains(where: { $0.hasPrefix(top + "/") }) {
                wrapper = top
            }
        }
        let zipName = zip.deletingPathExtension().lastPathComponent
        let folders = (try? desktopFolders()) ?? []
        var plan = Plan(zip: zip, added: date(zip), size: size(zip), target: nil, exact: false, ambiguous: [],
                        wrapper: wrapper,
                        files: entries.map { $0.filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") }.count })
        switch Self.match(names: [zipName] + (wrapper.map { [$0] } ?? []), folders: folders) {
        case .found(let name, let exact)?:
            plan.target = name
            plan.exact = exact
        case .ambiguous(let names)?:
            plan.ambiguous = names
        case nil:
            break
        }
        return plan
    }

    func size(_ url: URL) -> Int64 {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    // MARK: - Matching

    public enum Match: Equatable {
        case found(String, exact: Bool)
        case ambiguous([String])
    }

    /// Which Desktop folder the zip goes into.
    ///
    /// `names` are what the zip is called, in order of preference (its name, then the one folder in it).
    /// Same name (ignoring case and a browser's " (2)") beats a Desktop name contained in the zip's;
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
            guard f.count >= 3, keys.contains(where: { $0.contains(f) }) else { continue }
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

    static func related(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        return !x.isEmpty && !y.isEmpty && (x.contains(y) || y.contains(x))
    }

    func desktopFolders() throws -> [String] {
        try visibleChildren(of: desktop).filter(isFolder).map(\.lastPathComponent)
    }

    // MARK: - Moving

    /// Moves everything in `source` into `target`: folders merge, files replace (old one to the Trash).
    func merge(_ source: URL, into target: URL, prefix: String, report: inout Report) throws {
        for item in try children(of: source) {
            let name = item.lastPathComponent
            if name == ".DS_Store" || name == "__MACOSX" { continue }
            let dest = target.appendingPathComponent(name)
            let rel = prefix + name
            if !exists(dest) {
                try fileManager.moveItem(at: item, to: dest)
                report.added.append(rel)
            } else if isFolder(item) && isFolder(dest) {
                try merge(item, into: dest, prefix: rel + "/", report: &report)
            } else {
                try trash(dest)
                try fileManager.moveItem(at: item, to: dest)
                report.replaced.append(rel)
            }
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
