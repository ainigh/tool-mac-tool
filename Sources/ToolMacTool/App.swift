import AppKit
import ServiceManagement
import SwiftUI

@main
struct ToolMacToolApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, updater: model.updater)
        } label: {
            MenuBarIcon(updater: model.updater)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var updater: Updater

    var body: some View {
        // The filled icon means an update is waiting.
        Image(systemName: updater.hasUpdate ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
    }
}

/// What the menu shows: which tools are running and how each one last went.
@MainActor
final class AppModel: ObservableObject {
    struct Result {
        var ok: Bool
        var message: String
        var reveal: URL?
        var at: Date
    }

    @Published private(set) var running: Set<String> = []
    @Published private(set) var results: [String: Result] = [:]
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    let updater = Updater()

    /// The tool that ran most recently, and how it went.
    var lastResult: (tool: Tool, result: Result)? {
        guard let last = results.max(by: { $0.value.at < $1.value.at }),
              let tool = Tools.all.first(where: { $0.id == last.key }) else { return nil }
        return (tool, last.value)
    }

    init() {
        updater.start()
        // Start at login from the first launch; the menu has a switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
    }

    func run(_ tool: Tool) {
        guard !running.contains(tool.id) else { return }
        running.insert(tool.id)
        let work = tool.run
        Task.detached(priority: .userInitiated) {
            let result: Result
            do {
                let out = try work()
                result = Result(ok: true, message: out.message, reveal: out.reveal, at: Date())
            } catch {
                result = Result(ok: false, message: error.localizedDescription, reveal: nil, at: Date())
            }
            await MainActor.run {
                self.running.remove(tool.id)
                self.results[tool.id] = result
                HUD.shared.show(title: tool.title, message: result.message, ok: result.ok, reveal: result.reveal)
            }
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("open at login: \(error)")
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
