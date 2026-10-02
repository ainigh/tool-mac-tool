import AppKit
import SwiftUI
import ToolCore

/// What building an update here needs, checked one by one, with a way to install each missing
/// piece: Apple's command line tools, a Swift new enough (6, for FluidAudio), Homebrew, gh, and gh
/// signed in to an account that can see the repository.
@MainActor
final class BuildTools: ObservableObject {
    static let shared = BuildTools()

    enum Item: String, CaseIterable, Identifiable {
        case commandLineTools, swift, homebrew, gh, signedIn
        var id: String { rawValue }

        var title: String {
            switch self {
            case .commandLineTools: return "Apple's command line tools"
            case .swift: return "Swift 6 or newer"
            case .homebrew: return "Homebrew"
            case .gh: return "GitHub's command line tool (gh)"
            case .signedIn: return "gh signed in to GitHub"
            }
        }

        var why: String {
            switch self {
            case .commandLineTools: return "The compiler and the tools that build and sign the app."
            case .swift: return "The voices' package (FluidAudio) only builds with Swift 6."
            case .homebrew: return "Installs gh (only needed if gh isn't installed)."
            case .gh: return "Downloads updates while the repository is private."
            case .signedIn: return "Lets gh see \(Updater.repo)."
            }
        }
    }

    enum State: Equatable {
        case unknown, checking
        case ok(String)
        case missing(String)
        /// Something's under way (an installer is open, a download is running).
        case working(String)
        case failed(String)

        var isOK: Bool { if case .ok = self { return true } else { return false } }
        var detail: String {
            switch self {
            case .unknown: return "Not checked yet"
            case .checking: return "Checking…"
            case .ok(let s), .missing(let s), .working(let s), .failed(let s): return s
            }
        }
    }

    @Published private(set) var states: [Item: State] = [:]
    @Published private(set) var busy = false

    func state(_ item: Item) -> State { states[item] ?? .unknown }

    var allOK: Bool { Item.allCases.allSatisfy { state($0).isOK } }

    // MARK: - Checking

    func checkAll() {
        guard !busy else { return }
        busy = true
        for item in Item.allCases { states[item] = .checking }
        Task.detached {
            var found: [Item: State] = [:]
            for item in Item.allCases { found[item] = Self.check(item) }
            await MainActor.run {
                self.states = found
                self.busy = false
            }
        }
    }

    nonisolated static func check(_ item: Item) -> State {
        switch item {
        case .commandLineTools:
            if let out = try? Updater.run("/usr/bin/xcode-select", ["-p"]) {
                return .ok(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .missing("Not installed")
        case .swift:
            let s = Updater.swiftStatus()
            return s.ok ? .ok(s.have) : .missing("This Mac has \(s.have)")
        case .homebrew:
            if let brew = brewPath() { return .ok(brew) }
            return Updater.ghPath() != nil ? .ok("Not installed, and not needed: gh is already here") : .missing("Not installed")
        case .gh:
            if let gh = Updater.ghPath() { return .ok(gh) }
            return .missing("Not installed (updates of a private repository need it)")
        case .signedIn:
            guard let gh = Updater.ghPath() else { return .missing("Needs gh first") }
            guard (try? Updater.run(gh, ["auth", "status"])) != nil else { return .missing("Not signed in") }
            if (try? Updater.run(gh, ["api", "repos/\(Updater.repo)", "--silent"])) == nil {
                return .missing("Signed in, but that account can't see \(Updater.repo)")
            }
            return .ok("Can see \(Updater.repo)")
        }
    }

    nonisolated static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Installing

    /// Installs everything that's missing, in order (each step needs the ones before it).
    func installMissing() {
        guard let first = Item.allCases.first(where: { needsInstall($0) }) else { return }
        install(first)
    }

    func needsInstall(_ item: Item) -> Bool {
        if case .missing = state(item) { return true }
        if case .failed = state(item) { return true }
        return false
    }

    func install(_ item: Item) {
        guard !busy else { return }
        busy = true
        states[item] = .working("Starting…")
        Task.detached {
            let result = Self.install(item) { step in
                Task { @MainActor in self.states[item] = .working(step) }
            }
            await MainActor.run {
                self.busy = false
                self.states[item] = result
                // Installed for real: look at everything again (later steps may now pass).
                if result.isOK { self.checkAll() }
            }
        }
    }

    nonisolated static func install(_ item: Item, step: @escaping (String) -> Void) -> State {
        do {
            switch item {
            case .commandLineTools:
                // Apple's own installer: a dialog that downloads and installs them.
                _ = try? Updater.run("/usr/bin/xcode-select", ["--install"])
                return .working("Apple's installer is open: click Install, wait for it to finish, then Check again.")
            case .swift:
                return try installSwift(step: step)
            case .homebrew:
                try terminal(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
                return .working("Homebrew's installer is running in Terminal (it asks for your password). When it's done, Check again.")
            case .gh:
                guard let brew = brewPath() else { return .failed("Needs Homebrew first") }
                step("Installing gh with Homebrew…")
                try Updater.run(brew, ["install", "gh"], logOutput: true)
                return check(.gh)
            case .signedIn:
                guard let gh = Updater.ghPath() else { return .failed("Needs gh first") }
                try terminal("\(gh) auth login --web --git-protocol https -h github.com")
                return .working("Sign in in the Terminal window (it opens your browser). When it's done, Check again.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Updates the command line tools to the newest Software Update has (asking for your
    /// password). When it has none, they're reinstalled from scratch, which brings the newest
    /// this macOS can run.
    nonisolated static func installSwift(step: (String) -> Void) throws -> State {
        if (try? Updater.run("/usr/bin/xcode-select", ["-p"])) == nil {
            return .failed("Install Apple's command line tools first")
        }
        step("Looking for newer command line tools (this takes a minute)…")
        let list = (try? Updater.run("/bin/sh", ["-c", "/usr/sbin/softwareupdate --list 2>&1"])) ?? Data()
        if let tools = SoftwareUpdate.commandLineTools(in: String(decoding: list, as: UTF8.self)),
           (tools.version.parts.first ?? 0) >= 16 {
            step("Installing \(tools.label) (several minutes; it asks for your password)…")
            try admin("/usr/sbin/softwareupdate --install " + shellQuote(tools.label))
            Updater.log("installed \(tools.label)")
            return check(.swift)
        }
        step("Reinstalling the command line tools (it asks for your password)…")
        try admin("/bin/rm -rf /Library/Developer/CommandLineTools")
        _ = try? Updater.run("/usr/bin/xcode-select", ["--install"])
        return .working("Apple's installer is open: click Install, wait for it to finish, then Check again. "
            + "If it still has an older Swift, this macOS can't run newer tools: update macOS, or install Xcode 16 or newer from the App Store.")
    }

    /// Runs a shell command as an administrator (macOS asks for your password).
    nonisolated static func admin(_ command: String) throws {
        try Updater.run("/usr/bin/osascript", ["-e", "do shell script \(appleScriptString(command)) with administrator privileges"],
                        logOutput: true)
    }

    /// Opens Terminal running a command (for things that need you: a password, a browser sign-in).
    nonisolated static func terminal(_ command: String) throws {
        try Updater.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\"",
                                                "-e", "activate",
                                                "-e", "do script \(appleScriptString(command))",
                                                "-e", "end tell"])
    }

    nonisolated static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Every check and how it went, for pasting into a message.
    var report: String {
        var lines = ["Tool Mac Tool \(Updater.currentVersion) build tools:"]
        for item in Item.allCases {
            let s = state(item)
            lines.append("- \(item.title): \(s.isOK ? "OK" : "NOT OK") (\(s.detail))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The window

@MainActor
enum BuildToolsWindow {
    static func show() {
        Windows.show("build-tools", title: "Build tools (for updates)", size: NSSize(width: 620, height: 520)) {
            BuildToolsView(tools: .shared)
        }
        BuildTools.shared.checkAll()
    }
}

struct BuildToolsView: View {
    @ObservedObject var tools: BuildTools
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When GitHub hasn't built an update yet, the app builds it here. That needs these. Install fills in what's missing: some steps open Apple's installer or Terminal, or ask for your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(BuildTools.Item.allCases) { item in
                    row(item)
                    if item != BuildTools.Item.allCases.last { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
            HStack {
                Button("Check again") { tools.checkAll() }
                    .disabled(tools.busy)
                Button("Install what's missing") { tools.installMissing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(tools.busy || !BuildTools.Item.allCases.contains(where: tools.needsInstall))
                if tools.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(copied ? "Copied" : "Copy report") {
                    Clipboard.copy(tools.report)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                Button("Build log") { NSWorkspace.shared.show(Updater.logURL) }
                    .help(Updater.logURL.path)
            }
            if tools.allOK {
                Label("Everything's here: updates can be built on this Mac.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 420)
    }

    func row(_ item: BuildTools.Item) -> some View {
        let state = tools.state(item)
        return HStack(alignment: .top, spacing: 10) {
            Group {
                switch state {
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .checking, .working: ProgressView().controlSize(.small)
                case .unknown: Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium)
                Text(item.why).font(.caption).foregroundStyle(.secondary)
                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(state.isOK ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if tools.needsInstall(item) {
                Button("Install") { tools.install(item) }
                    .disabled(tools.busy)
            }
            if case .failed(let why) = state {
                Button("Copy") { Clipboard.copy("\(item.title): \(why)") }
            }
        }
        .padding(10)
    }
}
