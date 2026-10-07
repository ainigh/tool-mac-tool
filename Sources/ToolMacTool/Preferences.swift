import AppKit
import Combine
import Foundation
import ToolCore

/// The settings every tool reads (AppSettings, in ~/Library/Application Support/ToolMacTool/
/// settings.json): changed in the Settings and Prompts windows, saved a moment after each change.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue { scheduleSave() }
        }
    }
    @Published private(set) var problem: String?

    let url = AppSettings.defaultURL()
    private var saveTask: Task<Void, Never>?

    private init() {
        if let saved = AppSettings.load(from: url) {
            settings = saved
        } else {
            // First run: start from what Glass and the earlier chat already knew.
            var s = AppSettings()
            let config = MemoryStore.GlassConfig.load(home: FileManager.default.homeDirectoryForCurrentUser)
            if let o = config.ollama, !o.isEmpty { s.ollama = o }
            s.model = UserDefaults.standard.string(forKey: "chatModel") ?? config.model ?? ""
            settings = s
            try? s.save(to: url)
        }
    }

    var ollama: Ollama {
        Ollama(base: URL(string: settings.ollama.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: AppSettings.defaultOllama)!)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        do {
            let tidy = settings.tidied()
            try tidy.save(to: url)
            // A memory prompt cleared to write a new one is saved as the default but stays empty
            // on screen; otherwise the default would pop back in under your typing.
            var shown = tidy
            if settings.memoryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shown.memoryPrompt = settings.memoryPrompt
            }
            settings = shown
            problem = nil
        } catch {
            problem = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    func reset() {
        let keep = settings
        var s = AppSettings()
        s.ollama = keep.ollama
        s.model = keep.model
        settings = s
    }
}

/// Copies text to the clipboard.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
