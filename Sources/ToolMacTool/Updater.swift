import AppKit
import Foundation
import ToolCore

/// Checks GitHub for a newer release (at launch and every 6 hours) and installs it in place.
///
/// The repository is private, so it asks GitHub through the `gh` command (signed in with
/// `gh auth login`, as the installer does). If the repository is ever public, it works without gh.
@MainActor
final class Updater: ObservableObject {
    static let repo = "ainigh/tool-mac-tool"
    static let assetName = "ToolMacTool.zip"
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var latest: Release?

    var hasUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    func start() {
        check(userInitiated: false)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                self?.check(userInitiated: false)
            }
        }
    }

    func check(userInitiated: Bool) {
        if state == .checking || state == .installing { return }
        state = .checking
        Task.detached {
            let outcome: State
            var release: Release?
            do {
                let r = try Self.fetchLatest()
                release = r
                outcome = r.isNewer(than: Self.currentVersion) ? .available(r.version?.description ?? r.tag) : .upToDate
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await MainActor.run {
                self.latest = release
                // A quiet background check that fails shouldn't leave an error in the menu.
                if case .failed = outcome, !userInitiated {
                    self.state = .idle
                } else {
                    self.state = outcome
                }
            }
        }
    }

    func install() {
        guard let release = latest, hasUpdate else { return }
        state = .installing
        Task.detached {
            do {
                try Self.install(release)
            } catch {
                await MainActor.run { self.state = .failed("Update failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - GitHub

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    nonisolated static func fetchLatest() throws -> Release {
        if let gh = ghPath() {
            let out = try run(gh, ["api", "repos/\(repo)/releases/latest"])
            return try Release.decode(out)
        }
        // No gh: only works if the repository is public.
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try syncFetch(req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Problem("GitHub needs you signed in: install gh (brew install gh), then run gh auth login")
        }
        return try Release.decode(data)
    }

    /// Downloads the release, swaps it in for this app, and starts the new one.
    nonisolated static func install(_ release: Release) throws {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { throw Problem("this copy isn't an app bundle (a dev build?)") }
        guard let asset = release.asset(named: assetName) else { throw Problem("the release has no \(assetName)") }

        // On the app's own volume, so the swap below is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent(assetName)
        if let gh = ghPath() {
            _ = try run(gh, ["release", "download", release.tag, "--repo", repo, "--pattern", assetName,
                             "--dir", work.path, "--clobber"])
        } else {
            let (data, response) = try syncFetch(URLRequest(url: asset.browserDownloadURL))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Problem("download failed") }
            try data.write(to: zip)
        }

        let unpacked = work.appendingPathComponent("unpacked")
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let newApp = unpacked.appendingPathComponent(app.lastPathComponent)
        let newID = Bundle(url: newApp)?.bundleIdentifier
        guard newID != nil, newID == Bundle.main.bundleIdentifier else {
            throw Problem("the download doesn't contain \(app.lastPathComponent)")
        }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        _ = try fm.replaceItemAt(app, withItemAt: newApp)

        // Start the new copy once this one has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Helpers

    /// gh from Homebrew (apps started from Finder don't get the Terminal's PATH).
    nonisolated static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GH_PROMPT_DISABLED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read both while it runs, so a full pipe can't stall it.
        var errData = Data()
        let errReader = Thread { errData = err.fileHandleForReading.readDataToEndOfFile() }
        errReader.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while !errReader.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
            let name = (tool as NSString).lastPathComponent
            if name == "gh", msg.contains("auth login") || msg.contains("401") {
                throw Problem("gh isn't signed in: run gh auth login in Terminal")
            }
            throw Problem(msg.isEmpty ? "\(name) failed (\(p.terminationStatus))" : msg)
        }
        return data
    }

    nonisolated static func syncFetch(_ req: URLRequest) throws -> (Data, URLResponse) {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error> = .failure(Problem("no answer"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let data, let response { result = .success((data, response)) } else { result = .failure(error ?? Problem("no answer")) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }
}
