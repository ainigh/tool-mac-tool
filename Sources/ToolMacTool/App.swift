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
            MenuBarIcon(updater: model.updater, boards: model.boards)
        }
        .menuBarExtraStyle(.window)
    }
}

/// What the panel needs: the tools' models, the updater, open at login.
@MainActor
final class AppModel: ObservableObject {
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled

    let updater = Updater()
    let zips = ZipModel()
    let chat = ChatModel()
    /// Runs the scheduled jobs from launch on, whether or not its window is open.
    let scheduler = Scheduler()
    /// The timers' log: thresholds and the signals sent from it.
    let activity = ActivityStore()
    /// The battery, ticking from launch on, and the chimes' sounds and cards.
    lazy var timers = TimerBoard(activity: activity)
    /// The boards, and the timers in their boxes, ticking from launch on.
    lazy var boards = BoardStore(sounds: timers.sounds, activity: activity)
    // The chat's voice, the diagram tool and the voice tools, made when first opened.
    lazy var chatLink = VoiceLink(chat: chat)
    lazy var diagram = DiagramModel()
    lazy var speaker = Speaker()
    lazy var listener = Listener()
    lazy var transcriber = TranscribeModel()
    // Recording the screen or the microphone, and the recordings' gallery.
    lazy var recordings = RecordingsModel()
    lazy var screenRecorder: ScreenRecorder = {
        let r = ScreenRecorder()
        r.onSaved = { [weak self] _ in self?.recordings.reload() }
        return r
    }()
    /// The panel's groups pinned to float on the screen.
    lazy var groups = PinnedGroups(app: self)
    /// The screenshot tool.
    lazy var screenshots = Screenshots()
    lazy var audioRecorder: AudioRecorder = {
        let r = AudioRecorder()
        r.onSaved = { [weak self] _ in self?.recordings.reload() }
        return r
    }()

    init() {
        updater.start()
        ModelTools.shared.app = self
        MacFacts.prepare()
        // The scheduler hears of what goes into the timer log (its event jobs), runs the chimes
        // (its built-in jobs), and reads the battery and the boards' alarms for its placeholders.
        scheduler.attach(activity: activity, timers: timers, boards: boards)
        // Test mode's fast clock coming or going: the schedules are planned again from the new
        // time; leaving it, what was set on the fast clock is cleared up.
        ModeCenter.shared.onClockChange = { [weak self] leftTest in
            guard let self else { return }
            if leftTest {
                let now = Date()
                FocusCenter.shared.leftTestClock(now: now)
                self.boards.leftTestClock(now: now)
                self.timers.leftTestClock(now: now)
                self.activity.dropFuture(after: now)
            }
            self.scheduler.replanAll()
        }
        ModeCenter.shared.start()
        FocusCenter.shared.attach(boards: boards, timers: timers)
        scheduler.start()
        timers.start()
        boards.start()
        groups.restore()
        // Start at login from the first launch; the panel has a switch to turn it off.
        let key = "didSetUpOpenAtLogin"
        if !UserDefaults.standard.bool(forKey: key), Bundle.main.bundleURL.pathExtension == "app" {
            UserDefaults.standard.set(true, forKey: key)
            setOpenAtLogin(true)
        }
    }

    /// A tile: the panel goes away (it would sit over what the tool opens), then the tool opens.
    func open(_ tool: Tool) {
        MenuPanel.close()
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
