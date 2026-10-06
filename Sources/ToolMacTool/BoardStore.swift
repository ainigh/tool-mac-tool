import AppKit
import SwiftUI
import ToolCore

// Every board, loaded at launch so the timers in their boxes run whether or not a board is open:
// a check every second rings them, shows their reminders and cards (each with the box's text, to
// edit right there), and keeps the list of alarms coming up for the panel and the menu bar. The
// pinned boxes float on the screen in windows of their own, and come back after a relaunch. It
// also keeps a summary of every note for the panel: the ones docked along its bottom, and the
// ones each tag's board gathers (Important, Urgent, Delegate, Think). A board can be docked in
// the menu bar too, its icon beside the wrench: a click opens it.

@MainActor
final class BoardStore: ObservableObject {
    struct Kind: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let symbol: String
        /// Its own color in the panel, a darker shade (red, green and blue from 0 to 1).
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }
    }

    nonisolated static let kinds: [Kind] = [
        Kind(id: "goals", name: "Goals", symbol: "target", red: 0.72, green: 0.16, blue: 0.22),
        Kind(id: "strategies", name: "Strategies", symbol: "map", red: 0.80, green: 0.38, blue: 0.08),
        Kind(id: "entities", name: "Entities", symbol: "circle.hexagongrid", red: 0.62, green: 0.50, blue: 0.05),
        Kind(id: "notes", name: "Notes", symbol: "note.text", red: 0.14, green: 0.52, blue: 0.24),
        Kind(id: "people", name: "People", symbol: "person.2.fill", red: 0.04, green: 0.48, blue: 0.50),
        Kind(id: "ideas", name: "Ideas", symbol: "lightbulb.fill", red: 0.13, green: 0.33, blue: 0.76),
        Kind(id: "dreams", name: "Dreams", symbol: "moon.stars.fill", red: 0.34, green: 0.22, blue: 0.70),
        Kind(id: "projects", name: "Projects", symbol: "hammer.fill", red: 0.55, green: 0.17, blue: 0.62),
        Kind(id: "health", name: "Health", symbol: "heart.fill", red: 0.74, green: 0.14, blue: 0.46),
        Kind(id: "communication", name: "Communication", symbol: "bubble.left.and.bubble.right.fill",
             red: 0.42, green: 0.31, blue: 0.22),
    ]

    /// A note in a box, summed up for the panel and the tags' boards.
    struct Note: Identifiable, Equatable {
        let board: Kind
        let index: Int
        let title: String?
        let icon: String
        let tint: Int
        let tags: [NoteTag]
        let docked: Bool
        var id: String { "\(board.id)-\(index)" }
        /// "Goals · box 3".
        var place: String { "\(board.name) · box \(index + 1)" }
    }

    /// Every note worth listing: one with text, a tag, a dock or a timer.
    @Published private(set) var notes: [Note] = []
    /// The boards docked in the menu bar (a board's id, or a tag's board: "tag-urgent").
    @Published private(set) var menuBarBoards: [String] = UserDefaults.standard.stringArray(forKey: BoardStore.menuBarKey) ?? []

    /// An alarm coming up (or ringing now) in a box.
    struct Upcoming: Identifiable, Equatable {
        let board: Kind
        let index: Int
        let spec: TimerSpec
        /// When it rings; nil while it's ringing (at zero, waiting for OK).
        let at: Date?
        /// The box's first line of text, if it has any.
        let title: String?
        /// The note's icon and color.
        let icon: String
        let tint: Int
        /// What's left of the countdown, from 1 down to 0 (nil when it isn't counting).
        let fraction: Double?
        var id: String { "\(board.id)-\(index)" }
        /// "Goals · box 3".
        var place: String { "\(board.name) · box \(index + 1)" }
    }

    /// Every box's alarm that's counting or ringing, ringing ones first, then soonest first.
    @Published private(set) var upcoming: [Upcoming] = []
    /// Bumped every second, for what shows a countdown (the menu bar).
    @Published private(set) var now = AppClock.now()

    private(set) var models: [String: BoardModel] = [:]
    private let sounds: TonePlayer
    private let activity: ActivityStore
    private let cards = BigCards.shared
    private var ticker: Timer?
    private var pins: [String: GlassPanel] = [:]
    private var statusItems: [String: NSStatusItem] = [:]
    private var statusTargets: [String: StatusTarget] = [:]
    private var notesQueued = false
    nonisolated static let menuBarKey = "menuBarBoards"

    /// What each box's card is showing, so OK knows what it's putting away.
    private enum Shown { case reminder, ringing, round, roundPassed }
    private var showing: [String: Shown] = [:]

    init(sounds: TonePlayer, activity: ActivityStore) {
        self.sounds = sounds
        self.activity = activity
        for kind in Self.kinds {
            let m = BoardModel(id: kind.id)
            m.onChange = { [weak self] in self?.queueNotes() }
            models[kind.id] = m
        }
        refreshNotes()
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
        // The pinned boxes (and the boards docked in the menu bar) come back once the app has
        // finished starting up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self?.restorePins()
            self?.syncMenuBar()
        }
    }

    /// Opens a board; `focus` opens that box to fill it (showing it if it was hidden).
    func show(_ id: String, focus: Int? = nil) {
        guard let board = Self.kind(id) else { return }
        BoardWindow.show(self, board, focus: focus)
    }

    /// Opens a tag's board: every note with that tag, from all the boards.
    func show(_ tag: NoteTag) { TagBoardWindow.show(self, tag) }

    /// Opens a board docked in the menu bar (a board's id, or "tag-…").
    func open(docked id: String) {
        if let tag = Self.tag(fromDock: id) { show(tag) } else { show(id) }
    }

    // MARK: A note's icon, tags and dock

    func icon(_ board: Kind, _ i: Int) -> String { model(board).board.boxes[i].icon ?? board.symbol }

    /// A different icon for the note (nil: its board's again).
    func setIcon(_ symbol: String?, _ board: Kind, _ i: Int) {
        model(board).board.boxes[i].icon = symbol == board.symbol ? nil : symbol
    }

    func toggle(_ tag: NoteTag, _ board: Kind, _ i: Int) { model(board).board.boxes[i].toggle(tag) }

    /// In the row along the bottom of the panel, or out of it.
    func setDocked(_ on: Bool, _ board: Kind, _ i: Int) { model(board).board.boxes[i].docked = on }

    func tagged(_ tag: NoteTag) -> [Note] { notes.filter { $0.tags.contains(tag) } }
    var docked: [Note] { notes.filter(\.docked) }

    /// A change in a board: the summaries are made again once this moment's changes are in.
    private func queueNotes() {
        guard !notesQueued else { return }
        notesQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notesQueued = false
            self.refreshNotes()
        }
    }

    private func refreshNotes() {
        var out: [Note] = []
        for kind in Self.kinds {
            for (i, box) in model(kind).board.boxes.enumerated() {
                guard box.title != nil || !box.tags.isEmpty || box.docked || box.alarm != nil else { continue }
                out.append(Note(board: kind, index: i, title: box.title, icon: box.icon ?? kind.symbol, tint: box.tint,
                                tags: box.tags, docked: box.docked))
            }
        }
        if out != notes { notes = out }
    }

    // MARK: Boards docked in the menu bar

    nonisolated static func dockID(_ tag: NoteTag) -> String { "tag-\(tag.rawValue)" }
    nonisolated static func tag(fromDock id: String) -> NoteTag? {
        id.hasPrefix("tag-") ? NoteTag(rawValue: String(id.dropFirst(4))) : nil
    }

    /// A docked board's name and icon.
    nonisolated static func label(forDock id: String) -> (name: String, symbol: String)? {
        if let tag = tag(fromDock: id) { return (tag.title, tag.symbol) }
        if let kind = kind(id) { return (kind.name, kind.symbol) }
        return nil
    }

    func isInMenuBar(_ id: String) -> Bool { menuBarBoards.contains(id) }

    /// Its icon in the menu bar beside the wrench (a click opens it), or not.
    func setInMenuBar(_ on: Bool, _ id: String) {
        menuBarBoards.removeAll { $0 == id }
        if on { menuBarBoards.append(id) }
        UserDefaults.standard.set(menuBarBoards, forKey: Self.menuBarKey)
        syncMenuBar()
    }

    private func syncMenuBar() {
        let wanted = Set(menuBarBoards)
        for (id, item) in statusItems where !wanted.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            statusItems[id] = nil
            statusTargets[id] = nil
        }
        for id in menuBarBoards where statusItems[id] == nil {
            guard let label = Self.label(forDock: id) else { continue }
            let name = label.name, symbol = label.symbol
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "ToolMacTool.board.\(id)"
            let target = StatusTarget { [weak self] in self?.open(docked: id) }
            if let button = item.button {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
                button.image?.isTemplate = true
                button.toolTip = "\(name): open the board (right-click to take it out of the menu bar)"
                button.target = target
                button.action = #selector(StatusTarget.clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            target.onRightClick = { [weak self] in self?.setInMenuBar(false, id) }
            statusItems[id] = item
            statusTargets[id] = target
        }
    }

    // MARK: A box's timer

    func alarm(_ board: Kind, _ i: Int) -> BoxAlarm? { model(board).board.boxes[i].alarm }

    /// Starts one of a countdown's presets in a box (whatever it was running stops: one at a time).
    func start(_ spec: TimerSpec, choice: Int, in board: Kind, _ i: Int) {
        let state = spec.chose(choice, now: AppClock.now())
        set(board, i, BoxAlarm(spec: spec.id, state: state))
        if let d = spec.duration(state) { log(board, i, spec, .set, detail: TimerText.duration(d), value: d) }
    }

    /// A due date for a box, counting down from now.
    func setDue(_ date: Date, in board: Kind, _ i: Int) {
        let spec = TimerSpec.deadline
        let state = spec.due(until: date, now: AppClock.now())
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
            if let until = a.state.until, until > AppClock.now() { setDue(until, in: board, i) }
        } else if let c = a.state.choice {
            start(spec, choice: c, in: board, i)
        }
    }

    func canSnooze(_ board: Kind, _ i: Int) -> Bool {
        guard let a = alarm(board, i), let spec = a.timer else { return false }
        return spec.canSnooze(a.state, now: AppClock.now())
    }

    /// Quiet now, and ring again in three minutes (once).
    func snooze(_ board: Kind, _ i: Int) {
        let now = AppClock.now()
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
        if was == .ringing || was == .round || was == .roundPassed { log(board, i, spec, .dismissed) }
        if spec.isOneOff, spec.phase(a.state, now: AppClock.now()) == .finished {
            model(board).board.boxes[i].alarm = nil
            refresh(AppClock.now())
        }
    }

    private func set(_ board: Kind, _ i: Int, _ alarm: BoxAlarm?) {
        // Whatever it was ringing or showing belongs to the old timer.
        let key = Self.cardID(board, i)
        sounds.stop(key)
        hideCard(key)
        model(board).board.boxes[i].alarm = alarm
        refresh(AppClock.now())
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
        let now = AppClock.now()
        let cal = calendar
        for board in Self.kinds {
            let m = model(board)
            for i in m.board.boxes.indices {
                guard let a = m.board.boxes[i].alarm, let spec = a.timer else { continue }
                let key = Self.cardID(board, i)
                // A repeating timer's sound stops when the next round starts; its card stays until OK.
                if showing[key] == .round, case .counting = spec.phase(a.state, now: now) {
                    sounds.stop(key)
                    showing[key] = .roundPassed
                }
                guard let due = spec.due(a.state, now: now, calendar: cal) else { continue }
                m.board.boxes[i].alarm = due.state.isOn ? BoxAlarm(spec: a.spec, state: due.state) : nil
                if let event = due.event { fire(event, spec, board, i) }
            }
        }
        routines(now, calendar: cal)
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
                var fraction: Double?
                if case .counting(let left, let total, _) = spec.phase(a.state, now: now), total > 0 { fraction = left / total }
                out.append(Upcoming(board: board, index: i, spec: spec, at: ringing ? nil : at, title: box.title,
                                    icon: box.icon ?? board.symbol, tint: box.tint, fraction: fraction.map { ($0 * 100).rounded() / 100 }))
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
                let when = (state.until ?? AppClock.now()).formatted(date: .abbreviated, time: .shortened)
                log(board, i, spec, .alarm, detail: again ? "Again after a snooze" : "Due · \(when)", value: length)
                moment = .due(snoozed: again)
            case .repeating:
                log(board, i, spec, .alarm, detail: "Again after a snooze", value: length)
                moment = .round(state.rung)
            default:
                log(board, i, spec, .alarm, detail: again ? "Again after a snooze" : "Time's up · \(TimerText.duration(length))",
                    value: length)
                moment = .done(snoozed: again, at: AppClock.now())
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

    // MARK: Daily, weekly and monthly notes

    /// A note's status (To do, Pending, Completed): set, or taken off when it's the one on.
    func toggle(_ status: NoteStatus, _ board: Kind, _ i: Int) {
        // Completed on the note in focus is focus's Completed (it needs text, and moves on).
        let focus = FocusCenter.shared
        if status == .completed, focus.isFocus(board, i), focus.session?.canComplete == true,
           model(board).board.boxes[i].status != .completed {
            focus.complete()
            return
        }
        model(board).board.boxes[i].toggle(status, now: AppClock.now())
        // Completed for this period: its reminder (if one is up) has done its job.
        if model(board).board.boxes[i].status == .completed { hideRoutineCard(board, i) }
    }

    /// Daily, weekly or monthly on (asking first, saying what it means), or off again.
    func chooseRepeat(_ new: NoteRepeat, _ board: Kind, _ i: Int) {
        let box = model(board).board.boxes[i]
        let name = box.title ?? "\(board.name) · box \(i + 1)"
        let on = box.repeats != new
        let message: String
        if on {
            message = new.meaning(note: name)
                + (box.repeats.map { "\n\nIt's \($0.title) now: that goes (one at a time)." } ?? "")
                + "\n\nThe note's status (bottom left) is set to To do."
        } else {
            message = "No more Note reminders for \u{201C}\(name)\u{201D}. Its status (bottom left) stays as it is."
        }
        guard Confirm.ask(on ? "Turn on \(new.title) for this note?" : "Turn off \(new.title)?", message,
                          ok: on ? "Turn on \(new.title)" : "Turn off") else { return }
        model(board).board.boxes[i].setRepeat(on ? new : nil, now: AppClock.now())
        if !on { hideRoutineCard(board, i) }
    }

    static func routineID(_ board: Kind, _ i: Int) -> String { "routine-\(board.id)-\(i)" }

    private func hideRoutineCard(_ board: Kind, _ i: Int) {
        let key = Self.routineID(board, i)
        sounds.stop(key)
        cards.hide(key)
    }

    /// The notes that come round: a new day, week or month sets them back to To do, and on the
    /// hour (6 AM to 10 PM) each that isn't completed puts up its Note reminder.
    private func routines(_ now: Date, calendar cal: Calendar) {
        for board in Self.kinds {
            let m = model(board)
            for i in m.board.boxes.indices where m.board.boxes[i].repeats != nil {
                var box = m.board.boxes[i]
                _ = box.rollOver(now: now, calendar: cal)
                let hour = box.reminderDue(now: now, calendar: cal)
                if let hour { box.remindedAt = hour }
                if box != m.board.boxes[i] { m.board.boxes[i] = box }
                if let hour { remind(board, i, hour: hour) }
            }
        }
    }

    /// The Note reminder: Pending (again next hour) or Completed (done until the next day, week
    /// or month). It stays until one of them (or its ✕) is clicked.
    private func remind(_ board: Kind, _ i: Int, hour: Date) {
        let key = Self.routineID(board, i)
        // No screen (the lid is closed): nothing to show it on; the next hour tries again.
        guard !NSScreen.screens.isEmpty else { return }
        sounds.play(.ding, for: key, maxSeconds: nil)
        let m = model(board)
        cards.show(key, at: .center, onEscape: { [weak self] in self?.hideRoutineCard(board, i) }) { [weak self] size in
            NoteReminderCard(size: size, model: m, board: board, index: i, hour: hour,
                             pending: { self?.answer(.pending, board, i) },
                             completed: { self?.answer(.completed, board, i) },
                             open: { self?.show(board.id, focus: i) },
                             close: { self?.hideRoutineCard(board, i) })
        }
    }

    /// Pending or Completed on a Note reminder: the note's status, and the card put away.
    private func answer(_ status: NoteStatus, _ board: Kind, _ i: Int) {
        let m = model(board)
        m.board.boxes[i].status = status
        m.board.boxes[i].statusAt = AppClock.now()
        hideRoutineCard(board, i)
    }

    /// Test mode ended: what was set on the fast clock (still ahead of the real time) is cleared:
    /// timers, and the reminders and statuses of the notes that come round.
    func leftTestClock(now: Date = Date()) {
        let ahead = now.addingTimeInterval(5)
        for board in Self.kinds {
            let m = model(board)
            for i in m.board.boxes.indices {
                var box = m.board.boxes[i]
                if let s = box.alarm?.state, [s.start, s.until, s.snoozeAt, s.lastChime].contains(where: { ($0 ?? .distantPast) > ahead }) {
                    let key = Self.cardID(board, i)
                    sounds.stop(key)
                    hideCard(key)
                    box.alarm = nil
                }
                if let r = box.remindedAt, r > ahead { box.remindedAt = now }
                if let t = box.statusAt, t > ahead {
                    box.statusAt = now
                    if box.repeats != nil { box.status = .todo }
                }
                if box != m.board.boxes[i] { m.board.boxes[i] = box }
            }
        }
        refresh(now)
    }

    // MARK: Pinned boxes

    func isPinned(_ board: Kind, _ i: Int) -> Bool { model(board).board.boxes[i].pinned }

    /// Floats a box on the screen in a window of its own (or puts it back). The note in focus stays
    /// pinned while focus is on (only focus itself unpins it: `force`).
    func setPinned(_ on: Bool, _ board: Kind, _ i: Int, force: Bool = false) {
        if !on, !force, FocusCenter.shared.isFocus(board, i) {
            NSSound.beep()
            return
        }
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

/// The target of a board's icon in the menu bar: a click opens the board, a right-click takes it out.
@MainActor
final class StatusTarget: NSObject {
    let action: () -> Void
    var onRightClick: (() -> Void)?

    init(_ action: @escaping () -> Void) { self.action = action }

    @objc func clicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp { onRightClick?() } else { action() }
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
