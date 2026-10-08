import AppKit
import SwiftUI
import ToolCore

// The panel's rows and columns of notes and boards: across the very top the Daily plan, the
// Boards button (every board, on a grid of its own) and the boards with notes (each in its own
// darker color, the one opened most lately first), the chimes' switches (built-in schedules) beside the Scheduler, the notes
// running a timer (docked in their column by themselves while it runs), the schedules that are on
// (the next to run first), the tags' boards, and the
// notes docked along the bottom.

// MARK: - The boards, across the top

struct BoardsRow: View {
    @ObservedObject var store: BoardStore
    var groups: PinnedGroups?
    /// The most boards with notes shown beside the Boards button (the rest are on its grid).
    static let most = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Boards", color: Tools.boardsColor, groups: groups, pinID: PinnedGroups.boardsID)
            HStack(spacing: MenuView.gap) {
                // Always first: the Daily plan, then the Boards button.
                tile(BoardStore.dailyPlan, help: "The Daily plan: a board of its own, that opens by itself at \(DailyPlan.hoursText) every day.")
                tile(BoardStore.grid, color: Tools.boardsColor,
                     help: "Every board, as a card: name them, change their icons and descriptions, and see their notes. A blank board comes with the → at the top.")
                // Then the boards with notes, the one opened most lately first.
                ForEach(store.recent.prefix(Self.most)) { kind in tile(kind) }
                Spacer(minLength: 0)
            }
        }
    }

    private func tile(_ kind: BoardStore.Kind, color: Color? = nil, help: String? = nil) -> some View {
        BoardTile(kind: kind, color: color ?? kind.color, help: help, count: store.count(kind), inMenuBar: store.isInMenuBar(kind.id),
                  open: {
                      MenuPanel.close()
                      store.show(kind.id)
                  },
                  dock: { store.setInMenuBar($0, kind.id) })
    }
}

/// A board: its icon and name on its own color, and how many notes it has (on the Boards button,
/// how many boards). Right-click to dock it in the menu bar.
private struct BoardTile: View {
    let kind: BoardStore.Kind
    let color: Color
    let help: String?
    /// Its notes with a title (the Boards button: the boards in use).
    let count: Int
    let inMenuBar: Bool
    let open: () -> Void
    let dock: (Bool) -> Void
    @State private var hover = false

    private var countText: String {
        if kind.isGrid { return count == 1 ? "1 board in use." : "\(count) boards in use." }
        return count == 0 ? "No notes yet." : count == 1 ? "1 note." : "\(count) notes."
    }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 5) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 19, weight: .semibold))
                Text(kind.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 0, maxWidth: 104)
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.gradient))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(hover ? 0.45 : 0.12), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if count > 0 { CountBadge(count: count, color: color).padding(4) }
            }
            .overlay(alignment: .topLeading) {
                if inMenuBar {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(5)
                        .help("In the menu bar")
                }
            }
            .scaleEffect(hover ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("\(help ?? "\(kind.name): a board of notes.") \(countText) Right-click to \(inMenuBar ? "take it out of" : "dock it in") the menu bar.")
        .contextMenu {
            Button("Open \(kind.name)", action: open)
            Button(inMenuBar ? "Take out of the menu bar" : "Dock in the menu bar (beside the wrench)") { dock(!inMenuBar) }
        }
    }
}

// MARK: - The chimes, beside the Scheduler

/// A built-in chime (a scheduler job): a click turns it on or off; right-click opens it in the
/// Scheduler, to change its hours.
struct ChimeTile: View {
    let builtin: ScheduledJob.Builtin
    @ObservedObject var scheduler: Scheduler
    let color: Color
    @State private var hover = false

    var body: some View {
        let job = scheduler.builtin(builtin)
        let on = job?.enabled == true
        Button {
            flip(job, on: on)
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.28)))
                    Image(systemName: builtin == .dayChime ? "sun.max" : "moon.zzz")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                .scaleEffect(hover ? 1.06 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                Text(job?.name ?? fallbackName)
                    .font(.system(size: 10.5, weight: hover ? .medium : .regular))
                    .foregroundStyle(hover ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(status(job))
                    .font(.system(size: 10, weight: on ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(on ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(width: MenuView.tile, height: 84)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? color.opacity(0.14) : .clear))
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help(job, on: on))
        .contextMenu {
            Button(on ? "Turn off…" : "Turn on…") { flip(job, on: on) }
            Button("Open in the Scheduler…") {
                MenuPanel.close()
                SchedulerWindow.show(scheduler, select: job?.id)
            }
        }
    }

    /// On or off, after saying what that means.
    private func flip(_ job: ScheduledJob?, on: Bool) {
        guard let job, Confirm.schedule(job, doing: scheduler.doing(job), on: !on, clock24: scheduler.prefs.settings.clock24) else { return }
        scheduler.setEnabled(job.id, !on)
    }

    /// Its name before the scheduler has its job (it always should, but the tile still needs one).
    private var fallbackName: String { builtin == .dayChime ? "Day chime" : "Night watch" }

    private func status(_ job: ScheduledJob?) -> String {
        guard let job, job.enabled else { return "Off" }
        guard let next = job.next else { return "On" }
        return "Next \(TimerText.hourLabel(Calendar.current.component(.hour, from: next)))"
    }

    private func help(_ job: ScheduledJob?, on: Bool) -> String {
        let what = builtin == .dayChime
            ? "A ding and a card every hour through the day, with hours since 6 AM and to 10 PM."
            : "A ding and a warning card every hour through the night, with the hours left before 6 AM."
        // Without its job there's no "when": leave it out rather than end on an empty ": )".
        let when = job.map { ": " + $0.when.describe(clock24: scheduler.prefs.settings.clock24) } ?? ""
        return "\(job?.name ?? fallbackName) (a built-in schedule\(when))\n\n\(what)\n\n\(on ? "On: click to turn it off (it asks first)." : "Off: click to turn it on (it asks first).") Right-click to change its hours in the Scheduler."
    }
}

// MARK: - The notes running a timer

/// The notes with a timer or a due date running, soonest (and ringing) first: each docks here by
/// itself while its timer runs. A click opens it.
struct TimedNotesColumn: View {
    @ObservedObject var store: BoardStore
    let color: Color
    static let most = 4

    var body: some View {
        VStack(spacing: MenuView.gap) {
            if store.upcoming.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "timer")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(color.opacity(0.55))
                    Text("Set a timer on a note and it docks here while it runs")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: MenuView.bigTile)
                .padding(.vertical, 12)
            } else {
                ForEach(store.upcoming.prefix(Self.most)) { u in
                    TimedNoteTile(u: u, now: store.now) {
                        MenuPanel.close()
                        store.show(u.board.id, focus: u.index)
                    }
                }
                if store.upcoming.count > Self.most {
                    Text("+\(store.upcoming.count - Self.most) more")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A note running a timer: its icon in a ring that empties as the time goes, the timer's own
/// badge, its title and the countdown, on a dashed card in the timer's color (red while it rings).
private struct TimedNoteTile: View {
    let u: BoardStore.Upcoming
    let now: Date
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let look = TimerLook.of(u.spec)
        let ringing = u.at == nil
        let accent = ringing ? Color(red: 0.88, green: 0.24, blue: 0.28) : look.accent
        let colors = NoteLook.colors(tint: u.tint, board: u.board)
        Button(action: open) {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(colors.fill)
                    Image(systemName: u.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(colors.ink)
                        .symbolEffect(.pulse, isActive: ringing)
                    Circle().stroke(accent.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.001, min(1, ringing ? 1 : (u.fraction ?? 1))))
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: look.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(accent))
                        .offset(x: 4, y: 3)
                }
                Text(u.title ?? u.place)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Text(u.at.map { TimerText.countdown($0.timeIntervalSince(now)) } ?? (u.spec.kind == .deadline ? "Due now" : "Time's up"))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ringing ? accent : .primary)
                    .lineLimit(1)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(width: MenuView.bigTile)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(hover ? 0.24 : 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("\(u.place) · \(u.spec.name)\(u.title.map { " · \($0)" } ?? "")\n\(u.at.map { "Rings \(AlarmTime.short($0, now: now))" } ?? "Ringing now")\n\nClick to open the note.")
    }
}

// MARK: - The schedules that are on

/// The schedules that are on, the next to run first (then the ones waiting for something to
/// happen), as the notes running a timer are listed beside them. A click opens one in the
/// Scheduler; right-click to run it now, skip its next run or turn it off.
struct ScheduledJobsColumn: View {
    @ObservedObject var scheduler: Scheduler
    let color: Color
    static let most = 4

    var body: some View {
        let jobs = scheduler.book.upcoming()
        VStack(spacing: MenuView.gap) {
            if jobs.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(color.opacity(0.55))
                    Text("Turn on a schedule and it shows here, with when it runs next")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: MenuView.bigTile)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    MenuPanel.close()
                    SchedulerWindow.show(scheduler)
                }
                .help("Click to open the Scheduler")
            } else {
                // Ticks every second, for the countdowns (on the app's clock, so test mode shows too).
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let now = AppClock.now()
                    VStack(spacing: MenuView.gap) {
                        ForEach(jobs.prefix(Self.most)) { job in
                            ScheduledJobTile(job: job, scheduler: scheduler, now: now)
                        }
                    }
                }
                if jobs.count > Self.most {
                    Button {
                        MenuPanel.close()
                        SchedulerWindow.show(scheduler)
                    } label: {
                        Text("+\(jobs.count - Self.most) more")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Every schedule, in the Scheduler")
                }
            }
        }
    }
}

/// A schedule that's on: its action's icon on its color, its name, and when it runs next (a
/// countdown under a day away; what it waits for when it waits for something to happen).
private struct ScheduledJobTile: View {
    let job: ScheduledJob
    @ObservedObject var scheduler: Scheduler
    let now: Date
    @State private var hover = false

    var body: some View {
        let action = scheduler.action(job.actionID)
        let accent = action?.live.first.map { JobRow.color($0.kind) } ?? Color.gray
        let running = scheduler.running.contains(job.id)
        let failed = job.lastOK == false
        Button(action: open) {
            VStack(spacing: 3) {
                ZStack {
                    // Every so many minutes: a ring round it fills as its next run comes.
                    Circle().fill(accent.gradient).padding(fraction == nil ? 0 : 5)
                    Image(systemName: scheduler.symbol(for: job))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, isActive: running)
                    if let fraction {
                        Circle().stroke(accent.opacity(0.25), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.001, min(1, fraction)))
                            .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                }
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if failed {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(Color.orange))
                            .offset(x: 4, y: 3)
                            .help(job.lastResult ?? "It went wrong last time")
                    } else if job.when.kind == .event {
                        Image(systemName: job.when.event.symbol)
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(accent.opacity(0.85)))
                            .offset(x: 4, y: 3)
                    }
                }
                Text(job.name.isEmpty ? "Untitled" : job.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                Text(running ? "Running…" : when)
                    .font(.system(size: 10.5, weight: job.next == nil ? .medium : .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(running ? AnyShapeStyle(accent) : job.next == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .frame(width: MenuView.bigTile)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(hover ? 0.24 : 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: job.next == nil ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help(action))
        .contextMenu {
            Button("Open in the Scheduler", action: open)
            Button("Run now") { scheduler.run(job.id, byHand: true) }
                .disabled(running)
            if job.next != nil {
                Button("Skip the next run") { scheduler.skipNext(job.id) }
            }
            Divider()
            Button("Turn off…") {
                guard Confirm.schedule(job, doing: scheduler.doing(job), on: false, clock24: scheduler.prefs.settings.clock24) else { return }
                scheduler.setEnabled(job.id, false)
            }
        }
    }

    private func open() {
        MenuPanel.close()
        SchedulerWindow.show(scheduler, select: job.id)
    }

    /// "in 12:30" under a day away, else the day and time; what it waits for when it has no time.
    private var when: String {
        guard let next = job.next else { return job.when.event.title }
        let left = next.timeIntervalSince(now)
        if left <= 0 { return "Due now" }
        return left < 86_400 ? TimerText.countdown(left) : AlarmTime.short(next, now: now)
    }

    /// How far through its wait it is, for a schedule that repeats every so many minutes.
    private var fraction: Double? {
        guard job.when.kind == .every, let next = job.next else { return nil }
        let step = TimeInterval(max(1, job.when.minutes) * 60)
        return 1 - max(0, next.timeIntervalSince(now)) / step
    }

    private func help(_ action: SavedAction?) -> String {
        let clock24 = scheduler.prefs.settings.clock24
        var lines = ["\(job.name) · \(job.when.describe(clock24: clock24))", "Runs \(action.map { "\u{201C}\($0.name)\u{201D}" } ?? "no action yet")"]
        if let next = job.next { lines.append("Next: \(AlarmTime.short(next, now: now))") }
        if let last = job.lastRun {
            lines.append("Last ran \(AlarmTime.short(last, now: now))" + (job.lastOK == false ? ": it went wrong" : ""))
        }
        return lines.joined(separator: "\n") + "\n\nClick to open it in the Scheduler. Right-click to run it now, skip its next run or turn it off."
    }
}

// MARK: - The tags' boards

struct TagBoardsColumn: View {
    @ObservedObject var store: BoardStore

    var body: some View {
        VStack(spacing: MenuView.gap) {
            ForEach(NoteTag.allCases, id: \.self) { tag in
                TagBoardTile(tag: tag, count: store.tagged(tag).count, inMenuBar: store.isInMenuBar(BoardStore.dockID(tag)),
                             open: {
                                 MenuPanel.close()
                                 store.show(tag)
                             },
                             dock: { store.setInMenuBar($0, BoardStore.dockID(tag)) })
            }
        }
    }
}

/// A tag's board: its icon on its color, how many notes have the tag, and its name.
private struct TagBoardTile: View {
    let tag: NoteTag
    let count: Int
    let inMenuBar: Bool
    let open: () -> Void
    let dock: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tag.color.gradient)
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: tag.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(tag.color)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(.white))
                            .overlay(Capsule().strokeBorder(tag.color.opacity(0.5), lineWidth: 0.5))
                            .offset(x: 6, y: -5)
                    }
                }
                .scaleEffect(hover ? 1.06 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                Text(tag.title)
                    .font(.system(size: 12, weight: hover ? .semibold : .medium))
                    .foregroundStyle(hover ? AnyShapeStyle(tag.color) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            .frame(width: MenuView.bigTile, height: 78)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? tag.color.opacity(0.14) : .clear))
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("\(tag.help). \(count == 0 ? "No notes yet" : count == 1 ? "1 note" : "\(count) notes"). Right-click to \(inMenuBar ? "take it out of" : "dock it in") the menu bar.")
        .contextMenu {
            Button("Open \(tag.title)", action: open)
            Button(inMenuBar ? "Take out of the menu bar" : "Dock in the menu bar (beside the wrench)") { dock(!inMenuBar) }
        }
    }
}

// MARK: - The notes docked along the bottom

/// The notes docked along the bottom of the panel, across all its columns: a small icon each, on
/// the note's color, with its title. Shown only when one is docked.
struct DockRow: View {
    @ObservedObject var store: BoardStore

    var body: some View {
        let notes = store.docked
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Docked notes · \(notes.count)", color: Tools.dockColor)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 66, maximum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(notes) { note in
                            DockedNoteTile(note: note, timer: store.upcoming.first { $0.id == note.id }?.spec,
                                           open: {
                                               MenuPanel.close()
                                               store.show(note.board.id, focus: note.index)
                                           },
                                           pin: {
                                               MenuPanel.close()
                                               store.setPinned(!store.isPinned(note.board, note.index), note.board, note.index)
                                           },
                                           undock: { store.setDocked(false, note.board, note.index) })
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }
}

private struct DockedNoteTile: View {
    let note: BoardStore.Note
    /// The timer it's running, if any (a badge on its icon).
    let timer: TimerSpec?
    let open: () -> Void
    let pin: () -> Void
    let undock: () -> Void
    @State private var hover = false

    var body: some View {
        let colors = NoteLook.colors(tint: note.tint, board: note.board)
        Button(action: open) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(colors.fill)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(note.board.color.opacity(0.45), lineWidth: 1))
                    .overlay(Image(systemName: note.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.ink))
                    .frame(width: 30, height: 30)
                    .overlay(alignment: .bottomTrailing) {
                        if let timer {
                            Image(systemName: TimerLook.of(timer).symbol)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 13, height: 13)
                                .background(Circle().fill(Tools.timersColor))
                                .offset(x: 4, y: 3)
                        }
                    }
                    .scaleEffect(hover ? 1.08 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                Text(note.title ?? note.place)
                    .font(.system(size: 9.5, weight: hover ? .semibold : .medium))
                    .foregroundStyle(hover ? AnyShapeStyle(note.board.color) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            .frame(minWidth: 66, maxWidth: 80)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help("\(note.title ?? "Untitled") · \(note.place)\n\nClick to open it. Right-click to pin or undock it.")
        .contextMenu {
            Button("Open", action: open)
            Button("Pin / unpin on the screen", action: pin)
            Divider()
            Button("Undock", action: undock)
        }
    }
}

/// How many things a board holds: a small white capsule with the number, in the board's color.
struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .background(Capsule().fill(.white))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
    }
}
