import AppKit
import SwiftUI
import ToolCore

// The Actions window: what schedules run, made here. A glass panel like the Scheduler's, the
// actions down the left (the built-in chimes first) and the one you pick on the right: its name,
// the arguments it takes (each with the value it has when none is given), its steps in order (ask
// the model, remind, say it, a model tool, a shortcut, a web address, a chime, add to a note, wait,
// or another action with arguments of its own), running it by hand, and what uses it. A step's
// text can use {{name}} for an argument and {{last}} for what the step before gave back. A step can
// be turned off (skipped) or copied; the list can be searched; ⌘R runs the action picked, ⌘D
// copies it.

@MainActor
enum ActionsWindow {
    static let focus = Focus()

    final class Focus: ObservableObject {
        @Published var selected: String?
    }

    static func show(_ scheduler: Scheduler, select: String? = nil) {
        if let select { focus.selected = select }
        if focus.selected == nil || scheduler.action(focus.selected) == nil {
            focus.selected = scheduler.actions.actions.first { !$0.isBuiltin }?.id ?? scheduler.actions.actions.first?.id
        }
        Windows.show("actions") {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size)
            panel.level = .floating
            let close = { panel.orderOut(nil) }
            let host = FirstClickHostingView(rootView: ActionsView(scheduler: scheduler, focus: focus, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = [
                "w": close,
                "n": { focus.selected = scheduler.addAction() },
                // The action picked: run it (its arguments' own values), or a copy of it.
                "r": { if let id = focus.selected { scheduler.runAction(id, arguments: []) } },
                "d": { if let id = focus.selected, let copy = scheduler.duplicateAction(id) { focus.selected = copy } },
            ]
            panel.onEscape = {
                close()
                return true
            }
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        if let panel = Windows.window("actions") { GlassPanel.fit(panel) }
        scheduler.loadModels()
    }
}

struct ActionsView: View {
    @ObservedObject var scheduler: Scheduler
    @ObservedObject var focus: ActionsWindow.Focus
    let close: () -> Void
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @State private var search = ""
    @Environment(\.controlActiveState) private var active

    var mood: GlassMood { scheduler.problem != nil ? .error : scheduler.runningActions.isEmpty ? .idle : .thinking }
    var still: Bool { mood == .idle && active == .inactive }

    var status: String {
        if let problem = scheduler.problem { return problem }
        if !scheduler.runningActions.isEmpty { return "Running \(scheduler.runningActions.count)…" }
        let unused = scheduler.actions.actions.filter { !$0.isBuiltin && scheduler.book.jobs(running: $0.id).isEmpty
            && scheduler.actions.callers(of: $0.id).isEmpty }.count
        return "Actions · \(scheduler.actions.actions.count)" + (unused > 0 ? " · \(unused) not run by anything" : "")
    }

    /// The actions the search finds (by name, step, argument or what a step says).
    var shown: [SavedAction] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return scheduler.actions.actions }
        return scheduler.actions.actions.filter { a in
            a.name.lowercased().contains(words) || a.summary.lowercased().contains(words)
                || a.parameters.contains { $0.name.lowercased().contains(words) }
                || a.steps.contains { $0.text.lowercased().contains(words) || $0.target.lowercased().contains(words) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 9) {
                    StatusDot(kind: scheduler.problem != nil ? .trouble : scheduler.runningActions.isEmpty ? .ready : .thinking, hue: ink)
                    Text(status).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, 8)
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .help("Drag to move")
                PillButton(title: "Open the Scheduler") { SchedulerWindow.show(scheduler) }
                    .help("Where actions are given times to run")
                PillButton(title: "New action", prominent: true) { focus.selected = scheduler.addAction() }
                    .help("A new action (⌘N)")
                GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
                    .padding(.leading, 4)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 18) {
                list
                    .frame(width: 320)
                Group {
                    if let id = focus.selected, let action = scheduler.actionBinding(id) {
                        ActionEditor(action: action, scheduler: scheduler, ink: ink) { focus.selected = $0 }
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
                Text("An action is steps done in turn. Give it arguments to use as {{name}} in its steps; {{last}} is what the step before gave back. Schedules pick an action to run, and a step can run another action.")
                    .lineLimit(2)
                Spacer()
                KeyHint(key: "⌘N", does: "new")
                KeyHint(key: "⌘R", does: "run")
                KeyHint(key: "⌘D", does: "copy")
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
        .onChange(of: scheduler.runningActions) { running in
            if running.isEmpty { clock.ripple(x: 0.5, y: 0.5, power: 0.7) } else { ink = clock.frame.hue }
        }
    }

    var list: some View {
        VStack(spacing: 10) {
            SearchField(text: $search, prompt: "Search the actions")
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(shown) { action in
                        ActionRow(action: action, selected: focus.selected == action.id,
                                  running: scheduler.runningActions.contains(action.id),
                                  uses: scheduler.book.jobs(running: action.id).count,
                                  last: scheduler.actionResults[action.id], ranAt: scheduler.actionRanAt[action.id])
                            .onTapGesture { focus.selected = action.id }
                            .contextMenu { menu(action) }
                    }
                    if shown.isEmpty {
                        Text(search.isEmpty ? "No actions yet" : "No action matches \u{201C}\(search)\u{201D}")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 20)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Right-click on an action in the list.
    @ViewBuilder func menu(_ action: SavedAction) -> some View {
        Button("Run now") { scheduler.runAction(action.id, arguments: []) }
            .disabled(scheduler.runningActions.contains(action.id) || action.live.isEmpty)
        Button("Duplicate") { focus.selected = scheduler.duplicateAction(action.id) }
        Button("Schedule it…") {
            let id = scheduler.add(ScheduledJob(name: action.name, enabled: false, when: Schedule(kind: .daily, hour: 9, minute: 0)),
                                   action: action.id)
            SchedulerWindow.show(scheduler, select: id)
        }
        if !action.isBuiltin, scheduler.book.jobs(running: action.id).isEmpty, scheduler.actions.callers(of: action.id).isEmpty {
            Divider()
            Button("Delete") {
                if focus.selected == action.id { focus.selected = scheduler.actions.actions.first { $0.id != action.id && !$0.isBuiltin }?.id }
                scheduler.deleteAction(action.id)
            }
        }
    }

    var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Ink.reply(ink))
            Text("Pick an action")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.reply(ink))
            Text("An action is steps done in turn: ask the model, remind, say it, run a model tool or a shortcut, call a web address, chime, or run other actions. Schedules run them at the times you set.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            PillButton(title: "New action", prominent: true) { focus.selected = scheduler.addAction() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An action in the list: its icon, name, steps in a few words, how many schedules run it, and
/// how its last run by hand went.
struct ActionRow: View {
    let action: SavedAction
    let selected: Bool
    let running: Bool
    let uses: Int
    var last: ActionRunner.Outcome?
    var ranAt: Date?
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: action.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(JobRow.color(action.steps.first?.kind ?? .remind).opacity(0.85)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(action.name.isEmpty ? "Untitled" : action.name)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                    if action.isBuiltin {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                            .help("Built in: what the built-in chimes run; it can't be changed or deleted")
                    }
                }
                Text(action.summary)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if running {
                        ProgressView().controlSize(.mini)
                        Text("Running…")
                    } else {
                        if !action.parameters.isEmpty {
                            Image(systemName: "curlybraces")
                            Text(action.parameters.map(\.name).joined(separator: ", ")).lineLimit(1)
                        }
                        Image(systemName: "calendar")
                        Text(uses == 0 ? "No schedule" : uses == 1 ? "1 schedule" : "\(uses) schedules")
                        if let last, let ranAt {
                            Image(systemName: last.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(last.ok ? Color.green.opacity(0.8) : Color.orange)
                            Text(ranAt, style: .relative)
                                .lineLimit(1)
                                .help(last.ok ? "Last run by hand went fine" : "Last run by hand failed: \(last.output)")
                        }
                    }
                }
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(selected ? 0.14 : hover ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(selected ? 0.3 : 0.08), lineWidth: selected ? 1 : 0.5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// One action, to edit: its name, its arguments, its steps, running it, and what uses it. A
/// built-in one is shown, not changed.
struct ActionEditor: View {
    @Binding var action: SavedAction
    @ObservedObject var scheduler: Scheduler
    let ink: Double
    let select: (String?) -> Void
    /// The values to run it with by hand.
    @State private var runWith: [ActionArgument] = []
    @State private var shortcuts: [String] = []

    var running: Bool { scheduler.runningActions.contains(action.id) }
    var jobs: [ScheduledJob] { scheduler.book.jobs(running: action.id) }
    var callers: [String] { scheduler.actions.callers(of: action.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    TextField("Name", text: $action.name, prompt: Text("Name it").foregroundColor(.white.opacity(0.3)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Ink.reply(ink))
                        .disabled(action.isBuiltin)
                    if action.isBuiltin {
                        Label("Built in", systemImage: "lock.fill")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .help("Built in: the built-in chimes run it. It can't be changed or deleted.")
                    }
                }
                if let loop = scheduler.actions.loop(from: action.id) {
                    Label("It comes round to itself (\(loop.joined(separator: " → "))): running it stops there with an error.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                }
                if action.isBuiltin {
                    EditorSection(title: "What it does") {
                        Text("The \(action.steps.first?.target == "night" ? "night watch's" : "day chime's") sound and card. Schedules can run it too.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    EditorSection(title: "Arguments") { parameters }
                    EditorSection(title: action.steps.count == 1 ? "Its step" : "Its steps, in turn") { steps }
                }
                EditorSection(title: "Run it now") { runNow }
                EditorSection(title: "Used by") { usedBy }
                HStack(spacing: 8) {
                    PillButton(title: "Duplicate") { select(scheduler.duplicateAction(action.id)) }
                    PillButton(title: "Schedule it…") {
                        let id = scheduler.add(ScheduledJob(name: action.name, enabled: false, when: Schedule(kind: .daily, hour: 9, minute: 0)),
                                               action: action.id)
                        SchedulerWindow.show(scheduler, select: id)
                    }
                    .help("A new schedule (off until you set it) that runs this action, in the Scheduler")
                    if !action.isBuiltin {
                        PillButton(title: "Delete") { delete() }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
        }
        .task {
            if shortcuts.isEmpty { shortcuts = (try? await ShortcutRunner.list()) ?? [] }
        }
    }

    // MARK: Arguments

    var parameters: some View {
        VStack(alignment: .leading, spacing: 8) {
            if action.parameters.isEmpty {
                Text("None. An argument is a name for a value given each time it runs (by a schedule, or a step running this action), used in the steps as {{name}}.")
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(action.parameters.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    TextField("name", text: Binding(get: { action.parameters.indices.contains(i) ? action.parameters[i].name : "" },
                                                    set: { if action.parameters.indices.contains(i) { action.parameters[i].name = ActionArgument.clean($0) } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 160)
                    Text("when none is given")
                        .foregroundStyle(.white.opacity(0.45))
                    TextField("(empty)", text: Binding(get: { action.parameters.indices.contains(i) ? action.parameters[i].value : "" },
                                                       set: { if action.parameters.indices.contains(i) { action.parameters[i].value = $0 } }))
                        .textFieldStyle(.roundedBorder)
                    GlassIcon(symbol: "minus.circle", help: "Take this argument away") { action.parameters.remove(at: i) }
                }
            }
            HStack(spacing: 8) {
                ActionChip(title: "Add an argument", symbol: "plus", help: "A value it's given each time it runs, used as {{name}}") {
                    var n = 1
                    while action.parameters.contains(where: { $0.name == "value\(n == 1 ? "" : "\(n)")" }) { n += 1 }
                    action.parameters.append(ActionArgument(name: "value\(n == 1 ? "" : "\(n)")"))
                }
                if !action.parameters.isEmpty {
                    Text("Use them in the steps as " + action.parameters.filter { !$0.name.isEmpty }.map(\.token).joined(separator: ", "))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: Steps

    var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(action.steps.enumerated()), id: \.element.id) { n, step in
                StepCard(number: n + 1, count: action.steps.count,
                         step: Binding(get: { action.steps.first { $0.id == step.id } ?? step },
                                       set: { new in if let i = action.steps.firstIndex(where: { $0.id == step.id }) { action.steps[i] = new } }),
                         scheduler: scheduler, actionID: action.id, parameters: action.parameters, shortcuts: shortcuts, ink: ink,
                         move: { by in move(step.id, by: by) },
                         copy: { copyStep(step.id) },
                         remove: { action.steps.removeAll { $0.id == step.id } })
            }
            MenuPill(title: "Add a step", help: "Another step, done after the ones above",
                     items: ActionStep.Kind.allCases.map { kind -> (String, Bool, () -> Void) in
                         (kind.title, false, { action.steps.append(StepCard.fresh(kind, settings: scheduler.prefs.settings, scheduler: scheduler, not: action.id)) })
                     })
        }
    }

    /// A copy of a step, right after it.
    private func copyStep(_ id: String) {
        guard let i = action.steps.firstIndex(where: { $0.id == id }) else { return }
        var copy = action.steps[i]
        copy.id = UUID().uuidString
        withAnimation(.easeInOut(duration: 0.15)) { action.steps.insert(copy, at: i + 1) }
    }

    private func move(_ id: String, by: Int) {
        guard let i = action.steps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + by
        guard action.steps.indices.contains(j) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { action.steps.swapAt(i, j) }
    }

    // MARK: Run it now

    var runNow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !action.parameters.filter({ !$0.name.isEmpty }).isEmpty {
                ArgumentFields(parameters: action.parameters, given: $runWith)
            }
            HStack(spacing: 10) {
                PillButton(title: running ? "Running…" : "Run now", prominent: true) {
                    scheduler.runAction(action.id, arguments: runWith)
                }
                .disabled(running || action.live.isEmpty)
                .help("Run it now, with these values (what it gives back, or what went wrong, comes up on a card) · ⌘R")
                if let last = scheduler.actionResults[action.id] {
                    Image(systemName: last.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(last.ok ? Color.green.opacity(0.8) : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.output)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .foregroundStyle(.white.opacity(0.65))
                        if let at = scheduler.actionRanAt[action.id] {
                            (Text("Ran ") + Text(at, style: .relative) + Text(" ago"))
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    CopyButton(text: last.output)
                }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: Used by

    var usedBy: some View {
        VStack(alignment: .leading, spacing: 6) {
            if jobs.isEmpty && callers.isEmpty {
                Text("Nothing runs it yet: schedule it, or run it from a step of another action.")
                    .foregroundStyle(.white.opacity(0.5))
            }
            if !jobs.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(jobs) { job in
                        ActionChip(title: job.name, symbol: "calendar", help: "Open this schedule in the Scheduler") {
                            SchedulerWindow.show(scheduler, select: job.id)
                        }
                    }
                }
            }
            if !callers.isEmpty {
                Text("Run by: " + callers.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }

    private func delete() {
        var uses: [String] = jobs.map { "the schedule \u{201C}\($0.name)\u{201D}" }
        uses += callers.map { "the action \u{201C}\($0)\u{201D}" }
        if !uses.isEmpty {
            guard Confirm.ask("Delete \u{201C}\(action.name)\u{201D}?",
                              "It's run by \(uses.joined(separator: ", ")). They'll fail until you pick another action for them.",
                              ok: "Delete it") else { return }
        }
        let id = action.id
        select(scheduler.actions.actions.first { $0.id != id && !$0.isBuiltin }?.id)
        scheduler.deleteAction(id)
    }
}

/// A titled part of an editor.
struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.45))
            content()
        }
    }
}

/// The values given to an action's arguments: a field for each (empty: its own value).
struct ArgumentFields: View {
    let parameters: [ActionArgument]
    @Binding var given: [ActionArgument]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(parameters.filter { !$0.name.isEmpty }, id: \.name) { p in
                HStack(spacing: 8) {
                    Text(p.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 130, alignment: .trailing)
                    TextField(p.value.isEmpty ? "Its value ({{…}} work too)" : "Empty: \(p.value)", text: value(p.name))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func value(_ name: String) -> Binding<String> {
        Binding(get: { given.last { $0.name == name }?.value ?? "" },
                set: { v in
                    if let i = given.lastIndex(where: { $0.name == name }) { given[i].value = v } else { given.append(ActionArgument(name: name, value: v)) }
                })
    }
}

/// One step of an action: its number, what it does (and with what), its text (with what can go
/// in it), and moving or taking it away.
struct StepCard: View {
    let number: Int
    let count: Int
    @Binding var step: ActionStep
    @ObservedObject var scheduler: Scheduler
    /// The action it's in (a step running it would come round to itself).
    let actionID: String
    let parameters: [ActionArgument]
    let shortcuts: [String]
    let ink: Double
    let move: (Int) -> Void
    let copy: () -> Void
    let remove: () -> Void

    var settings: AppSettings { scheduler.prefs.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(JobRow.color(step.kind).opacity(step.off ? 0.25 : 0.85)))
                MenuPill(title: step.kind.title, help: Self.help(step.kind),
                         items: ActionStep.Kind.allCases.map { kind -> (String, Bool, () -> Void) in
                             (kind.title, step.kind == kind, {
                                 guard step.kind != kind else { return }
                                 let fresh = Self.fresh(kind, settings: settings, scheduler: scheduler, not: actionID)
                                 step.kind = kind
                                 step.target = fresh.target
                                 step.arguments = []
                             })
                         })
                if step.off {
                    Text("Off: skipped")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !step.off }, set: { step.off = !$0 }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(step.off ? "Off: it's skipped when the action runs. Click to turn it on." : "On: click to skip it (it's kept, to turn on again)")
                GlassIcon(symbol: "chevron.up", help: "Do it earlier") { move(-1) }
                    .disabled(number == 1)
                GlassIcon(symbol: "chevron.down", help: "Do it later") { move(1) }
                    .disabled(number == count)
                GlassIcon(symbol: "plus.square.on.square", help: "A copy of this step, right after it", action: copy)
                GlassIcon(symbol: "trash", help: "Take this step away", action: remove)
            }
            target
            if step.kind.hasText {
                GlassEditor(text: $step.text, hint: hint, ink: ink)
                    .frame(minHeight: 70, maxHeight: 160)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.18)))
                insertRow
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
        .opacity(step.off ? 0.55 : 1)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(step.off ? 0.02 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 0.5, dash: step.off ? [4, 3] : [])))
    }

    // MARK: What it does it with

    @ViewBuilder var target: some View {
        switch step.kind {
        case .askModel:
            HStack(spacing: 10) {
                MenuPill(title: step.target.isEmpty ? "Chat's model (\(ModelMenu.shortName(settings.model.isEmpty ? "none" : settings.model)))"
                                                    : ModelMenu.shortName(step.target),
                         help: "The model that answers", items: modelItems)
                Toggle("Can use the model tools and your shortcuts", isOn: $step.useTools)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.toolsOn)
                    .help(settings.toolsOn ? "It may call the tools turned on in Model tools and Shortcuts (not close the chat; a shortcut set to ask first isn't run)"
                                           : "Tools are turned off in Model tools")
            }
        case .tool:
            MenuPill(title: modelTools.first { $0.name == step.target }?.kind.title ?? "Pick a tool",
                     help: "The model tool it runs, with the text",
                     items: modelTools.map { t -> (String, Bool, () -> Void) in (t.kind.title, step.target == t.name, { step.target = t.name }) })
        case .shortcut:
            HStack(spacing: 10) {
                MenuPill(title: step.target.isEmpty ? "Pick a shortcut" : step.target,
                         help: "The shortcut it runs, with the text as its input",
                         items: shortcutNames.map { n -> (String, Bool, () -> Void) in (n, step.target == n, { step.target = n }) })
                if shortcutNames.isEmpty { Text("No shortcuts found yet").foregroundStyle(.white.opacity(0.5)) }
            }
        case .webhook:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Address").frame(width: 56, alignment: .trailing)
                    TextField("https://your-worker.your-name.workers.dev/signal", text: $step.target)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Text("Secret").frame(width: 56, alignment: .trailing)
                    SecureField("Optional: sent as Authorization: Bearer …", text: $step.secret)
                        .textFieldStyle(.roundedBorder)
                }
                if !step.target.trimmingCharacters(in: .whitespaces).isEmpty, !JobEditor.isWebAddress(step.target) {
                    Label("That isn't an http(s) address", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 560)
        case .chime:
            HStack(spacing: 8) {
                PillButton(title: "Day chime's card", prominent: step.target != "night") { step.target = "day" }
                    .help("A ding, and a card with the hour, hours since 6 AM and to 10 PM")
                PillButton(title: "Night watch's card", prominent: step.target == "night") { step.target = "night" }
                    .help("A ding, and a warning card with the hours left before 6 AM")
            }
        case .runAction:
            runAction
        case .addToNote:
            noteTarget
        case .wait:
            waitTarget
        case .remind, .speak:
            EmptyView()
        }
    }

    /// The note it adds to: picked from the notes with a title, by board.
    var noteTarget: some View {
        let notes = scheduler.noteChoices()
        var items: [(String, Bool, () -> Void)] = []
        for kind in BoardStore.kinds where notes.contains(where: { $0.board == kind }) {
            items.append((MenuPill.heading + kind.name, false, {}))
            for note in notes where note.board == kind {
                let link = NoteLink(board: kind.id, box: note.index)
                items.append((note.title ?? note.place, step.note == link, { step.target = ActionStep.target(link) }))
            }
        }
        return HStack(spacing: 10) {
            MenuPill(title: scheduler.noteName(step.note) ?? "Pick a note", help: "The note its text is added to (at the end, on a line of its own)",
                     items: items)
            if let link = step.note {
                ActionChip(title: "Open it", symbol: "arrow.up.right", help: "Open the note on its board") {
                    scheduler.openNote(link)
                }
            }
            if notes.isEmpty { Text("No notes with a title yet").foregroundStyle(.white.opacity(0.5)) }
        }
    }

    /// How long it waits: a few to pick from, or any number of seconds up to an hour.
    var waitTarget: some View {
        HStack(spacing: 8) {
            Text("Wait")
            TextField("", value: Binding(get: { step.seconds }, set: { step.target = "\(min(3600, max(1, $0)))" }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Text("seconds")
            ForEach([5, 30, 60, 300, 900], id: \.self) { n in
                PillButton(title: n < 60 ? "\(n) s" : "\(n / 60) min", prominent: step.seconds == n) { step.target = "\(n)" }
            }
            Text("then the next step (in test mode, 60 times faster)")
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
    }

    /// Which action it runs, the values it gives that action's arguments, and a way to it.
    var runAction: some View {
        let other = scheduler.action(step.target)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MenuPill(title: other?.name ?? (step.target.isEmpty ? "Pick an action" : "That action is gone: pick another"),
                         help: "The action this step runs; what it gives back is this step's",
                         items: scheduler.actions.actions.filter { $0.id != actionID }.map { a -> (String, Bool, () -> Void) in
                             (a.name, step.target == a.id, {
                                 step.target = a.id
                                 step.arguments = a.arguments(keeping: step.arguments)
                             })
                         })
                if let other {
                    ActionChip(title: "Open it", symbol: "arrow.up.right", help: "Show that action") {
                        ActionsWindow.focus.selected = other.id
                    }
                    Text(other.summary).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            if let other, !other.parameters.filter({ !$0.name.isEmpty }).isEmpty {
                ArgumentFields(parameters: other.parameters, given: $step.arguments)
                tokens
            }
        }
    }

    var modelItems: [(String, Bool, () -> Void)] {
        let chat: (String, Bool, () -> Void) = ("The chat's model" + (settings.model.isEmpty ? "" : " (\(settings.model))"),
                                                step.target.isEmpty, { step.target = "" })
        return [chat] + scheduler.models.map { m -> (String, Bool, () -> Void) in (m, step.target == m, { step.target = m }) }
    }

    /// The model tools a step can run (not closing the chat).
    var modelTools: [BuiltinTool] { settings.builtins.filter { $0.kind != .closeWindow } }

    /// Your shortcuts: the ones the Shortcuts app has, and the ones set up for the model.
    var shortcutNames: [String] { Array(Set(shortcuts + settings.shortcuts.map(\.shortcut))).sorted() }

    // MARK: What can go in the text

    /// This action's arguments and {{last}}, a click away; the rest of the placeholders in a menu.
    var insertRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(parameters.filter { !$0.name.isEmpty }, id: \.name) { p in
                    ActionChip(title: p.token, symbol: "plus", help: "This action's argument \(p.name)" + (p.value.isEmpty ? "" : " (when none is given: \(p.value))")) {
                        insert(p.token)
                    }
                }
                ActionChip(title: "{{last}}", symbol: "plus",
                           help: number == 1 ? "What it gave back the last time it ran (or what the step before gave, when another action runs it)"
                                             : "What step \(number - 1) gave back") { insert("{{last}}") }
                MenuPill(title: "More…", help: "The time, what set it off, the timer log…",
                         items: JobText.groups.flatMap { group in
                             group.items.filter { $0.token != "{{last}}" }.map { p -> (String, Bool, () -> Void) in
                                 ("\(group.title): \(p.token)", false, { insert(p.token) })
                             }
                         })
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }

    /// What a value given to another action can hold, said once under the fields.
    var tokens: some View {
        Text("The values can hold {{…}} too: " + (parameters.filter { !$0.name.isEmpty }.map(\.token) + ["{{last}}", "{{date}}", "{{event}}"]).joined(separator: ", "))
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
    }

    private func insert(_ token: String) {
        step.text += (step.text.isEmpty || step.text.hasSuffix(" ") || step.text.hasSuffix("\n") ? "" : " ") + token
    }

    var hint: String {
        switch step.kind {
        case .askModel: return "What should the model do? e.g. Look up tomorrow's weather and tell me whether to take an umbrella."
        case .remind: return "e.g. Drink some water."
        case .speak: return "e.g. Time for the stand-up."
        case .tool:
            switch BuiltinTool.Kind(rawValue: step.target) {
            case .soundAlarm: return "How many seconds the alarm sounds, e.g. 10"
            case .openURL: return "The web address, e.g. https://news.ycombinator.com"
            case .drawDiagram: return "What to draw"
            case .copyText: return "The text to put on the clipboard"
            default: return "What the tool is given"
            }
        case .shortcut: return "The shortcut's input (it can be empty)"
        case .webhook: return "Empty: what happened, as JSON. Or write your own, e.g. {\"text\": \"{{event}}\", \"battery\": \"{{battery}}\"}"
        case .addToNote: return "What goes in the note, e.g. {{date}} {{time}}: {{last}}"
        case .chime, .runAction, .wait: return ""
        }
    }

    static func help(_ kind: ActionStep.Kind) -> String {
        switch kind {
        case .askModel: return "The text is a prompt for the model, which may call tools. Its answer is what this step gives back."
        case .remind: return "The text comes up on a card that stays until you close it (big, in the middle, for a count gone over its limit)."
        case .speak: return "The text is read out in the voice from Read aloud."
        case .tool: return "One of the model tools (alarm, open a link, copy, draw a diagram) runs with the text."
        case .shortcut: return "One of your Apple Shortcuts runs with the text as its input; what it gives back is this step's."
        case .webhook: return "The text is POSTed to a web address (a Cloudflare worker, say). Empty, what happened goes as JSON."
        case .chime: return "A ding and a card, like the day chime's or the night watch's."
        case .runAction: return "Another action runs, given values for its arguments; what it gives back is this step's."
        case .addToNote: return "The text is added at the end of a note you pick, on a line of its own (a log, a journal, answers kept)."
        case .wait: return "Waits a while before the next step; what the step before gave back goes on through it."
        }
    }

    /// A new step of this kind, with what it does it with set to something sensible.
    static func fresh(_ kind: ActionStep.Kind, settings: AppSettings, scheduler: Scheduler, not actionID: String) -> ActionStep {
        switch kind {
        case .tool: return ActionStep(kind: kind, target: BuiltinTool.Kind.soundAlarm.rawValue)
        case .shortcut: return ActionStep(kind: kind, target: settings.shortcuts.first?.shortcut ?? "")
        case .chime: return ActionStep(kind: kind, target: "day")
        case .wait: return ActionStep(kind: kind, target: "30")
        case .addToNote:
            let note = scheduler.noteChoices().first
            return ActionStep(kind: kind, target: note.map { ActionStep.target(NoteLink(board: $0.board.id, box: $0.index)) } ?? "",
                              text: "{{time}}: {{last}}")
        case .runAction:
            let other = scheduler.actions.actions.first { $0.id != actionID && !$0.isBuiltin }
            return ActionStep(kind: kind, target: other?.id ?? "", arguments: other?.arguments(keeping: []) ?? [])
        default: return ActionStep(kind: kind)
        }
    }
}

/// A field to search a list with: a magnifying glass, the text, and a ✕ to clear it.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }
}
