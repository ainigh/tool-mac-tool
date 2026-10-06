import AppKit
import SwiftUI
import ToolCore

// The app's modes: normal; test (the clock the schedules, chimes, note timers, note reminders and
// the battery run by goes 60 times faster, for 30 minutes); and quiet (nothing pops up and the
// timers make no sound, for an hour, then everything held back pops up at once). The switch is in
// the panel's bottom bar; the mode shows beside the wrench while it's on.

@MainActor
final class ModeCenter: ObservableObject {
    static let shared = ModeCenter()

    @Published private(set) var state: ModeState
    /// How many pop-ups quiet mode is holding back.
    @Published private(set) var heldCount = 0

    var mode: AppMode { state.mode }

    /// Told when the app's clock changes (test mode starts or ends): `leftTest` is true when the
    /// fast clock was just let go of (what was set on it is cleared up).
    var onClockChange: ((_ leftTest: Bool) -> Void)?

    private var held: [(key: String, show: () -> Void)] = []
    private var ticker: Timer?
    private static let key = "appMode"

    private init() {
        state = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ModeState.self, from: $0) } ?? ModeState()
        AppClock.warp = state.mode == .test ? state.warp : nil
    }

    /// Starts watching the clock: a mode whose time is up goes back to normal (also one that ran
    /// out while the app was closed).
    func start() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
    }

    private func tick() {
        if state.isOver(at: Date()) { set(.normal) }
    }

    /// Into `new` from now (again from the start, if it's the one it's in).
    func set(_ new: AppMode) {
        // Strict focus: nothing may be sped up or held back.
        if new != .normal && FocusCenter.shared.isStrict { return }
        let old = state
        state = ModeState.entering(new, at: Date())
        AppClock.warp = state.warp
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.key) }
        if old.mode == .test || new == .test { onClockChange?(old.mode == .test) }
        if old.mode == .quiet && new != .quiet { release() }
    }

    /// Asks first, saying what it means, then switches.
    func choose(_ new: AppMode) {
        if new == .normal && mode == .normal { return }
        let title: String
        switch new {
        case .normal: title = "Back to normal mode?"
        case .test: title = mode == .test ? "Start test mode again?" : "Turn on test mode?"
        case .quiet: title = mode == .quiet ? "Start quiet mode again?" : "Turn on quiet mode?"
        }
        var message = new.meaning
        if mode == .quiet && new != .quiet && heldCount > 0 {
            message += "\n\nThe \(heldCount == 1 ? "pop-up" : "\(heldCount) pop-ups") held back in quiet mode pop up now."
        }
        if mode == .test && new != .test {
            message += "\n\nLeaving test mode: the schedules are planned again from the real time, and timers and log entries made on the fast clock are cleared."
        }
        guard Confirm.ask(title, message, ok: new == .normal ? "Back to normal" : "Turn on \(new.title.lowercased()) mode") else { return }
        set(new)
    }

    // MARK: Quiet mode's held pop-ups

    /// In quiet mode, keeps `show` to run when it ends and returns true (a newer one with the same
    /// key takes the older one's place: the same card, brought up to date); otherwise false.
    func hold(_ key: String, _ show: @escaping () -> Void) -> Bool {
        guard mode == .quiet else { return false }
        held.removeAll { $0.key == key }
        held.append((key, show))
        heldCount = held.count
        return true
    }

    /// A held pop-up that's no longer wanted (its card was put away meanwhile).
    func drop(_ key: String) {
        guard !held.isEmpty else { return }
        held.removeAll { $0.key == key }
        heldCount = held.count
    }

    /// Everything held back pops up now, in the order it came.
    private func release() {
        let items = held
        held = []
        heldCount = 0
        for item in items { item.show() }
    }
}

// MARK: - Asking first

/// A plain question with two buttons, over everything (including the floating cards).
@MainActor
enum Confirm {
    static func ask(_ title: String, _ message: String, ok: String, cancel: String = "Cancel") -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: cancel)
        alert.layout()
        alert.window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A schedule (a job, a chime) turned on or off: what that means (`doing`: what its action
    /// does, from `Scheduler.doing`), then yes or no.
    static func schedule(_ job: ScheduledJob, doing: String, on: Bool, clock24: Bool) -> Bool {
        let name = job.name.isEmpty ? "Untitled" : job.name
        let when = job.when.describe(clock24: clock24)
        let message: String
        if on {
            message = "\(when): it will \(doing)."
                + (job.when.kind == .once ? " It runs once, then turns itself off." : " This repeats until you turn it off.")
                + " Jobs run while Tool Mac Tool is open."
        } else {
            message = "It won't run again until you turn it back on (it's set to: \(when)). Its settings and history are kept."
        }
        return ask(on ? "Turn on \u{201C}\(name)\u{201D}?" : "Turn off \u{201C}\(name)\u{201D}?", message,
                   ok: on ? "Turn on" : "Turn off")
    }

}

// MARK: - The switch, in the panel's bottom bar

/// Normal, test and quiet: the one on is lit, with the time it has left.
struct ModeSwitch: View {
    @ObservedObject var modes: ModeCenter
    @ObservedObject private var focus = FocusCenter.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppMode.allCases, id: \.self) { m in
                let on = modes.mode == m
                Button { modes.choose(m) } label: {
                    Image(systemName: m.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .frame(width: 24, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Self.color(m) : Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Strict focus: nothing may be sped up or held back.
                .disabled(focus.isStrict && m != .normal)
                .help(focus.isStrict && m != .normal ? "Strict focus is on: test and quiet mode are locked until it's over"
                      : Self.help(m, on: on))
            }
            if modes.mode != .normal {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.left(modes.state, now: context.date, held: modes.heldCount))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Self.color(modes.mode))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.leading, 3)
            }
        }
    }

    static func color(_ m: AppMode) -> Color {
        switch m {
        case .normal: return .accentColor
        case .test: return Color(red: 0.9, green: 0.45, blue: 0.1)
        case .quiet: return Color(red: 0.42, green: 0.36, blue: 0.85)
        }
    }

    static func left(_ s: ModeState, now: Date, held: Int) -> String {
        let secs = Int((s.remaining(at: now) ?? 0).rounded(.up))
        let time = String(format: "%d:%02d", secs / 60, secs % 60)
        switch s.mode {
        case .normal: return ""
        case .test: return "Test · \(time)"
        case .quiet: return "Quiet · \(time)" + (held > 0 ? " · \(held) held" : "")
        }
    }

    static func help(_ m: AppMode, on: Bool) -> String {
        let what: String
        switch m {
        case .normal: what = "Normal mode: the real clock, pop-ups as they come."
        case .test: what = "Test mode: a day goes by in 24 minutes (an hour in a minute), to try schedules, timers and reminders. Back to normal after 30 minutes."
        case .quiet: what = "Quiet mode: no pop-ups and no timer sounds for an hour; then everything held back pops up."
        }
        if on { return what + (m == .normal ? " (On now.)" : " (On now: click to start it again.)") }
        return what + " Click to switch (it asks first)."
    }
}
