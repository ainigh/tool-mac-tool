import Foundation

// A web address pasted into a note is shown with its page's icon, title and site under the text;
// a YouTube video's plays right there. This is the reading of a page's head (its title, Open
// Graph tags and icons) and of YouTube addresses; the app fetches and draws them.

/// What a page says about itself.
public struct LinkMeta: Codable, Equatable, Sendable {
    public var title: String?
    public var siteName: String?
    public var summary: String?
    /// The page's picture (og:image), absolute.
    public var image: URL?
    /// Its icons, best first, absolute; /favicon.ico last.
    public var icons: [URL]

    public init(title: String? = nil, siteName: String? = nil, summary: String? = nil, image: URL? = nil, icons: [URL] = []) {
        self.title = title
        self.siteName = siteName
        self.summary = summary
        self.image = image
        self.icons = icons
    }

    /// Reads a page's HTML (its head is enough). `base` is the page's address, for relative links.
    public static func parse(html: String, base: URL) -> LinkMeta {
        // Only the head matters, and a huge body is slow to search.
        let head: String = {
            if let end = html.range(of: "</head>", options: .caseInsensitive) { return String(html[..<end.lowerBound]) }
            return String(html.prefix(300_000))
        }()
        var meta: [String: String] = [:]
        for tag in tags("meta", in: head) {
            let a = attributes(tag)
            guard let content = a["content"].map(decode)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { continue }
            for key in [a["property"], a["name"], a["itemprop"]].compactMap({ $0?.lowercased() }) where meta[key] == nil {
                meta[key] = content
            }
        }
        var icons: [(url: URL, rank: Int, size: Int)] = []
        for tag in tags("link", in: head) {
            let a = attributes(tag)
            guard let rel = a["rel"]?.lowercased(), let href = a["href"].map(decode),
                  let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { continue }
            let words = Set(rel.split(separator: " ").map(String.init))
            let rank: Int
            if words.contains("apple-touch-icon") || words.contains("apple-touch-icon-precomposed") { rank = 1 }
            else if words.contains("icon") { rank = url.pathExtension.lowercased() == "svg" ? 3 : 0 }
            else if words.contains("mask-icon") { rank = 4 }
            else { continue }
            let size = (a["sizes"] ?? "").split(separator: "x").first.flatMap { Int($0) } ?? 0
            icons.append((url, rank, size))
        }
        // PNG/ICO icons first (the largest up to 64 pt), then touch icons, then SVG (which an
        // image view can't always draw).
        icons.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let a = $0.size == 0 ? 32 : $0.size, b = $1.size == 0 ? 32 : $1.size
            return abs(a - 64) < abs(b - 64)
        }
        var urls = icons.map(\.url)
        if let scheme = base.scheme, let host = base.host,
           let fallback = URL(string: "\(scheme)://\(host)\(base.port.map { ":\($0)" } ?? "")/favicon.ico"), !urls.contains(fallback) {
            urls.append(fallback)
        }
        let title = meta["og:title"] ?? meta["twitter:title"] ?? titleTag(head)
        return LinkMeta(title: title.map(tidy).flatMap { $0.isEmpty ? nil : $0 },
                        siteName: meta["og:site_name"].map(tidy),
                        summary: (meta["og:description"] ?? meta["description"] ?? meta["twitter:description"]).map(tidy),
                        image: (meta["og:image"] ?? meta["twitter:image"]).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                        icons: urls)
    }

    /// The text of the <title> tag.
    static func titleTag(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let end = html.range(of: "</title>", options: .caseInsensitive, range: close.upperBound..<html.endIndex) else { return nil }
        return decode(String(html[close.upperBound..<end.lowerBound]))
    }

    /// Every `<name …>` tag, as the text between its brackets.
    static func tags(_ name: String, in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(name)\\b([^>]*)>", options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// A tag's attributes, names lowercased: `a="1" b='2' c=3`.
    static func attributes(_ tag: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))") else { return [:] }
        let ns = tag as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                value = ns.substring(with: m.range(at: g))
                break
            }
            if out[name] == nil { out[name] = value }
        }
        return out
    }

    /// One line, spaces squeezed.
    static func tidy(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// HTML's character references made into characters.
    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                       "rdquo": "”", "ldquo": "“", "middot": "·", "copy": "©", "reg": "®", "trade": "™"]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if body.hasPrefix("#") {
                    replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[body.lowercased()]
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

/// YouTube addresses: which video, and how to embed it.
public enum YouTube {
    /// The video's 11-character id, for watch, youtu.be, shorts, embed and live addresses.
    public static func videoID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path.split(separator: "/").map(String.init)
        var id: String?
        if bare == "youtu.be" {
            id = path.first
        } else if ["youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com"].contains(bare) {
            if path.first == "watch" || path.isEmpty {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if ["shorts", "embed", "live", "v"].contains(path[0]), path.count > 1 {
                id = path[1]
            }
        }
        guard let id, isID(id) else { return nil }
        return id
    }

    static func isID(_ s: String) -> Bool {
        s.count == 11 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Where the address starts playing (`t=90`, `t=1m30s`, `start=90`), in seconds.
    public static func start(_ url: URL) -> Int? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let t = items.first(where: { $0.name == "t" || $0.name == "start" })?.value, !t.isEmpty else { return nil }
        if let n = Int(t.hasSuffix("s") && Int(t.dropLast()) != nil ? String(t.dropLast()) : t) { return n > 0 ? n : nil }
        var total = 0, number = ""
        for ch in t {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Int(number) else { return nil }
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
        }
        return total > 0 ? total : nil
    }

    /// The player's address for the video.
    public static func embedURL(_ id: String, start: Int? = nil) -> URL {
        var c = URLComponents(string: "https://www.youtube.com/embed/\(id)")!
        var items = [URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "rel", value: "0")]
        if let start { items.append(URLQueryItem(name: "start", value: "\(start)")) }
        c.queryItems = items
        return c.url!
    }

    /// The page holding the player: an iframe that fills it. Loaded with a base address that
    /// names the app, which YouTube asks of apps that embed it (or it won't play).
    public static func playerPage(_ id: String, start: Int? = nil) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;height:100%;background:#000;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head><body>
        <iframe src="\(embedURL(id, start: start).absoluteString)" referrerpolicy="strict-origin-when-cross-origin"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body></html>
        """
    }

    /// Asks YouTube for the video's title and channel (JSON: title, author_name, thumbnail_url).
    public static func oEmbedURL(_ url: URL) -> URL? {
        var c = URLComponents(string: "https://www.youtube.com/oembed")
        c?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        return c?.url
    }

    public struct OEmbed: Codable, Equatable, Sendable {
        public var title: String?
        public var author_name: String?
        public var thumbnail_url: String?
    }
}
