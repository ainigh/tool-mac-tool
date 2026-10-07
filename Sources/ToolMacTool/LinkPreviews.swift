import AppKit
import SwiftUI
import ToolCore
import WebKit

// A web address in a note shows under its text with the page's icon, title and site, fetched
// once (as soon as it's pasted) and kept in ~/Library/Application Support/ToolMacTool/links.json.
// A YouTube video plays right in the note when the note is big enough (opened to fill the board,
// say), and in a window of its own from its line otherwise.

@MainActor
final class LinkPreviews: ObservableObject {
    static let shared = LinkPreviews()

    /// What's known about a link.
    struct Info: Codable, Equatable {
        var title: String?
        var site: String?
        var summary: String?
        /// The page's icon (PNG, ICO… as fetched).
        var icon: Data?
        /// A YouTube video's id, and where it starts.
        var youtube: String?
        var start: Int?
        var fetched: Date
        var failed: Bool
    }

    @Published private(set) var info: [String: Info] = [:]
    /// Published so a note shows its spinner as soon as a fetch starts, not on its next redraw.
    @Published private var loading: Set<String> = []
    private var saveTask: Task<Void, Never>?
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ToolMacTool/links.json")
    /// Links kept at most (the oldest go first).
    static let limit = 600
    /// A link that couldn't be read is tried again after this long.
    static let retry: TimeInterval = 60 * 60

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        info = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([String: Info].self, from: $0) } ?? [:]
    }

    /// The web addresses in a note's text, in order, each once (four at most).
    static func links(in text: String) -> [URL] {
        guard text.contains("http"), let detector else { return [] }
        var out: [URL] = []
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let link = match.url, let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  link.host?.isEmpty == false, !out.contains(link) else { continue }
            out.append(link)
            if out.count == 4 { break }
        }
        return out
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Fetched if it isn't known yet (or failed a while ago).
    func ensure(_ link: URL) {
        if let known = info[link.absoluteString], !known.failed || Date().timeIntervalSince(known.fetched) < Self.retry { return }
        fetch(link)
    }

    /// Fetched now (again, if it's known).
    func fetch(_ link: URL) {
        let key = link.absoluteString
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task {
            let got = await Self.load(link)
            self.loading.remove(key)
            self.info[key] = got
            self.images[key] = nil
            self.trim()
            self.scheduleSave()
        }
    }

    func isLoading(_ link: URL) -> Bool { loading.contains(link.absoluteString) }

    /// Decoded icons, so a note's redraw doesn't decode them again (not published: it only
    /// remembers what `info` already holds).
    private var images: [String: NSImage] = [:]

    /// The link's icon as a picture, if it has one.
    func icon(for link: URL) -> NSImage? {
        let key = link.absoluteString
        if let image = images[key] { return image }
        guard let data = info[key]?.icon, let image = NSImage(data: data) else { return nil }
        images[key] = image
        return image
    }

    /// What pasting text brings: its links are fetched straight away.
    func pasted(_ text: String) {
        for link in Self.links(in: text) where info[link.absoluteString] == nil { fetch(link) }
    }

    // MARK: Fetching

    private nonisolated static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    nonisolated static func load(_ link: URL) async -> Info {
        var out = Info(fetched: Date(), failed: false)
        if let id = YouTube.videoID(link) {
            out.youtube = id
            out.start = YouTube.start(link)
            out.site = "YouTube"
            if let api = YouTube.oEmbedURL(link), let got = try? await get(api),
               let e = try? JSONDecoder().decode(YouTube.OEmbed.self, from: got.data) {
                out.title = e.title
                out.summary = e.author_name
            }
            out.icon = await icon([URL(string: "https://www.youtube.com/favicon.ico")!])
            out.failed = out.title == nil
            return out
        }
        guard let got = try? await get(link, accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.5") else {
            out.failed = true
            out.icon = await icon(LinkMeta.parse(html: "", base: link).icons)
            return out
        }
        let final = got.url ?? link
        let type = got.type?.lowercased() ?? ""
        if type.isEmpty || type.contains("html") || type.contains("xml") {
            let text = String(data: got.data, encoding: .utf8) ?? String(data: got.data, encoding: .isoLatin1) ?? ""
            let meta = LinkMeta.parse(html: text, base: final)
            out.title = meta.title
            out.site = meta.siteName
            out.summary = meta.summary
            out.icon = await icon(meta.icons)
        } else {
            // A file (a PDF, a picture): its name.
            out.title = final.lastPathComponent.removingPercentEncoding ?? final.lastPathComponent
            out.icon = await icon(LinkMeta.parse(html: "", base: final).icons)
        }
        return out
    }

    private struct Got {
        let data: Data
        let url: URL?
        let type: String?
    }

    /// GETs an address (a 2xx answer only), at most 2 MB of it.
    private nonisolated static func get(_ url: URL, accept: String = "*/*") async throws -> Got {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard let code = http?.statusCode, (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return Got(data: data.prefix(2_000_000), url: response.url, type: http?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// The first of the icons that's a picture this Mac can draw (and not huge).
    private nonisolated static func icon(_ candidates: [URL]) async -> Data? {
        for url in candidates.prefix(4) {
            guard let got = try? await get(url, accept: "image/*,*/*;q=0.5"), got.data.count > 0, got.data.count < 300_000,
                  let image = NSImage(data: got.data), image.isValid else { continue }
            return got.data
        }
        return nil
    }

    // MARK: Keeping

    private func trim() {
        guard info.count > Self.limit else { return }
        for (key, _) in info.sorted(by: { $0.value.fetched < $1.value.fetched }).prefix(info.count - Self.limit) {
            info[key] = nil
            images[key] = nil
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(self.info).write(to: self.url, options: .atomic)
        }
    }
}

// MARK: - In a note

/// The links in a note's text, under it: each with its page's icon, title and site (a click opens
/// it). With room, the first YouTube video plays right here.
struct LinkStrip: View {
    let text: String
    /// Room to play a video in the note.
    let roomy: Bool
    let width: CGFloat
    @ObservedObject private var previews = LinkPreviews.shared

    var body: some View {
        let links = LinkPreviews.links(in: text)
        let shown = Array(links.prefix(roomy ? 4 : 2))
        let player = roomy ? shown.first(where: { previews.info[$0.absoluteString]?.youtube != nil }) : nil
        VStack(alignment: .leading, spacing: 3) {
            if let player, let info = previews.info[player.absoluteString], let id = info.youtube {
                YouTubePlayer(id: id, start: info.start)
                    .frame(width: max(120, min(width, 520)), height: max(68, min(width, 520) * 9 / 16))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            ForEach(shown, id: \.absoluteString) { link in
                LinkLine(link: link, info: previews.info[link.absoluteString], loading: previews.isLoading(link))
            }
            if links.count > shown.count {
                Text("+\(links.count - shown.count) more")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, links.isEmpty ? 0 : 3)
        .onAppear { for link in links { previews.ensure(link) } }
        .onChange(of: links) { _, now in
            for link in now { previews.ensure(link) }
        }
    }
}

/// One link: the page's icon, its title and site. A click opens it (a YouTube video in its own
/// player window); right-click for more.
struct LinkLine: View {
    let link: URL
    let info: LinkPreviews.Info?
    let loading: Bool
    @State private var hover = false

    var body: some View {
        let raw = link.host ?? ""
        let host = raw.hasPrefix("www.") ? String(raw.dropFirst(4)) : raw
        let title = info?.title ?? (loading ? "Getting the page…" : host)
        let site = info?.site ?? host
        Button(action: open) {
            HStack(spacing: 6) {
                icon
                    .frame(width: 15, height: 15)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .lineLimit(1)
                if site != title {
                    Text(site)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.black.opacity(0.45))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if info?.youtube != nil {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(red: 0.85, green: 0.1, blue: 0.1))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(hover ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help([info?.title, info?.summary, link.absoluteString].compactMap { $0 }.joined(separator: "\n\n"))
        .contextMenu {
            Button("Open in the browser") { NSWorkspace.shared.open(link) }
            if let id = info?.youtube {
                Button("Play here") { YouTubeWindow.show(id: id, start: info?.start, title: info?.title ?? "YouTube") }
            }
            Button("Copy the link") { Clipboard.copy(link.absoluteString) }
            Button("Fetch the preview again") { LinkPreviews.shared.fetch(link) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = LinkPreviews.shared.icon(for: link) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else if loading {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: info?.youtube != nil ? "play.rectangle.fill" : "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.45))
        }
    }

    private func open() {
        if let id = info?.youtube ?? YouTube.videoID(link) {
            YouTubeWindow.show(id: id, start: info?.start ?? YouTube.start(link), title: info?.title ?? "YouTube")
        } else {
            NSWorkspace.shared.open(link)
        }
    }
}

// MARK: - YouTube

/// YouTube's player for one video. It's loaded from a page that names this app as where it's
/// embedded, as YouTube asks of apps (without that it won't play).
struct YouTubePlayer: NSViewRepresentable {
    let id: String
    var start: Int?

    static var origin: URL {
        URL(string: "https://\(Bundle.main.bundleIdentifier ?? "com.ainigh.toolmactool")".lowercased())!
    }

    final class Coordinator {
        var loaded: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        load(web, context)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { load(web, context) }

    private func load(_ web: WKWebView, _ context: Context) {
        let key = "\(id)@\(start ?? 0)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        web.loadHTMLString(YouTube.playerPage(id, start: start), baseURL: Self.origin)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        // Stop the sound when the player leaves the screen.
        web.loadHTMLString("", baseURL: nil)
    }
}

/// A video in a glass window of its own (resizable; ⌘W or ✕ closes it and stops it).
@MainActor
enum YouTubeWindow {
    static func show(id: String, start: Int?, title: String) {
        let key = "youtube-\(id)"
        Windows.show(key) {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = NSSize(width: 800, height: 500)
            let panel = GlassPanel(size: size, resizable: true)
            panel.level = .floating
            panel.hasShadow = true
            panel.minSize = NSSize(width: 360, height: 240)
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        guard let panel = Windows.window(key) as? GlassPanel else { return }
        let close = { [weak panel] in
            panel?.orderOut(nil)
            // The player goes (and its sound with it) once this click is done with.
            DispatchQueue.main.async { panel?.contentView = nil }
        }
        panel.commands = ["w": close]
        if !(panel.contentView is FirstClickHostingView<YouTubeWindowView>) {
            let host = FirstClickHostingView(rootView: YouTubeWindowView(id: id, start: start, title: title, close: close))
            host.sizingOptions = []
            panel.contentView = host
        }
    }
}

struct YouTubeWindowView: View {
    let id: String
    let start: Int?
    let title: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color(red: 1, green: 0.25, blue: 0.25))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .help("Drag to move")
                GlassIcon(symbol: "safari", help: "Open on YouTube") {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { NSWorkspace.shared.open(url) }
                }
                GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
            }
            YouTubePlayer(id: id, start: start)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.85)))
        .environment(\.colorScheme, .dark)
    }
}
