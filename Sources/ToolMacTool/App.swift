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

/// What the panel needs: the tools' models, the updater, open at login.
@MainActor
final class AppModel: ObservableObject {
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    let updater = Updater()
    let zips = ZipModel()
    let chat = ChatModel()
    // The chat's voice, the diagram tool and the voice tools, made when first opened.
    lazy var chatLink = VoiceLink(chat: chat)
    lazy var diagram = DiagramModel()
    lazy var speaker = Speaker()
    lazy var listener = Listener()
    lazy var transcriber = TranscribeModel()

    init() {
        updater.start()
        ModelTools.shared.app = self
        MacFacts.prepare()
        // Start at login from the first launch; the panel has a switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
    }

    func open(_ tool: Tool) {
        tool.open(self)
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
