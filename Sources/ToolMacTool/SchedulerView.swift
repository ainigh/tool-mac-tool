import AppKit
import SwiftUI
import ToolCore

// The Scheduler's window: a glass panel as big as the diagram's, its jobs down the left and the
// one you pick on the right: what it does, its text, when it runs, what happens with the result,
// and what happened each time it ran.

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
                    JobRow(job: job, selected: focus.selected == job.id, running: scheduler.running.contains(job.id),
                           clock24: scheduler.prefs.settings.clock24,
                           toggle: { on in
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
            Text("A schedule takes some text and, at the times you set, asks the model with it (the model can use the model tools and your shortcuts), shows it as a reminder, says it, or hands it to a model tool or a shortcut.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            PillButton(title: "New schedule", prominent: true) { focus.selected = scheduler.add() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A job in the list: what it does, when, when it runs next, and its switch.
struct JobRow: View {
    let job: ScheduledJob
    let selected: Bool
    let running: Bool
    let clock24: Bool
    let toggle: (Bool) -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: job.action.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(JobRow.color(job.action).opacity(job.enabled ? 0.85 : 0.3)))
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name.isEmpty ? "Untitled" : job.name)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(job.enabled ? 0.95 : 0.55))
                    .lineLimit(1)
                Text(job.when.describe(clock24: clock24))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if running {
                        ProgressView().controlSize(.mini)
                        Text("Running…")
                    } else if job.enabled, let next = job.next {
                        Image(systemName: "clock")
                        Text("Next ") + Text(next, style: .relative)
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
        }
    }
}

/// One job, to edit: its name, what it does and with which text, when, what happens with the
/// result, and its history.
struct JobEditor: View {
    @Binding var job: ScheduledJob
    @ObservedObject var scheduler: Scheduler
    let ink: Double
    let select: (String?) -> Void
    @State private var shortcuts: [String] = []

    var settings: AppSettings { scheduler.prefs.settings }
    var runs: [JobRun] { scheduler.book.runs(of: job.id) }
    var running: Bool { scheduler.running.contains(job.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("Name", text: $job.name, prompt: Text("Name it").foregroundColor(.white.opacity(0.3)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.reply(ink))
                    section("What it does") { whatRow }
                    section(textTitle) {
                        VStack(alignment: .leading, spacing: 8) {
                            GlassEditor(text: $job.text, hint: textHint, ink: ink)
                                .frame(minHeight: 130, maxHeight: 220)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.18)))
                            HStack(spacing: 6) {
                                Text("Insert:")
                                ForEach(JobText.placeholders, id: \.self) { p in
                                    ActionChip(title: p, symbol: "plus", help: Self.placeholderHelp(p)) {
                                        job.text += (job.text.isEmpty || job.text.hasSuffix(" ") ? "" : " ") + p
                                    }
                                }
                            }
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    section("When") { WhenEditor(when: $job.when, clock24: settings.clock24) }
                    if job.action.hasResult {
                        section("With the result") {
                            HStack(spacing: 18) {
                                Toggle("Show it on a card", isOn: $job.showResult)
                                Toggle("Say it out loud", isOn: $job.speakResult)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
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
        .task(id: job.action) {
            if job.action == .shortcut, shortcuts.isEmpty {
                shortcuts = (try? await ShortcutRunner.list()) ?? []
            }
        }
    }

    // MARK: What it does

    var whatRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ScheduledJob.Action.allCases, id: \.self) { a in
                    PillButton(title: a.title, prominent: job.action == a) {
                        guard job.action != a else { return }
                        job.action = a
                        job.target = Self.defaultTarget(a, settings: settings)
                    }
                    .help(Self.actionHelp(a))
                }
            }
            HStack(spacing: 10) {
                switch job.action {
                case .askModel:
                    MenuPill(title: job.target.isEmpty ? "Chat's model (\(ModelMenu.shortName(settings.model.isEmpty ? "none" : settings.model)))"
                                                       : ModelMenu.shortName(job.target),
                             help: "The model that answers",
                             items: modelItems)
                    Toggle("Can use the model tools and your shortcuts", isOn: $job.useTools)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!settings.toolsOn)
                        .help(settings.toolsOn ? "It may call the tools turned on in Model tools and Shortcuts (not close the chat; a shortcut set to ask first isn't run)"
                                               : "Tools are turned off in Model tools")
                case .tool:
                    MenuPill(title: modelTools.first { $0.name == job.target }?.kind.title ?? "Pick a tool",
                             help: "The model tool it runs, with the text",
                             items: modelTools.map { t -> (String, Bool, () -> Void) in
                                 (t.kind.title, job.target == t.name, { job.target = t.name })
                             })
                case .shortcut:
                    MenuPill(title: job.target.isEmpty ? "Pick a shortcut" : job.target,
                             help: "The shortcut it runs, with the text as its input",
                             items: shortcutNames.map { n -> (String, Bool, () -> Void) in
                                 (n, job.target == n, { job.target = n })
                             })
                    if shortcutNames.isEmpty { Text("No shortcuts found yet").foregroundStyle(.white.opacity(0.5)) }
                case .remind, .speak:
                    EmptyView()
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    var modelItems: [(String, Bool, () -> Void)] {
        let chat: (String, Bool, () -> Void) = ("The chat's model" + (settings.model.isEmpty ? "" : " (\(settings.model))"),
                                                job.target.isEmpty, { job.target = "" })
        return [chat] + scheduler.models.map { m -> (String, Bool, () -> Void) in (m, job.target == m, { job.target = m }) }
    }

    /// The model tools a job can run (not closing the chat).
    var modelTools: [BuiltinTool] { settings.builtins.filter { $0.kind != .closeWindow } }

    /// Your shortcuts: the ones the Shortcuts app has, and the ones set up for the model.
    var shortcutNames: [String] { Array(Set(shortcuts + settings.shortcuts.map(\.shortcut))).sorted() }

    static func defaultTarget(_ action: ScheduledJob.Action, settings: AppSettings) -> String {
        switch action {
        case .tool: return BuiltinTool.Kind.soundAlarm.rawValue
        case .shortcut: return settings.shortcuts.first?.shortcut ?? ""
        default: return ""
        }
    }

    static func actionHelp(_ a: ScheduledJob.Action) -> String {
        switch a {
        case .askModel: return "The text is a prompt for the model, which may call tools. Its answer goes on a card or is read out."
        case .remind: return "The text comes up on a card that stays until you close it."
        case .speak: return "The text is read out in the voice from Read aloud."
        case .tool: return "One of the model tools (alarm, open a link, copy, draw a diagram) runs with the text."
        case .shortcut: return "One of your Apple Shortcuts runs with the text as its input; what it gives back can go on a card or be read out."
        }
    }

    var textTitle: String {
        switch job.action {
        case .askModel: return "The prompt"
        case .remind: return "The reminder"
        case .speak: return "What to say"
        case .tool, .shortcut: return "What it's given"
        }
    }

    var textHint: String {
        switch job.action {
        case .askModel: return "What should the model do? e.g. Look up tomorrow's weather and tell me whether to take an umbrella."
        case .remind: return "e.g. Drink some water."
        case .speak: return "e.g. Time for the stand-up."
        case .tool:
            switch BuiltinTool.Kind(rawValue: job.target) {
            case .soundAlarm: return "How many seconds the alarm sounds, e.g. 10"
            case .openURL: return "The web address, e.g. https://news.ycombinator.com"
            case .drawDiagram: return "What to draw"
            case .copyText: return "The text to put on the clipboard"
            default: return "What the tool is given"
            }
        case .shortcut: return "The shortcut's input (it can be empty)"
        }
    }

    static func placeholderHelp(_ p: String) -> String {
        switch p {
        case "{{date}}": return "Today's date when it runs"
        case "{{time}}": return "The time when it runs"
        case "{{last}}": return "What it gave back the last time it ran"
        default: return "What's on the clipboard when it runs"
        }
    }

    // MARK: Run, copy, delete

    var actions: some View {
        HStack(spacing: 8) {
            PillButton(title: running ? "Running…" : "Run now", prominent: true) { scheduler.run(job.id, byHand: true) }
                .disabled(running)
                .help("Run it now (its schedule stays as it is)")
            PillButton(title: "Duplicate") { select(scheduler.duplicate(job.id)) }
            PillButton(title: "Delete") {
                let id = job.id
                let next = scheduler.book.jobs.first { $0.id != id }?.id
                select(next)
                scheduler.delete(id)
            }
            Spacer()
            if job.enabled, let next = job.next {
                (Text("Next: ") + Text(next, style: .relative) + Text(" · ") + Text(next, style: .time))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text(job.enabled ? "Won't run again (its time has passed)" : "Off")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
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

/// When a job runs: once at a date and time, every so many minutes, hours or days, or at a time
/// of day on the weekdays you pick.
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
                        if k == .every { when.start = Date() }
                        if k == .once, when.at < Date() { when.at = Date().addingTimeInterval(3600) }
                    }
                }
            }
            switch when.kind {
            case .once:
                DatePicker("On", selection: $when.at, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .fixedSize()
            case .every:
                HStack(spacing: 8) {
                    Text("Every")
                    TextField("", value: Binding(get: { max(1, when.minutes / unit.size) },
                                                 set: { n in
                                                     when.minutes = max(1, n) * unit.size
                                                     when.start = Date()
                                                 }),
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    MenuPill(title: unit.rawValue, help: "Minutes, hours or days",
                             items: Unit.allCases.map { u in
                                 (u.rawValue, u == unit, {
                                     when.minutes = max(1, when.minutes / unit.size) * u.size
                                     when.start = Date()
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
                        Button {
                            if on { when.weekdays.removeAll { $0 == d } } else { when.weekdays.append(d) }
                        } label: {
                            Text(Schedule.dayNames[d - 1])
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(on || when.weekdays.isEmpty ? Color.black.opacity(0.85) : Color.white.opacity(0.7))
                                .frame(width: 38, height: 24)
                                .background(Capsule().fill(on ? Color.white.opacity(0.88)
                                                              : when.weekdays.isEmpty ? Color.white.opacity(0.45) : Color.white.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(when.weekdays.isEmpty ? "No days picked: every day." : when.describe(clock24: clock24))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 12.5, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
    }

    /// The hour and minute as a date today, for the time picker.
    var timeOfDay: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: when.hour, minute: when.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            when.hour = c.hour ?? 9
            when.minute = c.minute ?? 0
        })
    }
}
