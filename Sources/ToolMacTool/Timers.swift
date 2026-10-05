import AVFoundation
import AppKit
import SwiftUI
import ToolCore

// The chimes' tiles in the panel, what runs them (a check every second, from launch on), their
// sounds and the big cards they put up: each timer has its own sound and its own spot on the
// screen. The countdowns and due dates run in the boards' boxes (BoardStore), with these looks
// and sounds. The battery drains in the same tick. Everything that happens goes into the log
// (ActivityStore).

/// How each timer looks and sounds.
struct TimerLook {
    let symbol: String
    let tone: Tone
    let spot: ScreenSpot
    /// The card's accent.
    let accent: Color

    static func of(_ spec: TimerSpec) -> TimerLook {
        switch spec.id {
        case "timer-1": return TimerLook(symbol: "timer", tone: .triple, spot: .topLeft, accent: Color(red: 1, green: 0.62, blue: 0.35))
        case "timer-2": return TimerLook(symbol: "hourglass", tone: .siren, spot: .bottomLeft, accent: Color(red: 1, green: 0.5, blue: 0.55))
        case "repeat-1": return TimerLook(symbol: "repeat", tone: .marimba, spot: .topRight, accent: Color(red: 0.5, green: 0.85, blue: 1))
        case "repeat-2": return TimerLook(symbol: "arrow.triangle.2.circlepath", tone: .rising, spot: .bottomRight,
                                          accent: Color(red: 0.6, green: 0.95, blue: 0.7))
        case "due": return TimerLook(symbol: "calendar.badge.clock", tone: .triple, spot: .center,
                                     accent: Color(red: 0.78, green: 0.62, blue: 1))
        case "day-chime": return TimerLook(symbol: "sun.max", tone: .ding, spot: .topCenter, accent: Color(red: 1, green: 0.85, blue: 0.4))
        default: return TimerLook(symbol: "moon.zzz", tone: .dingDong, spot: .bottomCenter, accent: Color(red: 1, green: 0.35, blue: 0.3))
        }
    }
}

@MainActor
final class TimerBoard: ObservableObject {
    @Published private(set) var states: [String: TimerState] = [:]
    @Published private(set) var battery: BatteryState

    /// The two chimes (the countdowns are the boxes').
    let specs = TimerSpec.chimes
    let activity: ActivityStore
    /// Shared with the boxes' timers.
    let sounds = TonePlayer()
    private let cards = BigCards.shared
    private var ticker: Timer?
    private static let key = "timers"
    private static let batteryKey = "battery"
    static let batteryName = "Battery"

    init(activity: ActivityStore) {
        self.activity = activity
        let defaults = UserDefaults.standard
        battery = defaults.data(forKey: Self.batteryKey).flatMap { try? JSONDecoder().decode(BatteryState.self, from: $0) }
            ?? BatteryState()
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: TimerState].self, from: data) {
            // Only the chimes: the panel's countdowns moved into the boards' boxes.
            let ids = Set(specs.map(\.id))
            states = saved.filter { ids.contains($0.key) }
        }
    }

    func start() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common: keeps going while a menu is open or the panel is being scrolled.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
    }

    func state(_ id: String) -> TimerState { states[id] ?? TimerState() }

    /// The calendar the chimes keep: the time zone in Settings.
    var calendar: Calendar { Scheduler.calendar(Preferences.shared.settings) }

    // MARK: Setting

    /// A click on the tile: its next choice, started now (past the last, it's off).
    func tap(_ spec: TimerSpec) {
        let was = state(spec.id)
        let new = spec.cycled(was, now: Date())
        set(spec, new)
        if new.isOn { logSet(spec, new) } else if was.isOn { log(spec, .stopped) }
    }

    func choose(_ spec: TimerSpec, _ choice: Int) {
        let new = spec.chose(choice, now: Date())
        set(spec, new)
        logSet(spec, new)
    }

    func stop(_ spec: TimerSpec) {
        let was = state(spec.id).isOn
        set(spec, TimerState())
        if was { log(spec, .stopped) }
    }

    /// Restart the countdown it's on, from the top.
    func restart(_ spec: TimerSpec) {
        guard let c = state(spec.id).choice else { return }
        choose(spec, c)
    }

    func canSnooze(_ spec: TimerSpec) -> Bool { spec.canSnooze(state(spec.id), now: Date()) }

    /// Quiet now, and ring again in three minutes (once).
    func snooze(_ spec: TimerSpec) {
        let now = Date()
        guard spec.canSnooze(state(spec.id), now: now) else { return }
        states[spec.id] = spec.snoozed(state(spec.id), now: now)
        save()
        sounds.stop(spec.id)
        cards.hide(spec.id)
        log(spec, .snoozed, detail: "Rings again in \(TimerText.duration(TimerSpec.snooze))")
    }

    private func set(_ spec: TimerSpec, _ new: TimerState) {
        // Whatever it was ringing or showing belongs to the old setting.
        sounds.stop(spec.id)
        cards.hide(spec.id)
        states[spec.id] = new.isOn ? new : nil
        save()
    }

    /// OK on a card: quiet, put away, and a finished countdown goes off.
    func dismiss(_ spec: TimerSpec) {
        let ringing = cards.isShown(spec.id)
        sounds.stop(spec.id)
        cards.hide(spec.id)
        if ringing, !spec.isChime { log(spec, .dismissed) }
        if spec.kind == .once, spec.phase(state(spec.id), now: Date()) == .finished {
            states[spec.id] = nil
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private func log(_ spec: TimerSpec, _ kind: LogEntry.Kind, detail: String = "", value: Double? = nil) {
        activity.record(kind, source: spec.id, name: spec.name, detail: detail, value: value)
    }

    private func logSet(_ spec: TimerSpec, _ s: TimerState) {
        if spec.isChime {
            log(spec, .set, detail: "On")
        } else if let d = spec.duration(s) {
            log(spec, .set, detail: TimerText.duration(d), value: d)
        }
    }

    // MARK: The battery

    /// A click on the battery: the next level (100, 80 … 0), draining from now.
    func tapBattery() { setBattery(Battery.cycled(battery, now: Date())) }

    func chooseBattery(_ choice: Int) {
        setBattery(BatteryState(choice: choice, level: Battery.levels[choice], start: Date()))
    }

    private func setBattery(_ new: BatteryState) {
        battery = new
        saveBattery()
        activity.record(.batterySet, source: "battery", name: Self.batteryName, detail: "\(Int(new.level))%", value: new.level)
    }

    private func saveBattery() {
        if let data = try? JSONEncoder().encode(battery) { UserDefaults.standard.set(data, forKey: Self.batteryKey) }
    }

    // MARK: Running

    private func tick() {
        let now = Date()
        let cal = calendar
        for spec in specs {
            let s = state(spec.id)
            // A repeating timer's card goes when the next round starts.
            if spec.kind == .repeating, cards.isShown(spec.id), case .counting = spec.phase(s, now: now) {
                cards.hide(spec.id)
                sounds.stop(spec.id)
            }
            guard let due = spec.due(s, now: now, calendar: cal) else { continue }
            states[spec.id] = due.state.isOn ? due.state : nil
            save()
            if let event = due.event { fire(spec, event) }
        }
        if let due = Battery.due(battery, now: now) {
            battery = due.state
            saveBattery()
            switch due.event {
            case .step(let level):
                activity.record(.batteryLevel, source: "battery", name: Self.batteryName, detail: "\(level)%", value: Double(level))
            case .empty(let at):
                // No card: the log (and the report's battery chart) is where it shows.
                activity.record(.batteryEmpty, source: "battery", name: Self.batteryName, detail: "Ran out", value: 0, at: at)
            }
        }
    }

    private func fire(_ spec: TimerSpec, _ event: TimerEvent) {
        guard case .chime(let at) = event else { return }
        let look = TimerLook.of(spec)
        // No screen (the lid is closed, or a Power Nap woke the Mac in the dark): nothing to show
        // or hear it on. It still goes into the log.
        guard !NSScreen.screens.isEmpty else {
            log(spec, .chime, detail: TimerText.label(at, calendar: calendar) + " (screen off)")
            return
        }
        let ok: () -> Void = { [weak self] in self?.dismiss(spec) }
        log(spec, .chime, detail: TimerText.label(at, calendar: calendar))
        sounds.play(look.tone, for: spec.id, maxSeconds: nil)
        if spec.kind == .dayChime {
            let text = TimerText.day(at, calendar: calendar)
            cards.show(spec.id, at: look.spot, hideAfter: 30, onEscape: ok) { size in
                DayChimeCard(size: size, look: look, text: text, ok: ok)
            }
        } else {
            let text = TimerText.night(at, calendar: calendar)
            cards.show(spec.id, at: look.spot, hideAfter: 10 * 60, onEscape: ok) { size in
                NightChimeCard(size: size, look: look, text: text, ok: ok)
            }
        }
    }
}

// MARK: - Sounds

/// Plays each timer's sound on its own player, so one stopping never cuts another off.
///
/// Careful with the audio hardware, because AVAudioEngine throws Objective-C exceptions (which crash
/// the app) when it's used against an output that isn't there: in the moments after the Mac wakes,
/// while the lid closes or the output device changes. So the engine is made fresh whenever a sound
/// starts from quiet (and dropped when everything's quiet, or the hardware changes under it); it's
/// only touched when there's an output with channels; and for a few seconds after waking, sounds
/// wait.
@MainActor
final class TonePlayer {
    private var engine: AVAudioEngine?
    private var players: [String: AVAudioPlayerNode] = [:]
    private var stops: [String: Task<Void, Never>] = [:]
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Watches the current engine for the hardware changing under it.
    private var configObserver: NSObjectProtocol?
    /// Sounds asked for before this wait (just after waking).
    private var quietUntil = Date.distantPast
    /// Bumped by every play and stop, so a sound that waited doesn't start after it was stopped.
    private var turns: [String: Int] = [:]
    static let format = AVAudioFormat(standardFormatWithSampleRate: Tone.rate, channels: 1)!
    /// How long sounds wait after the Mac wakes.
    static let wakeQuiet: TimeInterval = 4

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopAll() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.quietUntil = Date().addingTimeInterval(Self.wakeQuiet) }
        })
    }

    func play(_ tone: Tone, for id: String, maxSeconds: TimeInterval?) {
        play(buffer(tone), loops: tone.loops, volume: tone.volume, for: id, maxSeconds: maxSeconds)
    }

    func play(_ buffer: AVAudioPCMBuffer, loops: Bool, volume: Float, for id: String, maxSeconds: TimeInterval?) {
        stop(id)
        let turn = (turns[id] ?? 0) + 1
        turns[id] = turn
        let wait = quietUntil.timeIntervalSinceNow
        if wait > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self, self.turns[id] == turn else { return }
                self.start(buffer, loops: loops, volume: volume, for: id, maxSeconds: maxSeconds)
            }
            return
        }
        start(buffer, loops: loops, volume: volume, for: id, maxSeconds: maxSeconds)
    }

    private func start(_ buffer: AVAudioPCMBuffer, loops: Bool, volume: Float, for id: String, maxSeconds: TimeInterval?) {
        guard let engine = readyEngine() else {
            // No output to play on: a system beep is the best there is.
            NSSound.beep()
            return
        }
        let player = players[id] ?? {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: Self.format)
            self.players[id] = p
            return p
        }()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            drop()
            NSSound.beep()
            return
        }
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer, at: nil, options: loops ? .loops : [])
        player.volume = volume
        player.play()
        // Stopped when it's done (a loop, after `maxSeconds`), so the engine can go.
        let seconds = loops ? (maxSeconds ?? 120) : Double(buffer.frameLength) / Tone.rate + 0.3
        stops[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.stop(id) }
        }
    }

    /// The engine, made fresh if there isn't one; nil when there's no output to play on.
    private func readyEngine() -> AVAudioEngine? {
        if let engine { return engine }
        let e = AVAudioEngine()
        // Read before anything is connected: with no output device it has no channels or rate.
        let out = e.outputNode.outputFormat(forBus: 0)
        guard out.channelCount > 0, out.sampleRate > 0 else { return nil }
        engine = e
        // The hardware changed under it (a device came or went): it's stopped; start over next time.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e,
                                                                queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine === e else { return }
                self.drop()
            }
        }
        return e
    }

    func stop(_ id: String) {
        turns[id] = (turns[id] ?? 0) + 1
        stops[id]?.cancel()
        stops[id] = nil
        if let engine, engine.isRunning { players[id]?.stop() }
        // Nothing playing: let the engine go (a running one keeps the audio hardware, and the Mac, awake).
        if stops.isEmpty { drop() }
    }

    func stopAll() {
        for id in Array(stops.keys) { stop(id) }
        drop()
    }

    /// Lets go of the engine and its players; the next sound makes new ones.
    private func drop() {
        for task in stops.values { task.cancel() }
        stops = [:]
        if let engine, engine.isRunning { engine.stop() }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine = nil
        players = [:]
    }

    private func buffer(_ tone: Tone) -> AVAudioPCMBuffer {
        if let b = buffers[tone] { return b }
        let b = Self.buffer(tone.samples())
        buffers[tone] = b
        return b
    }

    /// Mono samples at `Tone.rate`, as a buffer.
    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))!
        b.frameLength = AVAudioFrameCount(samples.count)
        if let dest = b.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { dest.update(from: base, count: samples.count) }
            }
        }
        return b
    }
}

// MARK: - The cards

/// The day chime: the hour, hours since 6 AM and to 10 PM, and how far through the day it is.
struct DayChimeCard: View {
    let size: NSSize
    let look: TimerLook
    let text: (title: String, since: String, left: String, progress: Double)
    let ok: () -> Void

    var body: some View {
        BigCard(size: size, symbol: look.symbol, accent: look.accent, name: "Day chime",
                headline: text.title, line: "\(text.since) · \(text.left)", close: ok) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(LinearGradient(colors: [look.accent.opacity(0.7), look.accent],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(10, g.size.width * text.progress))
                }
            }
            .frame(height: max(8, size.height * 0.03))
            .help("How much of the day (6 AM to 10 PM) has gone")
        }
    }
}

/// The night watch: a warning, the hour and how many hours are left before 6 AM.
struct NightChimeCard: View {
    let size: NSSize
    let look: TimerLook
    let text: (title: String, left: String)
    let ok: () -> Void
    @State private var pulse = false

    var body: some View {
        let h = max(36, size.height * 0.1)
        BigCard(size: size, symbol: "exclamationmark.triangle.fill", accent: look.accent, name: "Night watch · it's late",
                headline: text.title, line: text.left.uppercased(), mood: .error, close: ok) {
            HStack {
                Text("Wrap up and get some sleep.")
                    .font(.system(size: max(13, size.height * 0.045), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                BigButton(title: "OK", prominent: true, height: h, action: ok)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: max(22, size.height * 0.05), style: .continuous)
                .strokeBorder(look.accent.opacity(pulse ? 0.95 : 0.3), lineWidth: 4)
                .allowsHitTesting(false)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - In the panel

/// The chimes and the log, as big tiles stacked in their column: click a chime to turn it on or
/// off.
struct TimerGrid: View {
    @ObservedObject var board: TimerBoard
    let model: AppModel
    let color: Color

    var body: some View {
        VStack(spacing: MenuView.gap) {
            ForEach(board.specs) { spec in
                TimerTile(spec: spec, state: board.state(spec.id), color: color, board: board, big: true)
            }
            BigToolTile(tool: Tools.timerLog, color: color) { model.open(Tools.timerLog) }
        }
    }
}

/// The square a timer tile draws: the icon (full color when on), a ring for what's left, the
/// name, a status line, and a ✕ to stop it.
private struct TileFace: View {
    let symbol: String
    let name: String
    let status: String
    let on: Bool
    let fraction: Double?
    let pulse: Bool
    let color: Color
    let hover: Bool
    /// A size up, for a stacked column (as `BigToolTile` is to `ToolTile`).
    var big = false

    var body: some View {
        let icon: CGFloat = big ? 54 : 40
        let weight: Font.Weight = big ? (hover ? .semibold : .medium) : (hover ? .medium : .regular)
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: big ? 13 : 10, style: .continuous)
                    .fill(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.28)))
                Image(systemName: symbol)
                    .font(.system(size: big ? 24 : 18, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: pulse)
                ProgressRing(fraction: fraction, color: color, size: icon + 12)
            }
            .frame(width: icon, height: icon)
            .scaleEffect(hover ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
            Text(name)
                .font(.system(size: big ? 12 : 10.5, weight: weight))
                .foregroundStyle(hover ? AnyShapeStyle(color) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Text(status)
                .font(.system(size: big ? 10.5 : 10, weight: on ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(on ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .frame(width: big ? MenuView.bigTile : MenuView.tile, height: big ? 108 : 84)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? color.opacity(0.14) : .clear))
    }
}

/// The ✕ in a running tile's corner.
private struct StopBadge: View {
    let color: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, color)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .padding(.trailing, 6)
        .help(help)
        .transition(.scale.combined(with: .opacity))
    }
}

struct TimerTile: View {
    let spec: TimerSpec
    let state: TimerState
    let color: Color
    let board: TimerBoard
    var big = false
    @State private var hover = false

    var body: some View {
        let look = TimerLook.of(spec)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = spec.phase(state, now: context.date)
            ZStack(alignment: .topTrailing) {
                Button { board.tap(spec) } label: {
                    TileFace(symbol: look.symbol, name: spec.name, status: status(phase, now: context.date), on: state.isOn,
                             fraction: fraction(phase), pulse: phase == .finished, color: color, hover: hover, big: big)
                }
                .buttonStyle(PressStyle())
                .help(tip)
                .contextMenu { menu }

                if state.isOn {
                    StopBadge(color: color, help: "Stop \(spec.name)") { board.stop(spec) }
                }
            }
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: state.isOn)
    }

    @ViewBuilder private var menu: some View {
        ForEach(Array(spec.choices.enumerated()), id: \.offset) { i, name in
            Button(spec.isChime ? "Turn on" : "Start \(name)") { board.choose(spec, i) }
        }
        if state.isOn {
            Divider()
            if board.canSnooze(spec) { Button("Snooze 3 min") { board.snooze(spec) } }
            if !spec.isChime { Button("Restart") { board.restart(spec) } }
            Button("Stop") { board.stop(spec) }
        }
    }

    /// What's left, as a fraction of the countdown (nil: no ring).
    private func fraction(_ phase: TimerPhase) -> Double? {
        if case .counting(let left, let total, _) = phase, total > 0 { return left / total }
        if case .snoozed(let left) = phase { return left / TimerSpec.snooze }
        if case .holding = phase { return 0 }
        return nil
    }

    private func status(_ phase: TimerPhase, now: Date) -> String {
        switch phase {
        case .off: return "Off"
        case .counting(let left, _, let round): return TimerText.clock(left) + (round > 0 ? " · #\(round + 1)" : "")
        case .finished: return "Time's up"
        case .snoozed(let left): return "Zz \(TimerText.clock(left))"
        case .holding(let left, _): return "0:00 · ↻ \(TimerText.clock(left))"
        case .chiming:
            let next = spec.nextChime(after: now, calendar: board.calendar)
            return next.map { "Next \(TimerText.hourLabel(board.calendar.component(.hour, from: $0)))" } ?? "On"
        }
    }

    private var tip: String {
        let what: String
        switch spec.kind {
        case .once:
            what = "Counts down, then rings with a big card to click OK (one 3-minute snooze). Reminders come up in the middle of the screen on the way down."
        case .repeating:
            what = "Counts down, rings softly, stays at 0:00 for 5 minutes, then starts again, until you stop it. Reminders on the way down; one snooze a round."
        case .dayChime:
            what = "Every hour from 6 AM to 10 PM: a ding, and a card with the time, hours since 6 AM and hours to 10 PM."
        case .nightChime:
            what = "Every hour from 11 PM to 5 AM: a ding, and a warning card with the time and the hours left before 6 AM."
        case .deadline:
            what = "Counts down to a day and time, then rings with a big card to click OK."
        }
        let steps = (spec.choices + ["Off"]).joined(separator: " → ")
        return "\(spec.name)\n\n\(what) Its card covers the \(TimerLook.of(spec).spot.words) quarter of the screen.\n\nClick: \(steps). Right-click to pick one."
    }
}

/// The thin ring around a running timer's icon: what's left.
private struct ProgressRing: View {
    let fraction: Double?
    let color: Color
    var size: CGFloat = 52

    var body: some View {
        if let fraction {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
            }
            .frame(width: size, height: size)
            .allowsHitTesting(false)
        }
    }
}
