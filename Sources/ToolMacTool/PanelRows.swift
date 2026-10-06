import AppKit
import SwiftUI
import ToolCore

// The panel's rows and columns of notes and boards: across the very top the Daily plan, the
// Boards button (every board, on a grid of its own) and the boards with notes (each in its own
// darker color, the one opened most lately first), the chimes' switches (built-in schedules) beside the Scheduler, the notes
// running a timer (docked in their column by themselves while it runs), the tags' boards, and the
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
        BoardTile(kind: kind, color: color ?? kind.color, help: help, inMenuBar: store.isInMenuBar(kind.id),
                  open: {
                      MenuPanel.close()
                      store.show(kind.id)
                  },
                  dock: { store.setInMenuBar($0, kind.id) })
    }
}

/// A board: its icon and name on its own color. Right-click to dock it in the menu bar.
private struct BoardTile: View {
    let kind: BoardStore.Kind
    let color: Color
    let help: String?
    let inMenuBar: Bool
    let open: () -> Void
    let dock: (Bool) -> Void
    @State private var hover = false

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
        .help("\(help ?? "\(kind.name): a board of notes.") Right-click to \(inMenuBar ? "take it out of" : "dock it in") the menu bar.")
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
                Text(job?.name ?? (builtin == .dayChime ? "Day chime" : "Night watch"))
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

    private func status(_ job: ScheduledJob?) -> String {
        guard let job, job.enabled else { return "Off" }
        guard let next = job.next else { return "On" }
        return "Next \(TimerText.hourLabel(Calendar.current.component(.hour, from: next)))"
    }

    private func help(_ job: ScheduledJob?, on: Bool) -> String {
        let what = builtin == .dayChime
            ? "A ding and a card every hour through the day, with hours since 6 AM and to 10 PM."
            : "A ding and a warning card every hour through the night, with the hours left before 6 AM."
        let when = job.map { $0.when.describe(clock24: scheduler.prefs.settings.clock24) } ?? ""
        return "\(job?.name ?? "") (a built-in schedule: \(when))\n\n\(what)\n\n\(on ? "On: click to turn it off (it asks first)." : "Off: click to turn it on (it asks first).") Right-click to change its hours in the Scheduler."
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
        .help("\(tag.help). \(count == 1 ? "1 note" : "\(count) notes"). Right-click to \(inMenuBar ? "take it out of" : "dock it in") the menu bar.")
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
                    SectionHeader(title: "Docked notes", color: Tools.dockColor)
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
