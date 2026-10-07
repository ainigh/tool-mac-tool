import AppKit
import SwiftUI
import ToolCore

// Focus on a board (the Focus button at the top of a board): its notes one at a time, each pinned
// on the screen while you work on it, in rounds of a focus interval and a 3-minute rest, until
// the battery (set to 100% when it starts) is empty. A card in the middle of the screen keeps you
// going: reminders on the way down, then Snooze, Pending or Completed at time's up; the rest, and
// the next round. One board at a time. Strict focus can't be stopped from the app: no Stop, and
// Quit, Update, the battery, test and quiet mode and unpinning its note are all locked. Only
// quitting the app from outside (Force Quit, ⌥⌘Esc) or restarting the Mac ends it; it isn't kept
// across a relaunch.

@MainActor
final class FocusCenter: ObservableObject {
    static let shared = FocusCenter()

    @Published private(set) var session: FocusSession?
    /// Completed was asked for while the note had no text.
    @Published private(set) var needsText = false
    /// How the last session ended (shown on its last card).
    @Published private(set) var ended: String?
    /// The interval a new session starts with (the last one picked).
    @Published var interval: TimeInterval {
        didSet { UserDefaults.standard.set(interval, forKey: Self.intervalKey) }
    }

    private weak var boards: BoardStore?
    private weak var timers: TimerBoard?
    private let sounds = TonePlayer()
    private var ticker: Timer?
    /// The note the last card was about (for the card after the session ends).
    private(set) var lastPlace: (board: BoardStore.Kind, note: Int)?
    static let cardID = "focus"
    private static let intervalKey = "focusInterval"

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        interval = FocusSession.intervals.contains(saved) ? saved : FocusSession.defaultInterval
    }

    func attach(boards: BoardStore, timers: TimerBoard) {
        self.boards = boards
        self.timers = timers
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: What it's on

    var isOn: Bool { session != nil }
    /// Strict focus is running: nothing in the app may stop it.
    var isStrict: Bool { session?.strict == true }

    func isOn(_ board: BoardStore.Kind) -> Bool { session?.board == board.id }

    /// The note being worked on (or, resting, the one coming up).
    func isFocus(_ board: BoardStore.Kind, _ i: Int) -> Bool { session?.board == board.id && session?.note == i }

    var board: BoardStore.Kind? { session.flatMap { BoardStore.kind($0.board) } }

    /// The focused note's first line, or where it is.
    func title(_ board: BoardStore.Kind, _ i: Int) -> String {
        boards?.model(board).board.boxes[i].title ?? "\(board.name) · note \(i + 1)"
    }

    // MARK: Starting and stopping

    /// Focus on `board` (asking first, saying what it means; strict asks twice).
    func begin(_ board: BoardStore.Kind, strict: Bool) {
        guard let boards else { return }
        if let s = session {
            let other = BoardStore.kind(s.board)?.name ?? s.board
            if s.board == board.id && s.strict == strict { return }
            if s.strict {
                _ = Confirm.ask("Strict focus is running on \(other)", "It can't be stopped or changed from the app until the battery runs out.",
                                ok: "OK", cancel: "Close")
                return
            }
            guard Confirm.ask("Stop focus on \(other)?", "Only one board can be in focus at a time. Focus on \(other) stops, and starts on \(board.name).",
                              ok: "Stop it and go on") else { return }
        }
        let model = boards.model(board)
        guard let first = model.board.nextNote(after: nil, including: true) else {
            _ = Confirm.ask("Every note on \(board.name) is completed", "Mark one To do or Pending (bottom left of a note) to focus on it.",
                            ok: "OK", cancel: "Close")
            return
        }
        let minutes = Int(interval / 60)
        var message = "\(board.name)'s notes, one at a time, starting with \u{201C}\(title(board, first))\u{201D}: it's pinned on your screen "
            + "and a \(minutes)-minute focus interval starts. On the way down, reminders halve what's left. At time's up: "
            + "Snooze (3 minutes, once a round), Pending (rest, then the same note again) or Completed (the note is done: the next one is "
            + "pinned and a 3-minute rest starts, even before the interval is up). A note needs some text before it can be completed. "
            + "After each rest, another \(minutes)-minute round starts.\n\nThe battery is set to 100%, and focus goes on until it's empty "
            + "(it drains 20% an hour: about 5 hours)."
        if strict {
            message += "\n\nSTRICT: once it starts, nothing in Tool Mac Tool can stop it. There's no Stop; Quit, Update, the battery, "
                + "test and quiet mode are locked, and its note can't be unpinned. It ends only when the battery is empty, or if you "
                + "force-quit the app (⌥⌘Esc) or restart the Mac."
        } else {
            message += "\n\nYou can stop it any time with Stop focus at the top of the board."
        }
        guard Confirm.ask(strict ? "Start strict focus on \(board.name)?" : "Start focus on \(board.name)?", message,
                          ok: strict ? "Start strict focus" : "Start focus") else { return }
        if strict {
            guard Confirm.ask("Really start strict focus?", "There's no way to stop it from the app until the battery is empty (about 5 hours).",
                              ok: "Start it, I'm sure", cancel: "No") else { return }
        }
        if session != nil { finish(nil) }
        // Strict: nothing may be held back or sped up.
        if strict && ModeCenter.shared.mode == .quiet { ModeCenter.shared.set(.normal) }
        let now = AppClock.now()
        session = FocusSession(board: board.id, strict: strict, interval: interval, note: first, now: now,
                               onTestClock: ModeCenter.shared.mode == .test)
        ended = nil
        needsText = false
        timers?.chooseBattery(0)
        show(board, first)
        lastPlace = (board, first)
        sounds.play(.rising, for: Self.cardID, maxSeconds: nil)
        card()
    }

    /// Stop focus (normal focus only; asks first).
    func stop() {
        guard let s = session, !s.strict else { return }
        let name = BoardStore.kind(s.board)?.name ?? s.board
        guard Confirm.ask("Stop focus on \(name)?", "The note stays pinned (unpin it when you like). The battery goes on draining.",
                          ok: "Stop focus") else { return }
        finish("Stopped")
        BigCards.shared.hide(Self.cardID)
    }

    /// The session's over (`why` goes on its last card; nil: quietly).
    private func finish(_ why: String?) {
        sounds.stop(Self.cardID)
        let done = session?.completed ?? 0
        session = nil
        needsText = false
        if let why {
            ended = "\(why) · \(done == 1 ? "1 note" : "\(done) notes") completed"
        }
    }

    // MARK: Answers

    func snooze() {
        guard var s = session, s.canSnooze else { return }
        s.snooze(now: AppClock.now())
        session = s
        sounds.stop(Self.cardID)
        BigCards.shared.hide(Self.cardID)
    }

    /// Not done yet: rest, then the same note again.
    func pending() {
        guard var s = session, s.phase == .ringing || s.phase == .snoozed, let boards, let board else { return }
        let m = boards.model(board)
        m.board.boxes[s.note].status = .pending
        m.board.boxes[s.note].statusAt = AppClock.now()
        s.pending(now: AppClock.now())
        session = s
        needsText = false
        sounds.stop(Self.cardID)
        sounds.play(.ding, for: Self.cardID, maxSeconds: nil)
        card()
    }

    /// The note is done (it must have some text): it's unpinned, the next one pinned, and the
    /// rest starts.
    func complete() {
        guard var s = session, s.canComplete, let boards, let board else { return }
        let m = boards.model(board)
        guard FocusSession.hasText(m.board.boxes[s.note].text) else {
            needsText = true
            card()
            return
        }
        needsText = false
        let now = AppClock.now()
        m.board.boxes[s.note].status = .completed
        m.board.boxes[s.note].statusAt = now
        let was = s.note
        sounds.stop(Self.cardID)
        guard let next = m.board.nextNote(after: was) else {
            s.completed += 1
            session = s
            boards.setPinned(false, board, was, force: true)
            finish("Every note on \(board.name) is completed")
            card()
            return
        }
        s.complete(next: next, now: now)
        session = s
        boards.setPinned(false, board, was, force: true)
        show(board, next)
        lastPlace = (board, next)
        sounds.play(.ding, for: Self.cardID, maxSeconds: nil)
        card()
    }

    /// The note shown (the board shows more boxes if it's a hidden one) and pinned.
    private func show(_ board: BoardStore.Kind, _ i: Int) {
        guard let boards else { return }
        let m = boards.model(board)
        m.board.reveal(i)
        boards.setPinned(true, board, i)
    }

    // MARK: Running

    private func tick() {
        guard var s = session else { return }
        let now = AppClock.now()
        // The battery is the session's clock: empty, it's over.
        if let t = timers, t.battery.start != nil, Battery.level(t.battery, now: now) <= 0 {
            finish("The battery is empty: focus is over")
            card()
            return
        }
        guard BoardStore.kind(s.board) != nil else {
            finish("Its board is gone")
            return
        }
        let event = s.step(now: now)
        if s != session { session = s }
        guard let event else { return }
        switch event {
        case .reminder:
            sounds.play(.marimba, for: Self.cardID, maxSeconds: nil)
        case .timeUp, .snoozeOver:
            sounds.play(.triple, for: Self.cardID, maxSeconds: 120)
        case .focusStarted:
            sounds.play(.rising, for: Self.cardID, maxSeconds: nil)
        }
        card()
    }

    /// Test mode ended: a session begun on its fast clock ends with it; one begun before is
    /// brought back to the real time.
    func leftTestClock(now: Date = Date()) {
        guard var s = session else { return }
        if s.onTestClock {
            finish("Test mode ended")
            card()
        } else {
            s.rebase(now: now)
            session = s
        }
    }

    /// The focus card, in the middle of the screen (it follows the session as it goes).
    private func card() {
        guard let boards else { return }
        let here: BoardStore.Kind
        if let board, let s = session {
            here = board
            lastPlace = (board, s.note)
        } else if let last = lastPlace {
            here = last.board
        } else {
            return
        }
        let model = boards.model(here)
        BigCards.shared.show(Self.cardID, at: .center, onEscape: { [weak self] in
            // Time's up waits for an answer; anything else can be put away.
            if self?.session?.phase != .ringing { BigCards.shared.hide(Self.cardID) }
        }) { [weak self] size in
            if let self { FocusCard(size: size, focus: self, model: model, board: here, store: self.boards) }
        }
    }
}

// MARK: - The card

/// The focus card: what phase it's in (live), the note's text to read and edit, and the answers
/// that fit: at time's up Snooze, Pending and Completed.
struct FocusCard: View {
    let size: NSSize
    @ObservedObject var focus: FocusCenter
    @ObservedObject var model: BoardModel
    let board: BoardStore.Kind
    /// For the note's mic on the card.
    var store: BoardStore?

    var body: some View {
        let h = max(34, size.height * 0.09)
        let s = focus.session
        let note = s?.note ?? focus.lastPlace?.note ?? 0
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = AppClock.time(at: context.date)
            BigCard(size: size, symbol: s?.phase == .rest ? "cup.and.saucer.fill" : "scope", accent: accent(s),
                    name: name(s, note: note), headline: headline(s, now: now), line: line(s, note: note),
                    mood: s?.phase == .ringing ? .error : .idle, close: closeAction(s)) {
                VStack(spacing: size.height * 0.02) {
                    BoxNote(text: $model.board.boxes[note].text, height: size.height * 0.2, fontSize: max(13, size.height * 0.032),
                            store: store, board: board, index: note)
                    if focus.needsText {
                        Text("Type something in the note first (here, or on the pinned note), then click Completed.")
                            .font(.system(size: max(12, size.height * 0.03), weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 1, green: 0.6, blue: 0.55))
                    }
                    HStack(spacing: 10) {
                        if let s {
                            Image(systemName: s.strict ? "lock.fill" : "scope")
                                .foregroundStyle(.white.opacity(0.5))
                                .help(s.strict ? "Strict focus: it goes on until the battery is empty" : "Focus: Stop focus is at the top of the board")
                            Text("Round \(s.round) · \(s.completed) done")
                                .font(.system(size: max(11, h * 0.3), weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        buttons(s, h)
                    }
                }
            }
        }
    }

    private func accent(_ s: FocusSession?) -> Color {
        switch s?.phase {
        case .rest: return Color(red: 0.5, green: 0.85, blue: 1)
        case .ringing: return Color(red: 1, green: 0.55, blue: 0.5)
        case .none: return Color(red: 0.75, green: 0.75, blue: 0.8)
        default: return Color(red: 1, green: 0.78, blue: 0.35)
        }
    }

    private func name(_ s: FocusSession?, note: Int) -> String {
        guard let s else { return "Focus · \(board.name)" }
        return "\(s.strict ? "Strict focus" : "Focus") · \(board.name) · note \(note + 1) · \(TimerText.duration(s.interval)) rounds"
    }

    private func headline(_ s: FocusSession?, now: Date) -> String {
        guard let s else { return "FOCUS OVER" }
        let left = TimerText.clock(s.remaining(now: now) ?? 0)
        switch s.phase {
        case .focus: return left
        case .ringing: return "TIME'S UP"
        case .snoozed: return "Zz \(left)"
        case .rest: return "REST \(left)"
        }
    }

    private func line(_ s: FocusSession?, note: Int) -> String {
        let title = model.board.boxes[note].title ?? "Note \(note + 1) (empty)"
        guard let s else { return focus.ended ?? title }
        switch s.phase {
        case .rest: return "Next: \(title)"
        default: return title
        }
    }

    private func closeAction(_ s: FocusSession?) -> (() -> Void)? {
        if s?.phase == .ringing { return nil }
        return { BigCards.shared.hide(FocusCenter.cardID) }
    }

    @ViewBuilder private func buttons(_ s: FocusSession?, _ h: CGFloat) -> some View {
        if let s {
            switch s.phase {
            case .ringing:
                if s.canSnooze {
                    BigButton(title: "Snooze \(TimerText.duration(FocusSession.snooze))", symbol: "zzz", height: h) { focus.snooze() }
                        .help("Quiet for 3 minutes, then it rings again (once a round)")
                }
                BigButton(title: "Pending", symbol: "clock", height: h) { focus.pending() }
                    .help("Not done yet: a 3-minute rest, then another round on this note")
                BigButton(title: "Completed", symbol: "checkmark", prominent: true, height: h) { focus.complete() }
                    .help("Done: it's unpinned, the next note is pinned, and a 3-minute rest starts")
            case .snoozed:
                BigButton(title: "Pending", symbol: "clock", height: h) { focus.pending() }
                    .help("Not done yet: a 3-minute rest, then another round on this note")
                BigButton(title: "Completed", symbol: "checkmark", height: h) { focus.complete() }
                    .help("Done: it's unpinned, the next note is pinned, and a 3-minute rest starts")
                BigButton(title: "OK", prominent: true, height: h) { BigCards.shared.hide(FocusCenter.cardID) }
                    .help("Put the card away: it rings again when the snooze is over")
            case .focus:
                BigButton(title: "Completed", symbol: "checkmark", height: h) { focus.complete() }
                    .help("Done already: the next note is pinned and the rest starts now")
                BigButton(title: "OK", prominent: true, height: h) { BigCards.shared.hide(FocusCenter.cardID) }
            case .rest:
                BigButton(title: "OK", prominent: true, height: h) { BigCards.shared.hide(FocusCenter.cardID) }
            }
        } else {
            BigButton(title: "OK", prominent: true, height: h) { BigCards.shared.hide(FocusCenter.cardID) }
        }
    }
}

// MARK: - On the board

/// The Focus button at the top of a board: starts focus (normal or strict, with its interval), or,
/// while it's on, shows how it's going (and Stop, for normal focus).
struct FocusButton: View {
    @ObservedObject var focus: FocusCenter
    let board: BoardStore.Kind
    @State private var open = false

    var body: some View {
        let here = focus.isOn(board)
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: here && focus.isStrict ? "lock.fill" : "scope")
                if here, let s = focus.session {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(FocusStatus.short(s, now: AppClock.time(at: context.date)))
                            .monospacedDigit()
                    }
                } else {
                    Text("Focus")
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(here ? Color.black.opacity(0.85) : .white.opacity(0.85))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(here ? Color(red: 1, green: 0.78, blue: 0.35) : Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(.white.opacity(here ? 0 : 0.2), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(here ? "Focus is on: click for more" : "Focus on this board's notes, one at a time")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FocusPopover(focus: focus, board: board) { open = false }
        }
    }
}

/// What the Focus button opens: the interval and the two ways to start, or how it's going.
private struct FocusPopover: View {
    @ObservedObject var focus: FocusCenter
    let board: BoardStore.Kind
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Focus on \(board.name)", systemImage: "scope").font(.headline)
            if let s = focus.session, focus.isOn(board) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(FocusStatus.long(s, now: AppClock.time(at: context.date), title: focus.title(board, s.note)))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if s.strict {
                    Label("Strict: it can't be stopped from the app. It ends when the battery is empty.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Spacer()
                        Button("Stop focus", role: .destructive) {
                            done()
                            focus.stop()
                        }
                    }
                }
            } else {
                Text("Its notes one at a time, each pinned on your screen: a focus interval, then a 3-minute rest, round after round until the battery (set to 100%) is empty. At time's up: Snooze (once a round), Pending or Completed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let other = focus.board, !focus.isOn(board) {
                    Text("\(other.name) is in \(focus.isStrict ? "strict " : "")focus now (one board at a time).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Focus interval", selection: $focus.interval) {
                    ForEach(FocusSession.intervals, id: \.self) { i in
                        Text(TimerText.duration(i)).tag(i)
                    }
                }
                .disabled(focus.isStrict)
                HStack {
                    Button("Start focus") {
                        done()
                        focus.begin(board, strict: false)
                    }
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                    Button {
                        done()
                        focus.begin(board, strict: true)
                    } label: {
                        Label("Strict focus…", systemImage: "lock.fill")
                    }
                    .help("Like focus, but nothing in the app can stop it until the battery is empty")
                }
                .disabled(focus.isStrict)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// The focus bar at the top of the note being worked on: the phase and its countdown, and
/// Completed.
struct FocusBar: View {
    @ObservedObject var focus: FocusCenter

    var body: some View {
        if let s = focus.session {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Image(systemName: s.strict ? "lock.fill" : s.phase == .rest ? "cup.and.saucer.fill" : "scope")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(FocusStatus.short(s, now: AppClock.time(at: context.date)))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                    if s.canComplete {
                        Button { focus.complete() } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .frame(width: 15, height: 15)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Completed: the next note is pinned and the rest starts")
                        .accessibilityLabel("Completed")
                    }
                }
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .padding(.trailing, s.canComplete ? 4 : 8)
                .frame(height: 19)
                .background(Capsule().fill(s.phase == .ringing ? Color(red: 0.86, green: 0.22, blue: 0.28)
                                           : s.phase == .rest ? Color(red: 0.15, green: 0.45, blue: 0.7) : Color(red: 0.75, green: 0.45, blue: 0.05)))
            }
            .fixedSize()
        }
    }
}

enum FocusStatus {
    /// "Focus 7:32", "Time's up", "Zz 2:10", "Rest 2:59".
    static func short(_ s: FocusSession, now: Date) -> String {
        let left = TimerText.clock(s.remaining(now: now) ?? 0)
        switch s.phase {
        case .focus: return "Focus \(left)"
        case .ringing: return "Time's up"
        case .snoozed: return "Zz \(left)"
        case .rest: return "Rest \(left)"
        }
    }

    static func long(_ s: FocusSession, now: Date, title: String) -> String {
        let left = TimerText.left(s.remaining(now: now) ?? 0)
        let what: String
        switch s.phase {
        case .focus: what = "Focusing on \u{201C}\(title)\u{201D}: \(left) left."
        case .ringing: what = "Time's up on \u{201C}\(title)\u{201D}: Snooze, Pending or Completed (on its card)."
        case .snoozed: what = "Snoozed on \u{201C}\(title)\u{201D}: \(left) left."
        case .rest: what = "Resting: \(left) left. Next: \u{201C}\(title)\u{201D}."
        }
        return what + " Round \(s.round), \(TimerText.duration(s.interval)) each; \(s.completed) completed."
    }
}
