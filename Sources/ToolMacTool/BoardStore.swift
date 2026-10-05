import AppKit
import SwiftUI
import ToolCore

// Every board, loaded at launch so the timers in their boxes run whether or not a board is open:
// a check every second rings them, shows their reminders and cards (each with the box's text, to
// edit right there), and keeps the list of alarms coming up for the panel and the menu bar. The
// pinned boxes float on the screen in windows of their own, and come back after a relaunch.

@MainActor
final class BoardStore: ObservableObject {
    struct Kind: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let symbol: String
    }

    nonisolated static let kinds: [Kind] = [
        Kind(id: "goals", name: "Goals", symbol: "target"),
        Kind(id: "strategies", name: "Strategies", symbol: "map"),
        Kind(id: "entities", name: "Entities", symbol: "circle.hexagongrid"),
        Kind(id: "notes", name: "Notes", symbol: "note.text"),
    ]

    /// An alarm coming up (or ringing now) in a box.
    struct Upcoming: Identifiable, Equatable {
        let board: Kind
        let index: Int
        let spec: TimerSpec
        /// When it rings; nil while it's ringing (at zero, waiting for OK).
        let at: Date?
        /// The box's first line of text, if it has any.
        let title: String?
        var id: String { "\(board.id)-\(index)" }
        /// "Goals · box 3".
        var place: String { "\(board.name) · box \(index + 1)" }
    }

    /// Every box's alarm that's counting or ringing, ringing ones first, then soonest first.
    @Published private(set) var upcoming: [Upcoming] = []
    /// Bumped every second, for what shows a countdown (the menu bar).
    @Published private(set) var now = Date()

    private(set) var models: [String: BoardModel] = [:]
    private let sounds: TonePlayer
    private let activity: ActivityStore
    private let cards = BigCards.shared
    private var ticker: Timer?
    private var pins: [String: GlassPanel] = [:]

    /// What each box's card is showing, so OK knows what it's putting away.
    private enum Shown { case reminder, ringing, round }
    private var showing: [String: Shown] = [:]

    init(sounds: TonePlayer, activity: ActivityStore) {
        self.sounds = sounds
        self.activity = activity
        for kind in Self.kinds { models[kind.id] = BoardModel(id: kind.id) }
    }

    func model(_ board: Kind) -> BoardModel { models[board.id]! }

    nonisolated static func kind(_ id: String) -> Kind? { kinds.first { $0.id == id } }

    var calendar: Calendar { Scheduler.calendar(Preferences.shared.settings) }

    func start() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
        // The pinned boxes come back once the app has finished starting up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.restorePins()
        }
    }

    /// Opens a board; `focus` opens that box to fill it (showing it if it was hidden).
    func show(_ id: String, focus: Int? = nil) {
        guard let board = Self.kind(id) else { return }
        BoardWindow.show(self, board, focus: focus)
    }

    // MARK: A box's timer

    func alarm(_ board: Kind, _ i: Int) -> BoxAlarm? { model(board).board.boxes[i].alarm }

    /// Starts one of a countdown's presets in a box (whatever it was running stops: one at a time).
    func start(_ spec: TimerSpec, choice: Int, in board: Kind, _ i: Int) {
        let state = spec.chose(choice, now: Date())
        set(board, i, BoxAlarm(spec: spec.id, state: state))
        if let d = spec.duration(state) { log(board, i, spec, .set, detail: TimerText.duration(d), value: d) }
    }

    /// A due date for a box, counting down from now.
    func setDue(_ date: Date, in board: Kind, _ i: Int) {
        let spec = TimerSpec.deadline
        let state = spec.due(until: date, now: Date())
        set(board, i, BoxAlarm(spec: spec.id, state: state))
        log(board, i, spec, .set, detail: "Due \(date.formatted(date: .abbreviated, time: .shortened))",
            value: spec.duration(state))
    }

    func stop(_ board: Kind, _ i: Int) {
        guard let was = alarm(board, i), let spec = was.timer else { return }
        set(board, i, nil)
        log(board, i, spec, .stopped)
    }

    /// The same countdown again from the top (a due date still ahead counts from now to it).
    func restart(_ board: Kind, _ i: Int) {
        guard let a = alarm(board, i), let spec = a.timer else { return }
        if spec.kind == .deadline {
            if let until = a.state.until, until > Date() { setDue(until, in: board, i) }
        } else if let c = a.state.choice {
            start(spec, choice: c, in: board, i)
        }
    }

    func canSnooze(_ board: Kind, _ i: Int) -> Bool {
        guard let a = alarm(board, i), let spec = a.timer else { return false }
        return spec.canSnooze(a.state, now: Date())
    }

    /// Quiet now, and ring again in three minutes (once).
    func snooze(_ board: Kind, _ i: Int) {
        let now = Date()
        guard let a = alarm(board, i), let spec = a.timer, spec.canSnooze(a.state, now: now) else { return }
        model(board).board.boxes[i].alarm = BoxAlarm(spec: a.spec, state: spec.snoozed(a.state, now: now))
        let key = Self.cardID(board, i)
        sounds.stop(key)
        hideCard(key)
        log(board, i, spec, .snoozed, detail: "Rings again in \(TimerText.duration(TimerSpec.snooze))")
        refresh(now)
    }

    /// OK on a box's card: quiet, put away, and a countdown or due date at zero goes off.
    func dismiss(_ board: Kind, _ i: Int) {
        let key = Self.cardID(board, i)
        let was = showing[key]
        sounds.stop(key)
        hideCard(key)
        guard let a = alarm(board, i), let spec = a.timer else { return }
        if was == .ringing || was == .round { log(board, i, spec, .dismissed) }
        if spec.isOneOff, spec.phase(a.state, now: Date()) == .finished {
            model(board).board.boxes[i].alarm = nil
            refresh(Date())
        }
    }

    private func set(_ board: Kind, _ i: Int, _ alarm: BoxAlarm?) {
        // Whatever it was ringing or showing belongs to the old timer.
        let key = Self.cardID(board, i)
        sounds.stop(key)
        hideCard(key)
        model(board).board.boxes[i].alarm = alarm
        refresh(Date())
    }

    private func hideCard(_ key: String) {
        showing[key] = nil
        cards.hide(key)
    }

    static func cardID(_ board: Kind, _ i: Int) -> String { "box-\(board.id)-\(i)" }

    private func log(_ board: Kind, _ i: Int, _ spec: TimerSpec, _ kind: LogEntry.Kind, detail: String = "",
                     value: Double? = nil) {
        activity.record(kind, source: "box-\(board.id)-\(i + 1)", name: "\(board.name) \(i + 1) · \(spec.name)",
                        detail: detail, value: value)
    }

    // MARK: Running

    private func tick() {
        let now = Date()
        let cal = calendar
        for board in Self.kinds {
            let m = model(board)
            for i in m.board.boxes.indices {
                guard let a = m.board.boxes[i].alarm, let spec = a.timer else { continue }
                let key = Self.cardID(board, i)
                // A repeating timer's card goes when the next round starts.
                if showing[key] == .round, case .counting = spec.phase(a.state, now: now) {
                    sounds.stop(key)
                    hideCard(key)
                }
                guard let due = spec.due(a.state, now: now, calendar: cal) else { continue }
                m.board.boxes[i].alarm = due.state.isOn ? BoxAlarm(spec: a.spec, state: due.state) : nil
                if let event = due.event { fire(event, spec, board, i) }
            }
        }
        refresh(now)
    }

    private func refresh(_ now: Date) {
        var out: [Upcoming] = []
        for board in Self.kinds {
            for (i, box) in model(board).board.boxes.enumerated() {
                guard let a = box.alarm, let spec = a.timer else { continue }
                let ringing = spec.phase(a.state, now: now) == .finished
                let at = a.nextRing(now: now).map { Date(timeIntervalSinceReferenceDate: $0.timeIntervalSinceReferenceDate.rounded()) }
                guard ringing || at != nil else { continue }
                let title = box.text.split(whereSeparator: \.isNewline).first
                    .map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
                out.append(Upcoming(board: board, index: i, spec: spec, at: ringing ? nil : at, title: title))
            }
        }
        out.sort { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        if out != upcoming { upcoming = out }
        self.now = now
    }

    private func fire(_ event: TimerEvent, _ spec: TimerSpec, _ board: Kind, _ i: Int) {
        let look = TimerLook.of(spec)
        let key = Self.cardID(board, i)
        let state = alarm(board, i)?.state ?? TimerState()
        // No screen (the lid is closed, or a Power Nap woke the Mac in the dark): nothing to show
        // or hear it on. It still goes into the log, and a countdown at zero stays at zero.
        guard !NSScreen.screens.isEmpty else {
            switch event {
            case .finished, .snoozeOver, .roundDone: log(board, i, spec, .alarm, detail: "While the screen was off")
            case .chime, .reminder: break
            }
            return
        }
        let ok: () -> Void = { [weak self] in self?.dismiss(board, i) }
        let box = BoxCardContext(store: self, model: model(board), board: board, index: i, spec: spec, look: look, ok: ok)
        let moment: BoxAlarmCard.Moment
        switch event {
        case .reminder:
            showing[key] = .reminder
            cards.show(key, at: .center, onEscape: ok) { size in
                BoxAlarmCard(size: size, box: box, model: box.model, moment: .reminder)
            }
            return
        case .finished, .snoozeOver:
            let length = spec.duration(state) ?? 0
            let again = event == .snoozeOver(round: 0) || spec.kind == .repeating
            switch spec.kind {
            case .deadline:
                let when = (state.until ?? Date()).formatted(date: .abbreviated, time: .shortened)
                log(board, i, spec, .alarm, detail: again ? "Again after a snooze" : "Due · \(when)", value: length)
                moment = .due(snoozed: again)
            case .repeating:
                log(board, i, spec, .alarm, detail: "Again after a snooze", value: length)
                moment = .round(state.rung)
            default:
                log(board, i, spec, .alarm, detail: again ? "Again after a snooze" : "Time's up · \(TimerText.duration(length))",
                    value: length)
                moment = .done(snoozed: again, at: Date())
            }
            sounds.play(look.tone, for: key, maxSeconds: look.tone.loops ? 120 : nil)
        case .roundDone(let round):
            log(board, i, spec, .alarm, detail: "Round \(round) done", value: Double(round))
            sounds.play(look.tone, for: key, maxSeconds: nil)
            moment = .round(round)
        case .chime:
            return
        }
        if case .round = moment { showing[key] = .round } else { showing[key] = .ringing }
        cards.show(key, at: look.spot, onEscape: ok) { size in
            BoxAlarmCard(size: size, box: box, model: box.model, moment: moment)
        }
    }

    // MARK: Pinned boxes

    func isPinned(_ board: Kind, _ i: Int) -> Bool { model(board).board.boxes[i].pinned }

    /// Floats a box on the screen in a window of its own (or puts it back).
    func setPinned(_ on: Bool, _ board: Kind, _ i: Int) {
        model(board).board.boxes[i].pinned = on
        if on { showPin(board, i) } else { pins[Self.pinID(board, i)]?.orderOut(nil) }
    }

    private func restorePins() {
        for board in Self.kinds {
            for (i, box) in model(board).board.boxes.enumerated() where box.pinned { showPin(board, i) }
        }
    }

    static func pinID(_ board: Kind, _ i: Int) -> String { "pin-\(board.id)-\(i)" }

    private func showPin(_ board: Kind, _ i: Int) {
        let id = Self.pinID(board, i)
        if let panel = pins[id] {
            panel.orderFrontRegardless()
            return
        }
        let panel = GlassPanel(size: NSSize(width: 340, height: 280), resizable: true)
        panel.level = .floating
        panel.hasShadow = true
        panel.dragsAnywhere = true
        panel.minSize = NSSize(width: 220, height: 170)
        let host = FirstClickHostingView(rootView: PinnedBox(model: model(board), store: self, board: board, index: i))
        host.sizingOptions = []
        panel.contentView = host
        panel.commands = ["w": { [weak self] in self?.setPinned(false, board, i) }]
        let name = "ToolMacTool.\(id)"
        if !panel.setFrameUsingName(name), let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            // Down the right of the screen, each new one a little in from the last.
            let n = CGFloat(pins.count % 8)
            panel.setFrameOrigin(NSPoint(x: v.maxX - 360 - n * 26, y: v.maxY - 300 - n * 26))
        }
        panel.setFrameAutosaveName(name)
        pins[id] = panel
        panel.orderFrontRegardless()
    }
}

/// When an alarm rings, short: "3:45 PM" today, "Tue 3:45 PM" this week, "12 Oct, 3:45 PM" after
/// that, with the year when it isn't this one.
enum AlarmTime {
    static func short(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if date > now, date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
}
