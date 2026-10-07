import AppKit
import Combine
import SwiftUI
import ToolCore

/// The recent zips in Downloads, what each would do, and how the ones you ran went.
@MainActor
final class ZipModel: ObservableObject {
    enum Status: Equatable {
        case ready, running
        case done(ZipToDesktop.Report)
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        var plan: ZipToDesktop.Plan
        var status: Status
        var id: URL { plan.zip }
    }

    /// The panel shows the last 10 minutes; the window can look further back.
    static let panelSpan: TimeInterval = 10 * 60

    @Published private(set) var items: [Item] = []
    @Published var span: TimeInterval = 10 * 60 {
        didSet { refresh() }
    }
    /// Why the list may be wrong (Downloads or the Desktop can't be read), if it may.
    @Published private(set) var problem: String?
    /// A zip whose Desktop folder only matched part of its name: the first click asks, the second runs it.
    @Published private(set) var armed: URL?

    private var statuses: [URL: Status] = [:]
    /// The zip's date and size when its status was set: a different zip under the same name drops it.
    private var statusStamps: [URL: String] = [:]
    /// Each zip's listing, kept while its date and size stay the same, so refreshing doesn't read
    /// every zip again.
    private var listings: [URL: (stamp: String, entries: [String]?)] = [:]
    private var refreshing = false
    /// Asked to refresh while one was running (the span changed, say): go again when it's done.
    private var again = false
    private var disarm: Task<Void, Never>?

    func items(within seconds: TimeInterval, now: Date = Date()) -> [Item] {
        items.filter { now.timeIntervalSince($0.plan.added) <= seconds }
    }

    func refresh() {
        if refreshing {
            again = true
            return
        }
        refreshing = true
        let seconds = max(span, Self.panelSpan)
        let known = listings
        Task.detached(priority: .utility) {
            let tool = ZipToDesktop.forCurrentUser()
            var problem: String?
            var zips: [URL] = []
            do { zips = try tool.recentZips(within: seconds) } catch { problem = Self.explain(error, folder: "Downloads") }
            var folders: [String] = []
            do { folders = try tool.desktopFolders() } catch { problem = problem ?? Self.explain(error, folder: "Desktop") }
            var fresh: [URL: (stamp: String, entries: [String]?)] = [:]
            var plans: [ZipToDesktop.Plan] = []
            for zip in zips {
                let stamp = tool.stamp(zip)
                let kept = known[zip].flatMap { $0.stamp == stamp ? $0.entries : nil }
                let entries = kept ?? (try? tool.list(zip))
                fresh[zip] = (stamp, entries)
                plans.append(tool.plan(for: zip, entries: entries, folders: folders))
            }
            let found = plans, listings = fresh, trouble = problem
            await MainActor.run {
                // A zip that changed (downloaded again under the same name) starts fresh, not with
                // the last one's result.
                for (url, entry) in listings where self.statuses[url] != nil && self.statuses[url] != .running
                    && self.statusStamps[url] != entry.stamp {
                    self.statuses[url] = nil
                }
                self.listings = listings
                self.problem = trouble
                self.items = found.map { Item(plan: $0, status: self.statuses[$0.zip] ?? .ready) }
                self.refreshing = false
                if self.again {
                    self.again = false
                    self.refresh()
                }
            }
        }
    }

    /// A read error, in words, pointing to the setting when macOS said no.
    nonisolated static func explain(_ error: Error, folder: String) -> String {
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileReadNoPermissionError {
            return "Tool Mac Tool isn't allowed to read \(folder). Allow it in System Settings › Privacy & Security › Files and Folders."
        }
        return "Can't read \(folder): \(error.localizedDescription)"
    }

    static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    func run(_ item: Item) {
        if item.status == .running { return }
        // Only part of the zip's name matched: make sure before moving files in.
        if item.plan.unsafe == nil, item.plan.target != nil, !item.plan.exact, armed != item.id {
            arm(item.id)
            return
        }
        armed = nil
        set(item.id, .running)
        let zip = item.plan.zip
        Task.detached(priority: .userInitiated) {
            let status: Status
            do {
                status = .done(try ZipToDesktop.forCurrentUser().run(zip: zip))
            } catch {
                status = .failed(error.localizedDescription)
            }
            await MainActor.run {
                self.set(zip, status)
                switch status {
                case .done(let r):
                    HUD.shared.show(title: "Unzipped", message: r.summary, ok: true, reveal: r.target, at: .center)
                case .failed(let why):
                    HUD.shared.show(title: zip.lastPathComponent, message: why, ok: false, reveal: nil, at: .center)
                default:
                    break
                }
            }
        }
    }

    private func arm(_ id: URL) {
        armed = id
        disarm?.cancel()
        disarm = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled, self?.armed == id { self?.armed = nil }
        }
    }

    private func set(_ id: URL, _ status: Status) {
        statuses[id] = status
        if status == .running { statusStamps[id] = listings[id]?.stamp }
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = status }
    }

    /// Where the folder button goes: the target folder if there is one, else the zip.
    static func place(_ item: Item, desktop: URL = ZipToDesktop.forCurrentUser().desktop) -> URL {
        if case .done(let r) = item.status { return r.target }
        if let t = item.plan.target { return desktop.appendingPathComponent(t) }
        return item.plan.zip
    }

    /// "2 min ago"
    static func ago(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func line(for status: Status, plan: ZipToDesktop.Plan, armed: Bool = false) -> String {
        if armed, let target = plan.target { return "Click again to unzip into Desktop/\(target)" }
        switch status {
        case .ready: return plan.destination
        case .running: return "Unzipping…"
        case .done(let r): return "Done: " + r.summary
        case .failed(let why): return why
        }
    }
}

/// A small status icon for an item.
struct ZipStatusIcon: View {
    let status: ZipModel.Status

    var body: some View {
        switch status {
        case .ready:
            Image(systemName: "doc.zipper").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - In the panel

/// Under the tiles: the zips from the last 10 minutes. Click a row to run it.
struct RecentZipsList: View {
    @ObservedObject var zips: ZipModel

    var body: some View {
        let recent = zips.items(within: ZipModel.panelSpan)
        VStack(alignment: .leading, spacing: 2) {
            if let problem = zips.problem {
                ZipProblem(text: problem).padding(.horizontal, 6).padding(.vertical, 4)
            }
            if recent.isEmpty {
                Text("No zips downloaded in the last 10 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            } else {
                ForEach(recent) { item in
                    ZipRow(item: item, armed: zips.armed == item.id) { zips.run(item) }
                }
            }
        }
        .padding(.top, 8)
        .onAppear { zips.refresh() }
        .onVisibleTick(every: 5) { zips.refresh() }
    }
}

/// Why the list may be wrong, with a way to the setting that fixes it.
struct ZipProblem: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open Privacy Settings") {
                    MenuPanel.close()
                    NSWorkspace.shared.open(ZipModel.privacySettings)
                }
                Button("Copy the error") { Clipboard.copy(text) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

struct ZipRow: View {
    let item: ZipModel.Item
    let armed: Bool
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: run) {
                HStack(alignment: .top, spacing: 8) {
                    ZipStatusIcon(status: item.status).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.plan.zip.lastPathComponent).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(ZipModel.line(for: item.status, plan: item.plan, armed: armed))
                            .font(.caption)
                            .foregroundStyle(armed ? Color.accentColor : Color.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.status == .running)
            .help("Unzip into " + (item.plan.target.map { "Desktop/\($0)" } ?? "its Desktop folder"))

            IconButton(symbol: "folder", help: "Show in Finder") {
                MenuPanel.close()
                NSWorkspace.shared.show(ZipModel.place(item))
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .onHover { hover = $0 }
    }
}

// MARK: - The window

struct ZipWindow: View {
    @ObservedObject var zips: ZipModel

    struct Span: Identifiable {
        let name: String
        let seconds: TimeInterval
        var id: TimeInterval { seconds }
    }

    static let spans = [Span(name: "10 minutes", seconds: 600), Span(name: "Hour", seconds: 3600),
                        Span(name: "Day", seconds: 86400), Span(name: "Week", seconds: 7 * 86400)]

    var body: some View {
        let items = zips.items(within: zips.span)
        VStack(spacing: 0) {
            HStack {
                Picker("Downloaded in the last", selection: $zips.span) {
                    ForEach(Self.spans) { span in Text(span.name).tag(span.seconds) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Look again") { zips.refresh() }
                IconButton(symbol: "folder", help: "Open Downloads") {
                    NSWorkspace.shared.open(ZipToDesktop.forCurrentUser().downloads)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 10)
            if let problem = zips.problem {
                ZipProblem(text: problem).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.zipper").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("No zips downloaded in the last \(Self.spans.first(where: { $0.seconds == zips.span })?.name.lowercased() ?? "while")")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            ZipCard(item: item, armed: zips.armed == item.id) { zips.run(item) }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .onAppear { zips.refresh() }
        .onVisibleTick(every: 5) { zips.refresh() }
    }
}

/// One zip in the window, with everything known about it.
struct ZipCard: View {
    let item: ZipModel.Item
    let armed: Bool
    let run: () -> Void

    var body: some View {
        let plan = item.plan
        let unzipTitle: String = armed ? "Click again to confirm"
            : plan.target.map { "Unzip into Desktop/\($0)" } ?? "Unzip"
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZipStatusIcon(status: item.status)
                Text(plan.zip.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    .help(plan.zip.lastPathComponent)
                Spacer()
                Text(ZipModel.ago(plan.added)).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            ZipFacts(plan: plan)
            ZipOutcome(status: item.status)
            HStack {
                Button(action: run) {
                    Label(unzipTitle, systemImage: armed ? "questionmark.circle" : "arrow.down.doc")
                }
                .disabled(plan.target == nil || plan.unsafe != nil || item.status == .running)
                Button("Show zip") { NSWorkspace.shared.activateFileViewerSelecting([plan.zip]) }
                if plan.target != nil {
                    Button("Open folder") { NSWorkspace.shared.show(ZipModel.place(item)) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct ZipFacts: View {
    let plan: ZipToDesktop.Plan

    var body: some View {
        let size = ByteCountFormatter.string(fromByteCount: plan.size, countStyle: .file)
        let files = plan.files.map { "\($0) file\($0 == 1 ? "" : "s")" } ?? "can't read its list"
        VStack(alignment: .leading, spacing: 3) {
            Text("\(size) · \(files)" + (plan.wrapper.map { " · all inside “\($0)/”" } ?? ""))
            Text(plan.destination).foregroundStyle(plan.target == nil ? Color.orange : Color.primary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct ZipOutcome: View {
    let status: ZipModel.Status

    var body: some View {
        switch status {
        case .done(let r):
            VStack(alignment: .leading, spacing: 2) {
                Text("Done: \(r.added.count) added, \(r.replaced.count) replaced"
                     + (r.replaced.isEmpty ? "" : r.replaced.count == 1 ? " (the old one is in the Trash)" : " (the old ones are in the Trash)"))
                    .font(.callout)
                if !r.replaced.isEmpty {
                    Text("Replaced: " + Self.few(r.replaced)).font(.caption).foregroundStyle(.secondary)
                }
                if !r.added.isEmpty {
                    Text("Added: " + Self.few(r.added)).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let why):
            ErrorLine(text: why)
        default:
            EmptyView()
        }
    }

    static func few(_ paths: [String]) -> String {
        paths.prefix(6).joined(separator: ", ") + (paths.count > 6 ? " and \(paths.count - 6) more" : "")
    }
}
