import AppKit
import SwiftUI
import ToolCore

// Every board, loaded at launch so the timers in their boxes run whether or not a board is open:
// a check every second rings them, shows their reminders and cards (each with the box's text, to
// edit right there), and keeps the list of alarms coming up for the panel and the menu bar. The
// pinned boxes float on the screen in windows of their own, and come back after a relaunch. It
// also keeps a summary of every note for the panel: the ones docked along its bottom, and the
// ones each tag's board gathers (Important, Urgent, Delegate, Think). A board can be docked in
// the menu bar too, its icon beside the wrench: a click opens it, another closes it. The boards
// themselves (their names, icons and descriptions) are kept in the catalog: the ten the app comes
// with, blank ones to name on the Boards grid, and the Daily plan, which opens itself at 6 AM,
// 9 AM and noon.

@MainActor
final class BoardStore: ObservableObject {
    /// A board, by its id: what it's called, its icon and color come from the catalog (so a
    /// change there shows everywhere at once).
    struct Kind: Identifiable, Hashable, Sendable {
        let id: String

        private var info: BoardInfo {
            BoardStore.catalog.info(id) ?? BoardInfo(id: id, name: "Boards", symbol: "square.grid.2x2",
                                                     red: 0.36, green: 0.40, blue: 0.92)
        }

        /// Its name ("Board 12" while it has none).
        var name: String { isGrid ? "Boards" : BoardStore.catalog.title(id) }
        /// The line under its name.
        var detail: String { info.detail }
        /// Its icon: the one picked for it, else the one it comes with.
        var symbol: String { info.symbol }
        /// The icon it comes with.
        var defaultSymbol: String { info.defaultSymbol }
        /// Its own color in the panel, a darker shade.
        var color: Color { Color(red: info.red, green: info.green, blue: info.blue) }

        /// The Daily plan: a board like the others, never on the Boards grid.
        var isDailyPlan: Bool { id == BoardCatalog.dailyPlanID }
        /// The Boards grid itself: every board as a card.
        var isGrid: Bool { id == BoardCatalog.gridID }
        /// Its place on the Boards grid (nil: the Daily plan, or the grid).
        var slot: Int? { BoardStore.catalog.slot(id) }
    }

    /// Every board's name, icon, description and color (read from anywhere a board is drawn;
    /// changed only on the main thread, through the store).
    nonisolated(unsafe) static var catalog = BoardCatalog.load(from: BoardCatalog.url(), icons: BoardStore.legacyIcons())

    /// The icons picked for the boards before they were kept in the catalog.
    nonisolated private static func legacyIcons() -> [String: String] {
        var out: [String: String] = [:]
        for b in BoardCatalog.defaults {
            if let s = UserDefaults.standard.string(forKey: "boardIcon.\(b.id)") { out[b.id] = s }
        }
        return out
    }

    nonisolated static let dailyPlan = Kind(id: BoardCatalog.dailyPlanID)
    nonisolated static let grid = Kind(id: BoardCatalog.gridID)

    /// Every board of notes: the Daily plan, then the Boards grid's in their places.
    nonisolated static var kinds: [Kind] { catalog.all.map { Kind(id: $0.id) } }
    /// The boards on the Boards grid, in their places.
    nonisolated static var gridKinds: [Kind] { catalog.boards.map { Kind(id: $0.id) } }

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
    /// The Boards grid: where each board's card is, its size and color.
    let gridModel: BoardModel
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
        gridModel = BoardModel(id: BoardCatalog.gridID, fresh: Board(shown: BoardCatalog.defaults.count))
        for kind in Self.kinds {
            let m = BoardModel(id: kind.id)
            m.onChange = { [weak self] in self?.queueNotes() }
            models[kind.id] = m
        }
        // A card's size or color on the Boards grid.
        gridModel.onChange = { [weak self] in self?.objectWillChange.send() }
        refreshNotes()
    }

    func model(_ board: Kind) -> BoardModel {
        if board.isGrid { return gridModel }
        if let m = models[board.id] { return m }
        // A board the catalog has but that wasn't loaded (it can't happen: there are always as many).
        let m = BoardModel(id: board.id)
        m.onChange = { [weak self] in self?.queueNotes() }
        models[board.id] = m
        return m
    }

    /// The board with this id (the Boards grid too), if there is one.
    nonisolated static func kind(_ id: String) -> Kind? {
        id == BoardCatalog.gridID || catalog.info(id) != nil ? Kind(id: id) : nil
    }

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

    /// Opens a board; `focus` opens that box to fill it (showing it if it was hidden), `grid`
    /// shows its grid (putting back a box that was opened to fill it).
    func show(_ id: String, focus: Int? = nil, grid: Bool = false) {
        guard let board = Self.kind(id) else { return }
        if !board.isGrid {
            opened[id] = Date()
            UserDefaults.standard.set(opened.mapValues(\.timeIntervalSince1970), forKey: Self.openedKey)
        }
        if grid, focus == nil { model(board).expanded = nil }
        BoardWindow.show(self, board, focus: focus)
    }

    /// Opens the Boards grid: every board as a card.
    func showGrid() { show(BoardCatalog.gridID) }

    // MARK: The boards, the latest opened first

    /// When each board was last opened.
    @Published private(set) var opened: [String: Date] =
        ((UserDefaults.standard.dictionary(forKey: BoardStore.openedKey) as? [String: Double]) ?? [:]).mapValues(Date.init(timeIntervalSince1970:))
    nonisolated static let openedKey = "boardsOpened"

    /// The boards on the Boards grid that have notes, the one opened most lately first (those
    /// never opened after, in their places): beside the Boards button at the top of the panel.
    var recent: [Kind] {
        let written = Set(notes.lazy.filter { $0.title != nil }.map(\.board.id))
        return Self.gridKinds.enumerated().filter { written.contains($0.element.id) }.sorted { a, b in
            let x = opened[a.element.id] ?? .distantPast, y = opened[b.element.id] ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    /// The notes with a title on a board, in the order they show on it (those shown first).
    func written(_ board: Kind) -> [Note] {
        let b = model(board).board
        let mine = Dictionary(notes.filter { $0.board == board && $0.title != nil }.map { ($0.index, $0) }) { a, _ in a }
        return b.order.compactMap { mine[$0] }
    }

    /// What a board's buttons count: its notes with a title (the Boards grid: the boards in use).
    func count(_ board: Kind) -> Int {
        if board.isGrid { return Self.gridKinds.filter { !isBlank($0) }.count }
        return notes.filter { $0.board == board && $0.title != nil }.count
    }

    /// A board on the Boards grid with nothing on it: no notes with a title, and no name of its own.
    func isBlank(_ board: Kind) -> Bool {
        guard let info = Self.catalog.info(board.id) else { return true }
        return !info.builtin && info.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && written(board).isEmpty
    }

    // MARK: A board's name, icon and description

    func info(_ board: Kind) -> BoardInfo? { Self.catalog.info(board.id) }

    /// A board's name (the first line of its card on the Boards grid).
    func rename(_ board: Kind, _ name: String) {
        edit(board) { $0.name = name }
    }

    /// The line under a board's name (the second line of its card on the Boards grid).
    func setDetail(_ board: Kind, _ detail: String) {
        edit(board) { $0.detail = detail }
    }

    /// A different icon for a board (nil: the one it comes with): on its tile, at its top, in the
    /// menu bar, and on its notes that wear their board's.
    func setIcon(_ symbol: String?, for board: Kind) {
        edit(board) { $0.symbol = symbol ?? $0.defaultSymbol }
    }

    private func edit(_ board: Kind, _ change: (inout BoardInfo) -> Void) {
        var c = Self.catalog
        if board.isDailyPlan {
            change(&c.dailyPlan)
        } else if let i = c.slot(board.id) {
            change(&c.boards[i])
        } else {
            return
        }
        guard c != Self.catalog else { return }
        Self.catalog = c
        objectWillChange.send()
        model(board).objectWillChange.send()
        gridModel.objectWillChange.send()
        refreshNotes()
        updateStatusItems()
        saveCatalog()
    }

    private var catalogSave: Task<Void, Never>?
    /// Problem saving the catalog, if there was one.
    @Published private(set) var catalogProblem: String?

    private func saveCatalog() {
        catalogSave?.cancel()
        catalogSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try Self.catalog.save(to: BoardCatalog.url())
                self.catalogProblem = nil
            } catch {
                self.catalogProblem = "Couldn't save the boards: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Linked notes

    /// A note linked to: its summary (nil when it's gone, or has nothing to show).
    func note(_ link: NoteLink) -> Note? { notes.first { $0.board.id == link.board && $0.index == link.box } }

    /// "Goals · Plan the launch": a note, by its board and title.
    func noteName(_ link: NoteLink) -> String {
        guard let kind = Self.kind(link.board) else { return "A note that's gone" }
        return "\(kind.name) · \(note(link)?.title ?? "box \(link.box + 1)")"
    }

    /// Every note it could link to: the ones with a title, from all the boards, not itself.
    func linkable(from board: Kind, _ i: Int) -> [Note] {
        notes.filter { $0.title != nil && !($0.board.id == board.id && $0.index == i) }
    }

    func addLink(_ link: NoteLink, _ board: Kind, _ i: Int) {
        guard !model(board).board.boxes[i].links.contains(link) else { return }
        model(board).board.boxes[i].links.append(link)
    }

    func removeLink(_ link: NoteLink, _ board: Kind, _ i: Int) {
        model(board).board.boxes[i].links.removeAll { $0 == link }
    }

    /// Opens the board a linked note is on, with the note opened to fill it.
    func open(_ link: NoteLink) { show(link.board, focus: link.box) }

    /// Opens a tag's board: every note with that tag, from all the boards.
    func show(_ tag: NoteTag) { TagBoardWindow.show(self, tag) }

    /// A board docked in the menu bar (a board's id, or "tag-…"): opened, or closed when it's
    /// open (its icon toggles it).
    func open(docked id: String) {
        if let note = Self.note(fromDock: id) { return toggleMenuNote(note.board, note.box, id: id) }
        let window = Self.tag(fromDock: id).map { TagBoardWindow.id($0) } ?? BoardWindow.id(id)
        if let w = Windows.window(window), w.isVisible {
            w.orderOut(nil)
            return
        }
        if let tag = Self.tag(fromDock: id) { show(tag) } else { show(id) }
    }

    // MARK: A note's icon, tags and dock

    func icon(_ board: Kind, _ i: Int) -> String { model(board).board.boxes[i].icon ?? board.symbol }

    /// A different icon for the note (nil: its board's again).
    func setIcon(_ symbol: String?, _ board: Kind, _ i: Int) {
        model(board).board.boxes[i].icon = symbol == board.symbol ? nil : symbol
    }

    func toggle(_ tag: NoteTag, _ board: Kind, _ i: Int) { model(board).board.boxes[i].toggle(tag) }

    /// Text added at the end of a note, on a line of its own (what was said into it, a sound file
    /// written down, an action's step).
    func append(_ text: String, _ board: Kind, _ i: Int) {
        let m = model(board)
        guard m.board.boxes.indices.contains(i) else { return }
        let new = NoteText.appending(text, to: m.board.boxes[i].text)
        if new != m.board.boxes[i].text { m.board.boxes[i].text = new }
    }

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
        updateStatusItems()
    }

    /// What's in the menu bar wears its icon, and says its name (a note's title, a board's name).
    private func updateStatusItems() {
        for (id, item) in statusItems {
            guard let label = label(forDock: id), let button = item.button else { continue }
            let tip = Self.statusTip(id, name: label.name)
            if button.toolTip != tip { button.toolTip = tip }
            button.image = NSImage(systemSymbolName: label.symbol, accessibilityDescription: label.name)
            button.image?.isTemplate = true
        }
    }

    // MARK: Boards docked in the menu bar

    /// The tooltip on what's docked in the menu bar: the same words when it's put there and when
    /// its name changes.
    private static func statusTip(_ id: String, name: String) -> String {
        let what = note(fromDock: id) != nil ? "note" : "board"
        return "\(name): open or close the \(what) (right-click to take it out of the menu bar)"
    }

    nonisolated static func dockID(_ tag: NoteTag) -> String { "tag-\(tag.rawValue)" }
    nonisolated static func tag(fromDock id: String) -> NoteTag? {
        id.hasPrefix("tag-") ? NoteTag(rawValue: String(id.dropFirst(4))) : nil
    }

    /// A note's id in the menu bar: "note-<board>-<box>".
    nonisolated static func dockID(_ board: Kind, _ i: Int) -> String { "note-\(board.id)-\(i)" }
    nonisolated static func note(fromDock id: String) -> (board: Kind, box: Int)? {
        guard id.hasPrefix("note-") else { return nil }
        let rest = id.dropFirst(5)
        guard let dash = rest.lastIndex(of: "-"), let box = Int(rest[rest.index(after: dash)...]),
              let kind = kind(String(rest[..<dash])), !kind.isGrid, (0..<Board.maxBoxes).contains(box) else { return nil }
        return (kind, box)
    }

    /// What's docked in the menu bar: its name and icon (a board's, a tag's board's, or a note's).
    func label(forDock id: String) -> (name: String, symbol: String)? {
        if let tag = Self.tag(fromDock: id) { return (tag.title, tag.symbol) }
        if let kind = Self.kind(id) { return (kind.name, kind.symbol) }
        if let n = Self.note(fromDock: id) {
            let box = model(n.board).board.boxes[n.box]
            return (box.title ?? "\(n.board.name) · box \(n.box + 1)", box.icon ?? n.board.symbol)
        }
        return nil
    }

    // MARK: A note in the menu bar

    private var menuNotes: [String: GlassPanel] = [:]

    /// A note docked in the menu bar: a click there opens it by itself under its icon, as if
    /// pinned; another click puts it away.
    private func toggleMenuNote(_ board: Kind, _ i: Int, id: String) {
        if let panel = menuNotes[id], panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let panel: GlassPanel
        if let made = menuNotes[id] {
            panel = made
        } else {
            panel = GlassPanel(size: NSSize(width: 340, height: 300), resizable: true)
            panel.level = .floating
            panel.hasShadow = true
            panel.dragsAnywhere = true
            panel.minSize = NSSize(width: 220, height: 170)
            let host = FirstClickHostingView(rootView: PinnedBox(model: model(board), store: self, board: board, index: i))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": { [weak panel] in panel?.orderOut(nil) }]
            panel.onEscape = { [weak panel] in
                panel?.orderOut(nil)
                return true
            }
            menuNotes[id] = panel
        }
        // Just under its icon in the menu bar.
        if let frame = statusItems[id]?.button?.window?.frame {
            let size = panel.frame.size
            var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 6)
            if let v = NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame {
                origin.x = min(max(origin.x, v.minX + 8), v.maxX - size.width - 8)
            }
            panel.setFrameOrigin(origin)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
            menuNotes[id]?.orderOut(nil)
        }
        for id in menuBarBoards where statusItems[id] == nil {
            guard let label = label(forDock: id) else { continue }
            let name = label.name, symbol = label.symbol
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = "ToolMacTool.board.\(id)"
            let target = StatusTarget { [weak self] in self?.open(docked: id) }
            if let button = item.button {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
                button.image?.isTemplate = true
                button.identifier = MenuPanel.boardItem
                button.toolTip = Self.statusTip(id, name: name)
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
        openDailyPlan(now, calendar: cal)
        refresh(now)
    }

    // MARK: The Daily plan, opening by itself

    nonisolated static let dailyPlanKey = "dailyPlanOpened"

    /// At 6 AM, 9 AM and noon (up to an hour late, when the Mac was asleep), the Daily plan opens
    /// by itself, once each time. In quiet mode it waits until quiet mode ends.
    private func openDailyPlan(_ now: Date, calendar cal: Calendar) {
        let last = (UserDefaults.standard.object(forKey: Self.dailyPlanKey) as? Double).map(Date.init(timeIntervalSince1970:))
        guard DailyPlan.due(now: now, last: last, calendar: cal) != nil, !NSScreen.screens.isEmpty else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.dailyPlanKey)
        let open = { [weak self] in
            guard let self else { return }
            self.show(BoardCatalog.dailyPlanID, grid: true)
            self.sounds.play(.ding, for: "daily-plan", maxSeconds: nil)
        }
        if ModeCenter.shared.hold("daily-plan", open) { return }
        open()
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

    /// Daily (or mornings, afternoons, evenings), weekly or monthly on (asking first, saying what
    /// it means), or off again.
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

    /// The notes that come round: a new day, week or month (from 8 AM the day before) sets them
    /// back to To do, and on the hour (in its hours) each that isn't completed puts up its Note
    /// reminder.
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
        if let last = UserDefaults.standard.object(forKey: Self.dailyPlanKey) as? Double, last > ahead.timeIntervalSince1970 {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.dailyPlanKey)
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
