import AppKit
import SwiftUI
import ToolCore

// The Scheduler's window: a glass panel as big as the diagram's, its jobs down the left (the
// built-in chimes first) and the one you pick on the right: the action it runs (made in Actions)
// and the values it gives that action's arguments, when it runs (or what it waits for), what
// happens with the result, and what happened each time it ran.

@MainActor
enum SchedulerWindow {
    static let margin: CGFloat = 24
    static let focus = Focus()

    final class Focus: ObservableObject {
        @Published var selected: String?
    }

    static func show(_ scheduler: Scheduler, select: String? = nil) {
        if let select { focus.selected = select }
        if focus.selected == nil { focus.selected = scheduler.book.jobs.first?.id }
        Windows.show("scheduler") {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size)
            panel.level = .floating
            let close = { panel.orderOut(nil) }
            let host = FirstClickHostingView(rootView: SchedulerView(scheduler: scheduler, focus: focus, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close, "n": { focus.selected = scheduler.add() }]
            panel.onEscape = {
                close()
                return true
            }
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        if let panel = Windows.window("scheduler") { GlassPanel.fit(panel) }
        scheduler.loadModels()
    }
}

struct SchedulerView: View {
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var focus: SchedulerWindow.Focus
    let close: () -> Void
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @Environment(\.controlActiveState) private var active

    var mood: GlassMood { scheduler.problem != nil ? .error : scheduler.running.isEmpty ? .idle : .thinking }
    var still: Bool { mood == .idle && active == .inactive }

    var status: String {
        if let problem = scheduler.problem { return problem }
        let on = scheduler.book.jobs.filter(\.enabled).count
        if !scheduler.running.isEmpty { return "Running \(scheduler.running.count)…" }
        return scheduler.book.jobs.isEmpty ? "Scheduler" : "Scheduler · \(on) of \(scheduler.book.jobs.count) on"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 9) {
                    StatusDot(kind: scheduler.problem != nil ? .trouble : scheduler.running.isEmpty ? .ready : .thinking, hue: ink)
                    Text(status).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, 8)
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .help("Drag to move")
                PillButton(title: "Actions") { ActionsWindow.show(scheduler) }
                    .help("What schedules run: make and change actions there")
                PillButton(title: "New schedule", prominent: true) { focus.selected = scheduler.add() }
                    .help("A new schedule (⌘N)")
                GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
                    .padding(.leading, 4)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 18) {
                jobList
                    .frame(width: 340)
                Group {
                    if let id = focus.selected, let job = scheduler.binding(id) {
                        JobEditor(job: job, scheduler: scheduler, ink: ink) { focus.selected = $0 }
                            .id(id)
                    } else {
                        empty
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(maxHeight: .infinity)
            GlowLine(clock: clock, mood: mood, paused: still)
                .padding(.horizontal, 26)
            HStack(spacing: 8) {
                Text("Jobs run while Tool Mac Tool is open (it starts at login). One missed by over an hour, while the Mac slept or the app was closed, waits for its next time.")
                    .lineLimit(2)
                Spacer()
                KeyHint(key: "⌘N", does: "new")
                KeyHint(key: "esc", does: "close")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
        }
        .background(GlassCard(clock: clock, mood: mood, paused: still, radius: 30))
        .padding(SchedulerWindow.margin)
        .environment(\.colorScheme, .dark)
        .onChange(of: scheduler.running) { running in
            if running.isEmpty { clock.ripple(x: 0.5, y: 0.5, power: 0.7) } else { ink = clock.frame.hue }
        }
    }

    var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(scheduler.book.jobs) { job in
                    JobRow(job: job, action: scheduler.action(job.actionID), selected: focus.selected == job.id,
                           running: scheduler.running.contains(job.id), clock24: scheduler.prefs.settings.clock24,
                           toggle: { on in
                               // Asks first, saying what turning it on or off means.
                               guard Confirm.schedule(job, doing: scheduler.doing(job), on: on, clock24: scheduler.prefs.settings.clock24) else { return }
                               var j = job
                               j.enabled = on
                               scheduler.update(j)
                           })
                        .onTapGesture { focus.selected = job.id }
                }
            }
            .padding(.vertical, 4)
        }
    }

    var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Ink.reply(ink))
            Text(scheduler.book.jobs.isEmpty ? "Nothing scheduled yet" : "Pick a schedule")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.reply(ink))
            Text("A schedule runs an action (made in Actions) at the times you set or when something happens (an alarm, the battery, a day's count over a limit, the month starting), giving it the values its arguments need.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            PillButton(title: "New schedule", prominent: true) { focus.selected = scheduler.add() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A job in the list: its action's icon, when, when it runs next (or what it waits for), and its switch.
struct JobRow: View {
    let job: ScheduledJob
    let action: SavedAction?
    let selected: Bool
    let running: Bool
    let clock24: Bool
    let toggle: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: action?.symbol ?? "questionmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(JobRow.color(action?.steps.first?.kind ?? .remind).opacity(job.enabled && action != nil ? 0.85 : 0.3)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(job.name.isEmpty ? "Untitled" : job.name)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(job.enabled ? 0.95 : 0.55))
                        .lineLimit(1)
                    if job.isBuiltin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .help("Built in: it can be turned off and its hours changed, not deleted")
                    }
                }
                Text(job.when.describe(clock24: clock24) + " · " + (action?.name ?? "no action picked"))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if running {
                        ProgressView().controlSize(.mini)
                        Text("Running…")
                    } else if job.enabled, let next = job.next {
                        Image(systemName: "clock")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Next in " + TimerText.left(next.timeIntervalSince(AppClock.time(at: context.date))))
                        }
                    } else if job.enabled, job.when.kind == .event, !job.when.event.isTimed {
                        Image(systemName: job.when.event.symbol)
                        Text("Waiting for it")
                    } else {
                        Text(job.enabled ? "Not again" : "Off")
                    }
                    if let ok = job.lastOK, !running {
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ok ? Color.green.opacity(0.8) : Color.orange)
                            .help(ok ? "The last run went fine" : "The last run failed")
                    }
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { job.enabled }, set: toggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(job.enabled ? "On: click to turn it off" : "Off: click to turn it on")
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(selected ? 0.14 : hover ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(selected ? 0.3 : 0.08), lineWidth: selected ? 1 : 0.5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    static func color(_ action: ScheduledJob.Action) -> Color {
        switch action {
        case .askModel: return Color(red: 0.55, green: 0.4, blue: 1)
        case .remind: return Color(red: 0.2, green: 0.7, blue: 0.36)
        case .speak: return Color(red: 0.1, green: 0.6, blue: 0.85)
        case .tool: return Color(red: 0.96, green: 0.56, blue: 0.1)
        case .shortcut: return Color(red: 0.93, green: 0.3, blue: 0.45)
        case .webhook: return Color(red: 0.2, green: 0.62, blue: 0.62)
        case .chime: return Color(red: 0.9, green: 0.3, blue: 0.62)
        case .runAction: return Color(red: 0.45, green: 0.5, blue: 0.95)
        }
    }
}

/// Lays its views out left to right, wrapping onto a new line when one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + lineSpacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// One job, to edit: its name, the action it runs and the values it gives that action's
/// arguments, when, what happens with the result, and its history. A built-in job's name and
/// action stay as they are.
struct JobEditor: View {
    @Binding var job: ScheduledJob
    @ObservedObject var scheduler: Scheduler
    let ink: Double
    let select: (String?) -> Void

    var settings: AppSettings { scheduler.prefs.settings }
    var runs: [JobRun] { scheduler.book.runs(of: job.id) }
    var running: Bool { scheduler.running.contains(job.id) }
    var action: SavedAction? { scheduler.action(job.actionID) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        TextField("Name", text: $job.name, prompt: Text("Name it").foregroundColor(.white.opacity(0.3)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Ink.reply(ink))
                            .disabled(job.isBuiltin)
                        if job.isBuiltin {
                            Label("Built in", systemImage: "lock.fill")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 9)
                                .frame(height: 22)
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .help("Built in: on from the start. Turn it off or change its hours; it can't be deleted.")
                        }
                    }
                    section("The action it runs") { actionRow }
                    if let action, !action.parameters.filter({ !$0.name.isEmpty }).isEmpty {
                        section("Its arguments") {
                            VStack(alignment: .leading, spacing: 8) {
                                ArgumentFields(parameters: action.parameters, given: $job.arguments)
                                Text("Empty: the action's own value. They can hold {{…}}: {{date}}, {{time}}, {{last}} (what it gave back last time), {{event}} and the rest of the Scheduler's placeholders.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                    }
                    section("When") { WhenEditor(when: $job.when, clock24: settings.clock24) }
                    if !scheduler.isChime(job) {
                        section("With the result") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 18) {
                                    Toggle("Show it on a card", isOn: $job.showResult)
                                    Toggle("Say it out loud", isOn: $job.speakResult)
                                }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.8))
                                Text("When the action ends with an answer (the model's, a shortcut's, a web address's): a reminder or a spoken step has already been shown or said.")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                    }
                    actions
                }
                .padding(.vertical, 4)
                .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity)
            history
                .frame(width: 340)
        }
    }

    // MARK: The action

    var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if job.isBuiltin {
                    PillButton(title: action?.name ?? "Chime", prominent: true) {}
                } else {
                    MenuPill(title: action?.name ?? (job.actionID.isEmpty ? "Pick an action" : "Its action is gone: pick another"),
                             help: "The action it runs (make and change them in Actions)",
                             items: scheduler.actions.actions.map { a -> (String, Bool, () -> Void) in
                                 (a.name, job.actionID == a.id, {
                                     job.actionID = a.id
                                     job.arguments = a.arguments(keeping: job.arguments)
                                 })
                             })
                    PillButton(title: "New action…") {
                        let id = scheduler.addAction(SavedAction(name: job.name.isEmpty ? "New action" : job.name,
                                                                 steps: [ActionStep(kind: .remind)]))
                        job.actionID = id
                        job.arguments = []
                        ActionsWindow.show(scheduler, select: id)
                    }
                    .help("A new action for this schedule to run, opened in Actions")
                }
                if let action {
                    PillButton(title: "Open in Actions") { ActionsWindow.show(scheduler, select: action.id) }
                        .help("See or change what it does")
                }
            }
            if let action {
                Text(action.summary + (scheduler.book.jobs(running: action.id).count > 1 ? " · other schedules run it too" : ""))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
    }

    static func isWebAddress(_ text: String) -> Bool {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && u.host?.isEmpty == false
    }

    // MARK: Run, copy, delete

    var actions: some View {
        HStack(spacing: 8) {
            PillButton(title: running ? "Running…" : "Run now", prominent: true) { scheduler.run(job.id, byHand: true) }
                .disabled(running)
                .help("Run it now (its schedule stays as it is)")
            PillButton(title: "Duplicate") { select(scheduler.duplicate(job.id)) }
            if job.isBuiltin {
                PillButton(title: "Reset") { scheduler.reset(job.id) }
                    .help("Back to how it came: on, at its hours")
            } else {
                PillButton(title: "Delete") {
                    let id = job.id
                    let next = scheduler.book.jobs.first { $0.id != id }?.id
                    select(next)
                    scheduler.delete(id)
                }
            }
            Spacer()
            Group {
                if job.enabled, let next = job.next {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let now = AppClock.time(at: context.date)
                        Text("Next: in " + TimerText.left(next.timeIntervalSince(now)) + " · " + AlarmTime.short(next, now: now))
                    }
                } else if job.enabled, job.when.kind == .event, !job.when.event.isTimed {
                    Text("Waiting: " + job.when.describe(clock24: settings.clock24))
                } else {
                    Text(job.enabled ? "Won't run again (its time has passed)" : "Off")
                }
            }
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: History

    var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if !runs.isEmpty {
                    ActionChip(title: "Clear", symbol: "trash", help: "Forget this schedule's runs") { scheduler.clearHistory(job.id) }
                }
            }
            if runs.isEmpty {
                Text(running ? "Running for the first time…" : "Nothing yet. Each time it runs, what it gave back (or what went wrong) shows here.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(runs) { run in RunRow(run: run, ink: ink) }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
    }

    @ViewBuilder func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }
}

/// One run in the history: when, how it went, which tools it used, and what it gave back.
struct RunRow: View {
    let run: JobRun
    let ink: Double
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: run.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(run.ok ? Color.green.opacity(0.8) : Color.orange)
                Text(run.at, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                Spacer()
                CopyButton(text: run.output)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            if !run.tools.isEmpty {
                Text("Used: " + run.tools.joined(separator: ", "))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text(run.output)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(run.ok ? Ink.prompt(ink) : Color(red: 1, green: 0.75, blue: 0.78))
                .lineLimit(open ? nil : 4)
                .textSelection(.enabled)
                .onTapGesture(count: 2) { open.toggle() }
            if run.output.count > 220 {
                Button(open ? "Less" : "More") { open.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.15)))
    }
}

/// When a job runs: once at a date and time, every so many minutes, hours or days, at a time of
/// day on the weekdays you pick, every hour through the hours you pick, or when something happens.
struct WhenEditor: View {
    @Binding var when: Schedule
    let clock24: Bool

    enum Unit: String, CaseIterable {
        case minutes, hours, days
        var size: Int { self == .minutes ? 1 : self == .hours ? 60 : 1440 }
    }

    var unit: Unit {
        if when.minutes % 1440 == 0 { return .days }
        if when.minutes % 60 == 0 { return .hours }
        return .minutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Schedule.Kind.allCases, id: \.self) { k in
                    PillButton(title: k.title, prominent: when.kind == k) {
                        guard when.kind != k else { return }
                        when.kind = k
                        if k == .every { when.start = AppClock.now() }
                        if k == .once, when.at < AppClock.now() { when.at = AppClock.now().addingTimeInterval(3600) }
                    }
                }
            }
            switch when.kind {
            case .once:
                DatePicker("On", selection: $when.at, in: AppClock.now()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .fixedSize()
            case .every:
                HStack(spacing: 8) {
                    Text("Every")
                    TextField("", value: Binding(get: { max(1, when.minutes / unit.size) },
                                                 set: { n in
                                                     when.minutes = max(1, n) * unit.size
                                                     when.start = AppClock.now()
                                                 }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    MenuPill(title: unit.rawValue, help: "Minutes, hours or days",
                             items: Unit.allCases.map { u in
                                 (u.rawValue, u == unit, {
                                     when.minutes = max(1, when.minutes / unit.size) * u.size
                                     when.start = AppClock.now()
                                 })
                             })
                    Text("starting from now")
                        .foregroundStyle(.white.opacity(0.45))
                }
            case .daily:
                HStack(spacing: 8) {
                    Text("At")
                    DatePicker("", selection: timeOfDay, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .fixedSize()
                    Text("on")
                    ForEach(Schedule.week, id: \.self) { d in
                        let on = when.weekdays.contains(d)
                        DayChip(title: Schedule.dayNames[d - 1], on: on, all: when.weekdays.isEmpty, width: 38) {
                            if on { when.weekdays.removeAll { $0 == d } } else { when.weekdays.append(d) }
                        }
                    }
                }
                Text(when.weekdays.isEmpty ? "No days picked: every day." : when.describe(clock24: clock24))
                    .foregroundStyle(.white.opacity(0.45))
            case .hourly:
                hourly
            case .event:
                event
            }
        }
        .font(.system(size: 12.5, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: Every hour

    var hourly: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("At")
                Stepper(value: Binding(get: { when.minute }, set: { when.minute = min(59, max(0, $0)) }), in: 0...59, step: 5) {
                    Text(String(format: ":%02d", when.minute)).monospacedDigit().frame(minWidth: 30)
                }
                .fixedSize()
                Text("past the hour, in these hours:")
                Spacer().frame(width: 10)
                PillButton(title: "Day (6–22)", prominent: Set(when.hours) == Set(Schedule.dayHours)) { when.hours = Schedule.dayHours }
                PillButton(title: "Night (23–5)", prominent: Set(when.hours) == Set(Schedule.nightHours)) { when.hours = Schedule.nightHours }
                PillButton(title: "All day", prominent: when.hours.isEmpty) { when.hours = [] }
            }
            ForEach([0, 12], id: \.self) { first in
                HStack(spacing: 4) {
                    ForEach(first..<(first + 12), id: \.self) { h in
                        let on = when.hours.contains(h)
                        DayChip(title: clock24 ? String(format: "%02d", h) : TimerText.hourLabel(h).replacingOccurrences(of: " ", with: ""),
                                on: on, all: when.hours.isEmpty, width: 44) {
                            if on { when.hours.removeAll { $0 == h } } else { when.hours = (when.hours + [h]).sorted() }
                        }
                    }
                }
            }
            Text(when.describe(clock24: clock24) + (when.hours.isEmpty ? " (no hours picked: all of them)" : ""))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: An event

    var event: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("When")
                MenuPill(title: when.event.title, help: "What it waits for", items: eventItems)
                switch when.event {
                case .batteryAt:
                    Stepper(value: Binding(get: { when.level }, set: { when.level = min(100, max(0, $0)) }), in: 0...100, step: 10) {
                        Text(when.level <= 0 ? "empty" : "\(when.level)%").monospacedDigit().frame(minWidth: 44)
                    }
                    .fixedSize()
                    .help("The battery passes each 10% on its way down, and can be set to 100, 80, 60, 40, 20 or 0")
                case .countOver:
                    MenuPill(title: when.metric.words, help: "What's counted",
                             items: ThresholdRule.Metric.allCases.map { m in (m.words, m == when.metric, { when.metric = m }) })
                    Text("in a day go over")
                    Stepper(value: Binding(get: { when.limit }, set: { when.limit = min(999, max(0, $0)) }), in: 0...999) {
                        Text("\(when.limit)").monospacedDigit().frame(minWidth: 30)
                    }
                    .fixedSize()
                case .startOfWeek, .endOfWeek, .startOfMonth, .endOfMonth:
                    Text("at")
                    DatePicker("", selection: timeOfDay, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .fixedSize()
                default:
                    EmptyView()
                }
            }
            Text(Self.eventHelp(when))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The events, under their groups' headings.
    var eventItems: [(String, Bool, () -> Void)] {
        var items: [(String, Bool, () -> Void)] = []
        for group in ScheduleEvent.groups {
            items.append((MenuPill.heading + group.title, false, {}))
            for e in group.events {
                let pick: () -> Void = { when.event = e }
                items.append((e.title, e == when.event, pick))
            }
        }
        return items
    }

    static func eventHelp(_ when: Schedule) -> String {
        switch when.event {
        case .alarmSet: return "Each time a timer or a due date is set on a note. {{event}} says which."
        case .alarmRang: return "Each time a note's countdown reaches zero, a repeating one finishes a round, a snooze is up or a due date comes."
        case .alarmSnoozed: return "Each time an alarm is snoozed."
        case .alarmStopped: return "Each time a note's timer is stopped by hand."
        case .alarmDismissed: return "Each time OK is clicked on an alarm's card."
        case .batteryAt: return when.level <= 0 ? "When the battery runs out." : "When the battery passes \(when.level)% on its way down, or is set to it."
        case .batteryChange: return "When the battery is set, passes each 10% on the way down, or runs out (what the timer log's battery signals sent)."
        case .chime: return "Each time the day chime or the night watch (or a chime of your own) sounds."
        case .countOver: return "The moment the day's count goes over the limit: once a day at most. With Remind me it comes up big in the middle of the screen, as the timer log's thresholds did."
        case .thresholdCrossed: return "Each time any schedule's count goes over its limit."
        case .startOfWeek: return "Every Monday at this time."
        case .endOfWeek: return "Every Sunday at this time."
        case .startOfMonth: return "On the 1st of each month at this time."
        case .endOfMonth: return "On the last day of each month at this time."
        case .appLaunch: return "A couple of seconds after Tool Mac Tool starts (at login, after an update)."
        case .macWake: return "When the Mac wakes from sleep."
        }
    }

    /// The hour and minute as a date today, for the time picker.
    var timeOfDay: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: when.hour, minute: when.minute, second: 0, of: AppClock.now()) ?? AppClock.now()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            when.hour = c.hour ?? 9
            when.minute = c.minute ?? 0
        })
    }
}

/// A day or an hour to pick: white when picked, half-lit when none are (all of them count).
private struct DayChip: View {
    let title: String
    let on: Bool
    let all: Bool
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(on || all ? Color.black.opacity(0.85) : Color.white.opacity(0.7))
                .frame(width: width, height: 24)
                .background(Capsule().fill(on ? Color.white.opacity(0.88) : all ? Color.white.opacity(0.45) : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
