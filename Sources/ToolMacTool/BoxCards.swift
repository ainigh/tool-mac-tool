import AppKit
import SwiftUI
import ToolCore

// The big glass cards a box's timer puts on screen: a reminder on the way down, time's up, a
// round done, a due date come. Each waits for OK, and has the box's text at the bottom to read
// and edit right there (it's the box's own text: what you type shows in the box too).

/// The box a card is for, and what its OK does.
struct BoxCardContext {
    let store: BoardStore
    let model: BoardModel
    let board: BoardStore.Kind
    let index: Int
    let spec: TimerSpec
    let look: TimerLook
    let ok: () -> Void

    /// "Goals · box 3 · Timer 1".
    var name: String { "\(board.name) · box \(index + 1) · \(spec.name)" }
}

struct BoxAlarmCard: View {
    enum Moment {
        /// On the way down.
        case reminder
        /// A countdown at zero (rung again after its snooze, or not), and when.
        case done(snoozed: Bool, at: Date)
        /// A repeating countdown at zero, for the nth time.
        case round(Int)
        /// A due date come.
        case due(snoozed: Bool)
    }

    let size: NSSize
    let box: BoxCardContext
    @ObservedObject var model: BoardModel
    let moment: Moment

    var body: some View {
        let h = max(34, size.height * 0.09)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            BigCard(size: size, symbol: symbol, accent: box.look.accent, name: name, headline: headline(AppClock.time(at: context.date)),
                    line: line(AppClock.time(at: context.date)), mood: mood, close: box.ok) {
                VStack(spacing: size.height * 0.025) {
                    BoxNote(text: $model.board.boxes[box.index].text, height: size.height * 0.24,
                            fontSize: max(13, size.height * 0.034))
                    HStack(spacing: 10) {
                        Button {
                            box.store.show(box.board.id, focus: box.index)
                        } label: {
                            Label("Open \(box.board.name)", systemImage: "square.grid.2x2")
                                .font(.system(size: max(11, h * 0.3), weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Open the board this box is on")
                        Spacer()
                        buttons(h)
                        BigButton(title: "OK", prominent: true, height: h, action: box.ok)
                    }
                }
            }
        }
    }

    private var alarm: BoxAlarm? { model.board.boxes[box.index].alarm }

    private var symbol: String {
        if case .reminder = moment { return box.look.symbol }
        return box.spec.kind == .deadline ? "calendar.badge.exclamationmark" : box.look.symbol
    }

    private var mood: GlassMood {
        switch moment {
        case .done, .due: return .error
        case .reminder, .round: return .idle
        }
    }

    private var name: String {
        let s = alarm?.state ?? TimerState()
        switch moment {
        case .reminder:
            if box.spec.kind == .deadline, let until = s.until {
                return "\(box.name) · \(until.formatted(date: .abbreviated, time: .shortened))"
            }
            return "\(box.name) · \(TimerText.duration(box.spec.duration(s) ?? 0))"
        case .done(_, let at):
            return "\(box.name) · \(TimerText.duration(box.spec.duration(s) ?? 0)) · done at \(at.formatted(date: .omitted, time: .shortened))"
        case .round:
            return "\(box.name) · every \(TimerText.duration(box.spec.duration(s) ?? 0))"
        case .due:
            return box.name
        }
    }

    private func headline(_ now: Date) -> String {
        switch moment {
        case .reminder:
            // What's left right now (it stays up until OK).
            guard let at = alarm?.nextRing(now: now) else { return "NOW" }
            return TimerText.span(at.timeIntervalSince(now))
        case .done: return "TIME'S UP"
        case .round(let n): return "ROUND \(n) DONE"
        case .due: return "DUE NOW"
        }
    }

    private func line(_ now: Date) -> String {
        let s = alarm?.state
        switch moment {
        case .reminder:
            return box.spec.kind == .deadline ? "until it's due" : "left until the alarm"
        case .done(let snoozed, _):
            return snoozed ? "Snoozed once already: click OK" : "Click OK to stop the alarm"
        case .round:
            if let s, case .holding(let left, _) = box.spec.phase(s, now: now) { return "next round in \(TimerText.clock(left))" }
            return "next round started"
        case .due(let snoozed):
            let when = s?.until.map { $0.formatted(date: .complete, time: .shortened) } ?? ""
            return snoozed ? "Snoozed once already · \(when)" : when
        }
    }

    @ViewBuilder private func buttons(_ h: CGFloat) -> some View {
        switch moment {
        case .reminder:
            BigButton(title: "Stop timer", symbol: "stop.fill", height: h) { box.store.stop(box.board, box.index) }
                .help("Stop \(box.spec.name) on this box")
        case .done:
            if box.store.canSnooze(box.board, box.index) {
                BigButton(title: "Snooze \(TimerText.duration(TimerSpec.snooze))", symbol: "zzz", height: h) {
                    box.store.snooze(box.board, box.index)
                }
                .help("Quiet for 3 minutes, then it rings again (once per countdown)")
            }
            BigButton(title: "Again", symbol: "arrow.counterclockwise", height: h) { box.store.restart(box.board, box.index) }
                .help("Start the same countdown again")
        case .round:
            if box.store.canSnooze(box.board, box.index) {
                BigButton(title: "Snooze \(TimerText.duration(TimerSpec.snooze))", symbol: "zzz", height: h) {
                    box.store.snooze(box.board, box.index)
                }
                .help("Quiet now, ring again in 3 minutes (once a round)")
            }
            BigButton(title: "Stop timer", symbol: "stop.fill", height: h) { box.store.stop(box.board, box.index) }
                .help("Stop \(box.spec.name): no more rounds")
        case .due:
            if box.store.canSnooze(box.board, box.index) {
                BigButton(title: "Snooze \(TimerText.duration(TimerSpec.snooze))", symbol: "zzz", height: h) {
                    box.store.snooze(box.board, box.index)
                }
                .help("Quiet for 3 minutes, then it rings again (once)")
            }
        }
    }
}

/// The box's text on a card: white on the glass, to edit as you would in the box.
struct BoxNote: View {
    @Binding var text: String
    let height: CGFloat
    let fontSize: CGFloat

    var body: some View {
        BoxEditor(text: $text, fontSize: fontSize, ink: NSColor(white: 1, alpha: 0.92),
                  linkInk: NSColor(red: 0.55, green: 0.8, blue: 1, alpha: 1))
            .padding(8)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .overlay(alignment: .topTrailing) {
                if text.isEmpty {
                    Text("The box is empty: type here")
                        .font(.system(size: fontSize * 0.8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - A note that comes round

/// The Note reminder a daily (or mornings, afternoons, evenings), weekly or monthly note puts up on
/// the hour (8 AM to 10 PM, or its part of the day) until it's completed: its title big, its text
/// to read and edit, and Pending (put away until the next hour) or Completed (until the next day,
/// week or month, each from 8 AM). It stays until one is clicked.
struct NoteReminderCard: View {
    let size: NSSize
    @ObservedObject var model: BoardModel
    let board: BoardStore.Kind
    let index: Int
    let hour: Date
    let pending: () -> Void
    let completed: () -> Void
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        let box = model.board.boxes[index]
        let h = max(34, size.height * 0.09)
        let repeats = box.repeats ?? .daily
        let accent = Color(red: 0.45, green: 0.85, blue: 0.6)
        BigCard(size: size, symbol: "bell.badge.fill", accent: accent,
                name: "Note reminder · \(repeats.title) · \(board.name) · box \(index + 1)",
                headline: box.title ?? "\(board.name) \(index + 1)",
                line: "\(hour.formatted(date: .omitted, time: .shortened)) · \(Self.line(repeats, status: box.status))",
                close: close) {
            VStack(spacing: size.height * 0.025) {
                BoxNote(text: $model.board.boxes[index].text, height: size.height * 0.2, fontSize: max(13, size.height * 0.032))
                HStack(spacing: 10) {
                    Button(action: open) {
                        Label("Open \(board.name)", systemImage: "square.grid.2x2")
                            .font(.system(size: max(11, h * 0.3), weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .help("Open the board this note is on")
                    Spacer()
                    BigButton(title: "Pending", symbol: "clock", height: h, action: pending)
                        .help("Not done yet: put this away, and it comes up again next hour")
                    BigButton(title: "Completed", symbol: "checkmark", prominent: true, height: h, action: completed)
                        .help("Done: no more reminders until \(repeats.until)")
                }
            }
        }
    }

    static func line(_ repeats: NoteRepeat, status: NoteStatus?) -> String {
        switch status {
        case .pending: return "pending · not completed \(repeats.current)"
        default: return "not completed \(repeats.current)"
        }
    }
}
