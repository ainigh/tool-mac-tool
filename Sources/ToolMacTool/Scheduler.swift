import AppKit
import SwiftUI
import ToolCore

// The scheduler: jobs that run at the times you set, or when something happens (an alarm goes
// off, the battery reaches a level, a day's count goes over a limit, the month starts, the Mac
// wakes), while the app is open. Each takes its text and asks the model (which can call the model
// tools and your shortcuts), shows it as a reminder, says it, hands it to a model tool or a
// shortcut, calls a web address with it, or chimes. Results go on a card and into the history.
// The day chime and the night watch are its built-in jobs; the timer log's old thresholds and
// signals were turned into jobs the first time this version ran.

@MainActor
final class Scheduler: ObservableObject {
    @Published var book: ScheduleBook {
        didSet {
            if book != oldValue { scheduleSave() }
        }
    }
    /// The jobs running now (by id).
    @Published private(set) var running: Set<String> = []
    @Published private(set) var problem: String?
    /// The models Ollama has, for the picker.
    @Published private(set) var models: [String] = []

    let prefs = Preferences.shared
    let url = ScheduleBook.defaultURL()
    /// Says things for jobs that speak (its own, so it doesn't cut into Read aloud).
    let speaker = Speaker()
    private var ticker: Timer?
    private var saveTask: Task<Void, Never>?
    private var waking: NSObjectProtocol?
    /// What the jobs reach into: the log (events, counts), the battery and the chimes, the boards' alarms.
    private weak var activity: ActivityStore?
    private weak var timers: TimerBoard?
    private weak var boards: BoardStore?
    /// When each job last ran for an event, so one whose own run sets its event off can't loop.
    private var lastEvent: [String: Date] = [:]
    static let eventGap: TimeInterval = 1
    private static let migratedKey = "schedulesFromSignals"

    /// A job missed by more than this while the app was closed (or the Mac asleep) is skipped
    /// rather than run late.
    static let lateness: TimeInterval = 60 * 60

    init() {
        var book = ScheduleBook.load(from: url) ?? ScheduleBook(jobs: ScheduleBook.examples)
        book.ensureBuiltins()
        self.book = book
    }

    /// Hooks it up to the log (each entry may set off an event job), the battery and chimes, and
    /// the boards; the first time, the timer log's thresholds and signals become jobs.
    func attach(activity: ActivityStore, timers: TimerBoard, boards: BoardStore) {
        self.activity = activity
        self.timers = timers
        self.boards = boards
        activity.onRecord { [weak self] entry in self?.heard(entry) }
        if !UserDefaults.standard.bool(forKey: Self.migratedKey) {
            UserDefaults.standard.set(true, forKey: Self.migratedKey)
            let now = Date()
            for var job in ScheduleBook.fromSignals(activity.settings) {
                job.plan(from: now)
                book.jobs.append(job)
            }
        }
    }

    /// Starts checking every few seconds (and as soon as the Mac wakes).
    func start() {
        let now = Date()
        for i in book.jobs.indices {
            let job = book.jobs[i]
            // Never planned, or missed long ago: plan from now. (Missed a little: it runs now.)
            if job.enabled, job.next.map({ now.timeIntervalSince($0) > Self.lateness }) ?? true {
                book.jobs[i].plan(from: now)
            }
        }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        waking = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                   queue: .main) { [weak self] _ in
            Task { @MainActor in self?.woke() }
        }
        tick()
        // Once the app has finished starting up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.happened(.appLaunch)
        }
    }

    private func tick() {
        let now = Date()
        for job in book.jobs where job.isDue(now) && !running.contains(job.id) {
            // A chime missed by more than a few minutes (the Mac was asleep) waits for the next hour.
            if job.action == .chime, let next = job.next, now.timeIntervalSince(next) > TimerSpec.chimeGrace {
                if let i = book.jobs.firstIndex(where: { $0.id == job.id }) { book.jobs[i].plan(from: now) }
                continue
            }
            run(job.id, now: now, context: Context(at: job.next))
        }
    }

    /// Back from sleep: what was missed by a lot is skipped, what was just missed runs; then the
    /// jobs that wait for the Mac to wake.
    private func woke() {
        let now = Date()
        for i in book.jobs.indices where book.jobs[i].enabled {
            if let next = book.jobs[i].next, now.timeIntervalSince(next) > Self.lateness { book.jobs[i].plan(from: now) }
        }
        tick()
        happened(.macWake)
    }

    // MARK: Events

    /// What set a run off: the log entry (an event job), the count it took over the limit, and
    /// the time it was planned for.
    struct Context {
        var entry: LogEntry?
        var crossing: Int?
        var at: Date?
    }

    /// A new entry in the log: the jobs waiting for it run.
    private func heard(_ entry: LogEntry) {
        guard let activity else { return }
        let now = Date()
        for job in book.jobs where job.enabled && job.when.kind == .event && job.when.event.isLogged {
            guard job.when.matches(entry, log: activity.log) else { continue }
            fire(job, context: Context(entry: entry, crossing: job.when.crossing(entry, log: activity.log)), now: now)
        }
    }

    /// Something that isn't in the log happened (the app started, the Mac woke).
    private func happened(_ event: ScheduleEvent) {
        let now = Date()
        for job in book.jobs where job.enabled && job.when.kind == .event && job.when.event == event {
            fire(job, context: Context(), now: now)
        }
    }

    private func fire(_ job: ScheduledJob, context: Context, now: Date) {
        if let last = lastEvent[job.id], now.timeIntervalSince(last) < Self.eventGap { return }
        guard !running.contains(job.id) else { return }
        lastEvent[job.id] = now
        // A count over its limit is a threshold crossed: the log (and the report) keep it.
        if let crossing = context.crossing {
            activity?.record(.threshold, source: "thresholds", name: job.name,
                             detail: "\(job.when.rule.describe): \(crossing) today", value: Double(crossing))
        }
        run(job.id, now: now, context: context)
    }

    // MARK: Editing

    func job(_ id: String?) -> ScheduledJob? { book.jobs.first { $0.id == id } }

    /// A binding to a job for the editor: changing when it runs (or turning it on) plans it again.
    func binding(_ id: String) -> Binding<ScheduledJob>? {
        guard job(id) != nil else { return nil }
        return Binding(get: { [weak self] in self?.job(id) ?? ScheduledJob() },
                       set: { [weak self] new in self?.update(new) })
    }

    func update(_ new: ScheduledJob) {
        guard let i = book.jobs.firstIndex(where: { $0.id == new.id }) else { return }
        let old = book.jobs[i]
        var job = new
        // A built-in job keeps what it is and what it does: only when it runs, and whether, change.
        if old.isBuiltin {
            job.builtin = old.builtin
            job.name = old.name
            job.action = old.action
            job.target = old.target
        }
        if job.when != old.when || job.enabled != old.enabled { job.plan(from: Date()) }
        book.jobs[i] = job
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard var job = job(id) else { return }
        job.enabled = on
        update(job)
    }

    func builtin(_ b: ScheduledJob.Builtin) -> ScheduledJob? { book.jobs.first { $0.builtin == b.rawValue } }

    /// A built-in job back as it came (on, at its hours).
    func reset(_ id: String) {
        guard let i = book.jobs.firstIndex(where: { $0.id == id }), let b = book.jobs[i].builtin.flatMap({ ScheduledJob.Builtin(rawValue: $0) }) else { return }
        var job = b.job
        job.lastRun = book.jobs[i].lastRun
        job.lastOK = book.jobs[i].lastOK
        job.lastResult = book.jobs[i].lastResult
        job.plan(from: Date())
        book.jobs[i] = job
    }

    @discardableResult
    func add(_ job: ScheduledJob = ScheduledJob(name: "New schedule", action: .remind,
                                                when: Schedule(kind: .daily, hour: 9, minute: 0))) -> String {
        var job = job
        job.plan(from: Date())
        book.jobs.insert(job, at: 0)
        return job.id
    }

    func duplicate(_ id: String) -> String? {
        guard var copy = job(id) else { return nil }
        copy.id = UUID().uuidString
        copy.builtin = nil
        copy.name += " (copy)"
        copy.lastRun = nil
        copy.lastResult = nil
        copy.lastOK = nil
        return add(copy)
    }

    /// Gone, unless it's built in (those can only be turned off).
    func delete(_ id: String) {
        book.jobs.removeAll { $0.id == id && !$0.isBuiltin }
    }

    func clearHistory(_ id: String) {
        book.runs.removeAll { $0.job == id }
    }

    func loadModels() {
        Task {
            if let names = try? await prefs.ollama.models() { models = names }
        }
    }

    // MARK: Running

    /// Runs it now. On its schedule, it then moves on to its next time; run by hand, its
    /// schedule stays as it was.
    func run(_ id: String, now: Date = Date(), byHand: Bool = false, context: Context = Context()) {
        guard let job = job(id), !running.contains(id) else { return }
        running.insert(id)
        if !byHand, let i = book.jobs.firstIndex(where: { $0.id == id }) {
            // Planned on at once, so a slow job isn't started twice.
            book.jobs[i].next = job.when.next(after: now)
        }
        Task {
            let outcome = await perform(job, now: now, context: context)
            finished(job, at: now, outcome: outcome, byHand: byHand, context: context)
        }
    }

    private func finished(_ job: ScheduledJob, at now: Date, outcome: Outcome, byHand: Bool, context: Context) {
        running.remove(job.id)
        // A chime goes into the timer log, not the history (every hour, it would crowd out the rest).
        if job.action != .chime {
            book.record(JobRun(job: job.id, name: job.name, at: now, ok: outcome.ok, output: outcome.output, tools: outcome.tools))
        }
        if let i = book.jobs.firstIndex(where: { $0.id == job.id }) {
            if byHand {
                book.jobs[i].lastRun = now
                book.jobs[i].lastOK = outcome.ok
                book.jobs[i].lastResult = outcome.output
            } else {
                book.jobs[i].ran(at: now, ok: outcome.ok, result: outcome.output)
            }
        }
        if !outcome.ok {
            ResultCard.shared.show(job: job, text: outcome.output, ok: false, scheduler: self)
            return
        }
        switch job.action {
        case .remind:
            // A count gone over its limit comes up big, in the middle of the screen.
            if let crossing = context.crossing {
                ThresholdCard.show(title: job.name, metric: job.when.metric, count: crossing, limit: job.when.limit, text: outcome.output)
            } else {
                ResultCard.shared.show(job: job, text: outcome.output, ok: true, scheduler: self)
            }
        case .askModel, .shortcut, .webhook:
            if job.showResult { ResultCard.shared.show(job: job, text: outcome.output, ok: true, scheduler: self) }
            if job.speakResult { speaker.say(outcome.output) }
        case .speak, .tool, .chime:
            break
        }
    }

    struct Outcome {
        var ok: Bool
        var output: String
        var tools: [String] = []
    }

    private func perform(_ job: ScheduledJob, now: Date, context: Context) async -> Outcome {
        let s = prefs.settings
        let text = JobText.fill(job.text, now: now, last: job.lastResult,
                                clipboard: NSPasteboard.general.string(forType: .string) ?? "",
                                calendar: Self.calendar(s), clock24: s.clock24, values: values(for: job, context: context, now: now))
        switch job.action {
        case .chime:
            let at = context.at ?? now
            let hour = Calendar.current.dateInterval(of: .hour, for: at)?.start ?? at
            timers?.chime(night: job.target == "night", at: hour, key: job.builtin ?? "job-\(job.id)", name: job.name)
            return Outcome(ok: true, output: "Chimed for \(TimerText.hourLabel(Calendar.current.component(.hour, from: hour)))")
        case .webhook:
            let target = job.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else {
                return Outcome(ok: false, output: "Write the web address it calls (starting https:// or http://).")
            }
            let body = WebCall.body(text: text, job: job, entry: context.entry, crossing: context.crossing, now: now,
                                    calendar: Self.calendar(s), device: ActivityStore.device)
            return await Self.call(url, body: body.data, contentType: body.contentType, secret: job.secret)
        case .remind:
            return Outcome(ok: true, output: text.isEmpty ? job.name : text)
        case .speak:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Outcome(ok: false, output: "Nothing to say: write what to say.") }
            speaker.say(text)
            return Outcome(ok: true, output: text)
        case .tool:
            guard let tool = s.builtins.first(where: { $0.name == job.target }) else {
                return Outcome(ok: false, output: "Pick which model tool it runs.")
            }
            let (result, shown) = ModelTools.shared.run(tool, call: ToolCall(name: tool.name, arguments: ["input": text]))
            return Outcome(ok: !result.hasPrefix("Nothing") && !result.hasPrefix("That isn't"), output: result, tools: [shown])
        case .shortcut:
            guard !job.target.isEmpty else { return Outcome(ok: false, output: "Pick which shortcut it runs.") }
            let returnsText = s.shortcuts.first { $0.shortcut == job.target }?.returnsText ?? true
            do {
                let out = try await ShortcutRunner.run(job.target, input: text, returnsText: returnsText)
                return Outcome(ok: true, output: out.isEmpty ? "\(job.target) ran." : out, tools: [job.target])
            } catch {
                return Outcome(ok: false, output: "\(job.target) failed: \(error.localizedDescription)", tools: [job.target])
            }
        case .askModel:
            return await ask(job, prompt: text, now: now)
        }
    }

    /// What the placeholders are filled with, besides the time: the job, what happened, the
    /// timer log's counts, the battery and the next alarm.
    private func values(for job: ScheduledJob, context: Context, now: Date) -> [String: String] {
        let s = prefs.settings
        let cal = Self.calendar(s)
        var v = ["job": job.name, "when": job.when.describe(clock24: s.clock24)]
        if let activity { v.merge(JobText.logValues(activity.log, now: now, calendar: cal, clock24: s.clock24)) { $1 } }
        if let entry = context.entry { v.merge(JobText.eventValues(entry, now: now, calendar: cal, clock24: s.clock24)) { $1 } }
        if let crossing = context.crossing {
            v["count"] = "\(crossing)"
            v["limit"] = "\(job.when.limit)"
        }
        if let timers {
            let b = timers.battery
            if b.start == nil {
                v["battery"] = "not set"
                v["battery_empty"] = "not set"
            } else {
                v["battery"] = "\(Int(Battery.level(b, now: now).rounded(.up)))%"
                if let empty = Battery.emptyAt(b), empty > now {
                    v["battery_empty"] = AlarmTime.short(empty, now: now)
                } else {
                    v["battery_empty"] = "already empty"
                }
            }
        }
        if let boards {
            if let u = boards.upcoming.first {
                var parts: [String] = [u.at.map { AlarmTime.short($0, now: now) } ?? "ringing now", u.place, u.spec.name]
                if let title = u.title { parts.append(title) }
                v["next_alarm"] = parts.joined(separator: " · ")
            } else {
                v["next_alarm"] = "none"
            }
        }
        return v
    }

    /// POSTs the body to the address: what it answers is the result (a 2xx is a success).
    nonisolated static func call(_ url: URL, body: Data, contentType: String, secret: String) async -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("ToolMacTool", forHTTPHeaderField: "User-Agent")
        let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let host = url.host ?? url.absoluteString
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reply = String(decoding: data.prefix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(ok: (200..<300).contains(code), output: "HTTP \(code)" + (reply.isEmpty ? "" : ": \(reply)"), tools: [host])
        } catch {
            return Outcome(ok: false, output: "Couldn't reach \(host): \(error.localizedDescription)", tools: [host])
        }
    }

    static func calendar(_ s: AppSettings) -> Calendar {
        var c = Calendar.current
        c.timeZone = s.zone
        return c
    }

    // MARK: Asking the model

    private enum ToolAction {
        case builtin(BuiltinTool)
        case shortcut(ShortcutTool)

        func spec(name: String) -> OllamaTool {
            switch self {
            case .builtin(let t): return t.spec()
            case .shortcut(let t): return t.spec(name: name)
            }
        }
    }

    /// The model's model for a job: its own, else the chat's.
    func model(for job: ScheduledJob) -> String {
        job.target.isEmpty ? prefs.settings.model : job.target
    }

    /// How many rounds of tool calls a job's model may make before it has to answer.
    static let toolRounds = 4

    private func ask(_ job: ScheduledJob, prompt: String, now: Date) async -> Outcome {
        let s = prefs.settings
        let model = model(for: job)
        guard !model.isEmpty else { return Outcome(ok: false, output: "Pick a model in Settings first (Ollama needs at least one: ollama pull llama3.2)") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Outcome(ok: false, output: "Write the prompt first.") }
        var tools: [(name: String, action: ToolAction)] = []
        if job.useTools && s.toolsOn {
            // Closing the chat makes no sense for a job.
            let builtins = s.builtins.filter { $0.enabled && $0.kind != .closeWindow }
            let shortcuts = ShortcutTool.callable(s.shortcuts, reserved: Set(builtins.map(\.name)))
            tools = builtins.map { ($0.name, ToolAction.builtin($0)) } + shortcuts.map { ($0.name, ToolAction.shortcut($0.tool)) }
        }
        var system = [
            "You are running as a scheduled job on the user's Mac, called \u{201C}\(job.name)\u{201D} (\(job.when.describe(clock24: s.clock24))). "
                + "Nobody is waiting at the keyboard: do what the prompt asks and answer with just the result, briefly, "
                + "ready to be shown on a card" + (job.speakResult ? " and read out loud (plain sentences, no Markdown)." : "."),
        ]
        if !tools.isEmpty {
            system.append("You have tools that act on the user's Mac (and some of their Apple Shortcuts). Call one when the "
                + "job needs it, then answer using what it returns; don't call tools otherwise, and never pretend you ran one.")
        }
        system.append(NowContext.describe(now, zone: s.zone, location: s.location, clock24: s.clock24))
        var turns = [ChatTurn(role: "system", content: system.joined(separator: "\n\n")), ChatTurn(role: "user", content: prompt)]
        var specs = tools.map { $0.action.spec(name: $0.name) }
        let ollama = prefs.ollama
        var ran: [String] = []
        var answer = ""
        do {
            var round = 0
            while true {
                var said = ""
                var calls: [ToolCall] = []
                do {
                    for try await chunk in ollama.chat(model: model, messages: turns, contextTokens: s.contextTokens,
                                                       temperature: s.temperature, thinking: s.thinking,
                                                       tools: round < Self.toolRounds ? specs : []) {
                        if let piece = chunk.message?.content { said += piece }
                        if let c = chunk.message?.toolCalls { calls += c }
                    }
                } catch let error where !specs.isEmpty && Ollama.cantUseTools(error) {
                    // This model can't call tools: ask again without them.
                    specs = []
                    continue
                }
                if !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer = said }
                if calls.isEmpty { break }
                round += 1
                turns.append(ChatTurn(role: "assistant", content: said, toolCalls: calls))
                for call in calls {
                    let (result, label) = await runTool(call, among: tools)
                    ran.append(label)
                    turns.append(ChatTurn(role: "tool", content: result, toolName: call.function.name))
                }
                if round > Self.toolRounds + 1 { break }
            }
        } catch {
            return Outcome(ok: false, output: ollama.explain(error), tools: ran)
        }
        let shown = MemoryStore.hideTags(answer, streaming: false).trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(ok: true, output: shown.isEmpty ? (ran.isEmpty ? "(No answer.)" : "Done: " + ran.joined(separator: ", ")) : shown,
                       tools: ran)
    }

    private func runTool(_ call: ToolCall, among tools: [(name: String, action: ToolAction)]) async -> (String, String) {
        guard let action = tools.first(where: { $0.name == call.function.name })?.action else {
            return ("There's no tool called \(call.function.name).", call.function.name + " (not a tool)")
        }
        switch action {
        case .builtin(let builtin):
            return ModelTools.shared.run(builtin, call: call)
        case .shortcut(let tool):
            // Nobody is there to say yes: a shortcut set to ask first isn't run by a job.
            if tool.confirm {
                return ("Not run: the user asks to approve this shortcut each time, and nobody is there to approve it.",
                        tool.shortcut + " (needs approval)")
            }
            do {
                let out = try await ShortcutRunner.run(tool.shortcut, input: ShortcutTool.input(from: call), returnsText: tool.returnsText)
                if !tool.returnsText { return ("Done: the shortcut ran.", tool.shortcut) }
                return (out.isEmpty ? "The shortcut ran and gave nothing back." : out, tool.shortcut)
            } catch {
                return ("The shortcut failed: \(error.localizedDescription)", tool.shortcut + " (failed)")
            }
        }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try self.book.save(to: self.url)
                self.problem = nil
            } catch {
                self.problem = "Couldn't save the schedules: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - The card a job's result comes on

/// A glass card at the top right of the screen with a job's result or reminder. It stays until
/// you close it; a newer result takes its place.
@MainActor
final class ResultCard {
    static let shared = ResultCard()
    private var panel: NSPanel?

    func show(job: ScheduledJob, text: String, ok: Bool, scheduler: Scheduler) {
        let panel = self.panel ?? make()
        self.panel = panel
        let view = ResultCardView(title: job.name, symbol: job.action.symbol, text: text, ok: ok,
                                  say: { scheduler.speaker.say(text) },
                                  open: { [weak self] in
                                      self?.hide()
                                      SchedulerWindow.show(scheduler, select: job.id)
                                  },
                                  close: { [weak self] in self?.hide() })
        let host = FirstClickHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrame(NSRect(x: v.maxX - size.width - 12, y: v.maxY - size.height - 8, width: size.width, height: size.height),
                           display: true)
        }
        panel.orderFrontRegardless()
        if ok { NSSound(named: NSSound.Name("Glass"))?.play() } else { NSSound.beep() }
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

struct ResultCardView: View {
    let title: String
    let symbol: String
    let text: String
    let ok: Bool
    let say: () -> Void
    let open: () -> Void
    let close: () -> Void
    @State private var clock = GlassClock()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: ok ? symbol : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ok ? Color(red: 0.45, green: 0.95, blue: 0.6) : Color(red: 1, green: 0.55, blue: 0.5))
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Date(), style: .time)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                GlassIcon(symbol: "xmark", help: "Close", action: close)
            }
            Text(text)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(14)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ActionChip(title: copied ? "Copied" : "Copy", symbol: "doc.on.doc", help: "Copy it") {
                    Clipboard.copy(text)
                    copied = true
                }
                ActionChip(title: "Say it", symbol: "speaker.wave.2", help: "Read it out loud", action: say)
                Spacer()
                ActionChip(title: "Scheduler", symbol: "calendar.badge.clock", help: "Open it in the Scheduler (the whole result and its history)", action: open)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 380)
        .background(GlassCard(clock: clock, mood: ok ? .idle : .error, radius: 20))
        .padding(14)
        .environment(\.colorScheme, .dark)
    }
}
