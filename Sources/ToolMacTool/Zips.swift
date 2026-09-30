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

    private var statuses: [URL: Status] = [:]
    private var refreshing = false

    func items(within seconds: TimeInterval, now: Date = Date()) -> [Item] {
        items.filter { now.timeIntervalSince($0.plan.added) <= seconds }
    }

    func refresh() {
        if refreshing { return }
        refreshing = true
        let seconds = max(span, Self.panelSpan)
        Task.detached(priority: .utility) {
            let tool = ZipToDesktop.forCurrentUser()
            let plans = ((try? tool.recentZips(within: seconds)) ?? []).map { tool.plan(for: $0) }
            await MainActor.run {
                self.items = plans.map { Item(plan: $0, status: self.statuses[$0.zip] ?? .ready) }
                self.refreshing = false
            }
        }
    }

    func run(_ item: Item) {
        if item.status == .running { return }
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
                    HUD.shared.show(title: "Unzipped", message: r.summary, ok: true, reveal: r.target)
                case .failed(let why):
                    HUD.shared.show(title: zip.lastPathComponent, message: why, ok: false, reveal: nil)
                default:
                    break
                }
            }
        }
    }

    private func set(_ id: URL, _ status: Status) {
        statuses[id] = status
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

    static func line(for status: Status, plan: ZipToDesktop.Plan) -> String {
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
    let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let recent = zips.items(within: ZipModel.panelSpan)
        VStack(alignment: .leading, spacing: 2) {
            if recent.isEmpty {
                Text("No zips downloaded in the last 10 minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            } else {
                ForEach(recent) { item in
                    ZipRow(item: item) { zips.run(item) }
                }
            }
        }
        .padding(.top, 8)
        .onAppear { zips.refresh() }
        .onReceive(tick) { _ in zips.refresh() }
    }
}

struct ZipRow: View {
    let item: ZipModel.Item
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: run) {
                HStack(alignment: .top, spacing: 8) {
                    ZipStatusIcon(status: item.status).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.plan.zip.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(ZipModel.line(for: item.status, plan: item.plan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
    let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
            Divider()
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.zipper").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("No zips in Downloads from then").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            ZipCard(item: item) { zips.run(item) }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .onAppear { zips.refresh() }
        .onReceive(tick) { _ in zips.refresh() }
    }
}

/// One zip in the window, with everything known about it.
struct ZipCard: View {
    let item: ZipModel.Item
    let run: () -> Void

    var body: some View {
        let plan = item.plan
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZipStatusIcon(status: item.status)
                Text(plan.zip.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Text(ZipModel.ago(plan.added)).font(.caption).foregroundStyle(.secondary)
            }
            ZipFacts(plan: plan)
            ZipOutcome(status: item.status)
            HStack {
                Button(action: run) {
                    Label(plan.target.map { "Unzip into Desktop/\($0)" } ?? "Unzip", systemImage: "arrow.down.doc")
                }
                .disabled(plan.target == nil || item.status == .running)
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
                Text("Done: \(r.added.count) added, \(r.replaced.count) replaced (the old ones are in the Trash)")
                    .font(.callout)
                if !r.replaced.isEmpty {
                    Text("Replaced: " + Self.few(r.replaced)).font(.caption).foregroundStyle(.secondary)
                }
                if !r.added.isEmpty {
                    Text("Added: " + Self.few(r.added)).font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let why):
            Text(why).font(.callout).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    static func few(_ paths: [String]) -> String {
        paths.prefix(6).joined(separator: ", ") + (paths.count > 6 ? " and \(paths.count - 6) more" : "")
    }
}
