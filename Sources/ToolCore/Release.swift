import Foundation

/// A version like "0.1.12" (a leading "v" is fine). Compared number by number: 0.1.12 > 0.1.9.
public struct Version: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// The bits of a GitHub release the updater needs (GET /repos/{owner}/{repo}/releases/latest).
public struct Release: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
        public let name: String
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tag: String
    public let notes: String?
    public let page: URL?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case notes = "body"
        case page = "html_url"
        case assets
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }

    public var version: Version? { Version(tag) }

    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }

    /// Whether this release is newer than the running `current` version.
    public func isNewer(than current: String) -> Bool {
        guard let mine = Version(current), let theirs = version else { return false }
        return theirs > mine
    }
}
