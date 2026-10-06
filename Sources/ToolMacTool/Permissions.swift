import AVFoundation
import AppKit
import SwiftUI
import ToolCore

// The permissions macOS asks for (the folders, the microphone, screen recording), checked one at
// a time in a small panel at the bottom of the screen after every install or update (an update can
// make macOS ask again), and from the shield in the panel's bottom bar. macOS's question must
// never end up behind the app's windows: many of them float above others, and an answer the app
// waits for and can't be given looks like a frozen app. So while a check runs, every window of
// the app that floats is brought down to the normal level (and put back after), the panel itself
// is an ordinary window, and the checks run off the main thread.

/// Keeps macOS's questions in sight: while one may come up, the app's floating windows go down to
/// the normal level, under it.
@MainActor
enum PromptSafety {
    private static var lowered: [(window: NSWindow, level: NSWindow.Level)] = []
    private static var depth = 0

    static func lower() {
        depth += 1
        guard depth == 1 else { return }
        for w in NSApp.windows where w.isVisible && w.level.rawValue > NSWindow.Level.normal.rawValue {
            lowered.append((w, w.level))
            w.level = .normal
        }
    }

    static func restore() {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        for item in lowered { item.window.level = item.level }
        lowered = []
    }
}

@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum Item: String, CaseIterable, Identifiable {
        case downloads, desktop, documents, microphone, screen
        var id: String { rawValue }

        var title: String {
            switch self {
            case .downloads: return "Downloads folder"
            case .desktop: return "Desktop folder"
            case .documents: return "Documents folder"
            case .microphone: return "Microphone"
            case .screen: return "Screen Recording"
            }
        }

        var why: String {
            switch self {
            case .downloads: return "Unzip to Desktop reads the zips you download"
            case .desktop: return "Unzip to Desktop puts them in your Desktop folders"
            case .documents: return "The Glass folder: memory, dictations, chats, recordings, transcripts"
            case .microphone: return "Dictate, talking to the chat, Record screen and Record audio"
            case .screen: return "Record screen and Screenshot"
            }
        }

        var symbol: String {
            switch self {
            case .downloads: return "arrow.down.circle"
            case .desktop: return "menubar.dock.rectangle"
            case .documents: return "doc.on.doc"
            case .microphone: return "mic"
            case .screen: return "rectangle.dashed.badge.record"
            }
        }

        /// Its page in System Settings → Privacy & Security.
        var settings: URL {
            let page: String
            switch self {
            case .downloads, .desktop, .documents: page = "Privacy_FilesAndFolders"
            case .microphone: page = "Privacy_Microphone"
            case .screen: page = "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)")!
        }
    }

    enum State: Equatable {
        case waiting
        /// Being checked: macOS may be asking right now.
        case checking
        case allowed
        /// Turned off: it says how to turn it on.
        case denied(String)
    }

    @Published private(set) var states: [Item: State] = [:]
    @Published private(set) var running = false
    private var panel: NSPanel?
    private static let checkedKey = "permissionsCheckedFor"

    /// This build (version and commit): the check runs once for each.
    static var build: String { "\(Updater.currentVersion)-\(Updater.currentCommit ?? "")" }

    var allAllowed: Bool { Item.allCases.allSatisfy { states[$0] == .allowed } }

    /// After launch: a build that hasn't been checked yet (just installed or updated) gets the panel.
    func afterLaunch() {
        guard UserDefaults.standard.string(forKey: Self.checkedKey) != Self.build else { return }
        Task { @MainActor [weak self] in
            // Once the app has settled (its pinned windows are back), so they're lowered too.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.show(installed: true)
        }
    }

    /// The panel, and the checks run (again).
    func show(installed: Bool = false) {
        let panel = self.panel ?? make()
        self.panel = panel
        let host = FirstClickHostingView(rootView: PermissionsView(permissions: self, installed: installed) { [weak self] in
            self?.close()
        })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: v.midX - panel.frame.width / 2, y: v.minY + 16))
        }
        panel.orderFrontRegardless()
        runAll()
    }

    func close() {
        panel?.orderOut(nil)
        if !running { UserDefaults.standard.set(Self.build, forKey: Self.checkedKey) }
    }

    /// Each one in turn: the next starts once macOS has had its answer for the one before.
    func runAll() {
        guard !running else { return }
        running = true
        for item in Item.allCases { states[item] = .waiting }
        PromptSafety.lower()
        Task { @MainActor in
            for item in Item.allCases {
                self.states[item] = .checking
                self.states[item] = await Self.check(item)
            }
            self.running = false
            PromptSafety.restore()
            UserDefaults.standard.set(Self.build, forKey: Self.checkedKey)
        }
    }

    /// One again (after turning it on in System Settings).
    func recheck(_ item: Item) {
        guard !running else { return }
        PromptSafety.lower()
        states[item] = .checking
        Task { @MainActor in
            self.states[item] = await Self.check(item)
            PromptSafety.restore()
        }
    }

    // MARK: The checks (each may make macOS ask; none waits on the main thread)

    static func check(_ item: Item) async -> State {
        switch item {
        case .downloads: return await folder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        case .desktop: return await folder(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
        case .documents: return await folder(documentsFolder())
        case .microphone: return await microphone()
        case .screen: return screen()
        }
    }

    /// The Glass folder if it's there, else the nearest folder above it (Documents).
    nonisolated static func documentsFolder() -> URL {
        var url = RecordingsModel.glassFolder()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        while !FileManager.default.fileExists(atPath: url.path), url.standardizedFileURL.path != home, url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        return url
    }

    /// Reading the folder is what makes macOS ask (the first time); it's done off the main thread,
    /// which waits for the answer.
    private static func folder(_ url: URL) async -> State {
        await Task.detached(priority: .userInitiated) { () -> State in
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return .allowed
            } catch {
                let ns = error as NSError
                let refused = ns.code == NSFileReadNoPermissionError
                    || (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EPERM) || $0.code == Int(EACCES)) } == true
                if refused {
                    return .denied("Turn on Tool Mac Tool for this folder in System Settings → Privacy & Security → Files and Folders")
                }
                return .denied("Couldn't read \(url.path): \(error.localizedDescription)")
            }
        }.value
    }

    private static func microphone() async -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined:
            let granted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { done.resume(returning: $0) }
            }
            return granted ? .allowed : .denied("Turn on Tool Mac Tool in System Settings → Privacy & Security → Microphone")
        default:
            return .denied("Turn on Tool Mac Tool in System Settings → Privacy & Security → Microphone")
        }
    }

    /// macOS asks the first time; once allowed in System Settings, it counts after the app is
    /// reopened.
    private static func screen() -> State {
        if CGPreflightScreenCaptureAccess() { return .allowed }
        if CGRequestScreenCaptureAccess() { return .allowed }
        return .denied("Turn on Tool Mac Tool in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app")
    }

    private func make() -> NSPanel {
        // An ordinary window (not a floating one), so macOS's questions come up over it.
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .normal
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

/// "Installed": each permission, its state, and what to do about one that's off.
struct PermissionsView: View {
    @ObservedObject var permissions: Permissions
    let installed: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: permissions.running ? "shield.lefthalf.filled" : permissions.allAllowed ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(permissions.running ? Color.accentColor : permissions.allAllowed ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed ? "Tool Mac Tool v\(Updater.currentVersion) installed" : "Permissions")
                        .font(.system(size: 14, weight: .semibold))
                    Text(permissions.running ? "Checking what it needs, one at a time. When macOS asks, click Allow."
                         : permissions.allAllowed ? "Everything it needs is allowed." : "Some are off: the tools that need them won't work until they're on.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            ForEach(Permissions.Item.allCases) { item in
                row(item)
            }
            HStack {
                Text("Its windows stay under macOS's questions while it checks, so none is hidden.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check again") { permissions.runAll() }
                    .disabled(permissions.running)
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .padding(1)
    }

    private func row(_ item: Permissions.Item) -> some View {
        let state = permissions.states[item] ?? .waiting
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium))
                if case .denied(let how) = state {
                    Text(how).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.why).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .waiting:
                Text("Waiting").font(.system(size: 11)).foregroundStyle(.secondary)
            case .checking:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("macOS may ask: click Allow").font(.system(size: 11, weight: .medium))
                }
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            case .denied:
                HStack(spacing: 6) {
                    Button("Open Settings") { NSWorkspace.shared.open(item.settings) }
                    Button("Check") { permissions.recheck(item) }
                        .disabled(permissions.running)
                }
                .controlSize(.small)
            }
        }
    }
}
