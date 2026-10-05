import AVFoundation
import AppKit
import SwiftUI
import ToolCore

// The timers' looks and sounds, and the big cards the chimes put up: each timer has its own sound
// and its own spot on the screen. The countdowns and due dates run in the boards' notes
// (BoardStore); the chimes are the scheduler's built-in jobs (the day chime and the night watch),
// which call `TimerBoard.chime`. The battery drains here, a check every second. Everything that
// happens goes into the log (ActivityStore).

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
    @Published private(set) var battery: BatteryState

    let activity: ActivityStore
    /// Shared with the boxes' timers and the scheduler's chimes.
    let sounds = TonePlayer()
    private let cards = BigCards.shared
    private var ticker: Timer?
    private static let batteryKey = "battery"
    static let batteryName = "Battery"

    init(activity: ActivityStore) {
        self.activity = activity
        battery = UserDefaults.standard.data(forKey: Self.batteryKey)
            .flatMap { try? JSONDecoder().decode(BatteryState.self, from: $0) } ?? BatteryState()
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

    /// The calendar the cards read the hour in: the time zone in Settings.
    var calendar: Calendar { Scheduler.calendar(Preferences.shared.settings) }

    // MARK: The chimes (run by the scheduler: the day chime and the night watch are its built-in jobs)

    /// A chime for the hour `at`: its sound, its card (the day chime's, or the night watch's
    /// warning), and the log. `key` is the job's, so its OK puts away only its own card.
    func chime(night: Bool, at hour: Date, key: String, name: String) {
        guard let spec = TimerSpec.chimes.first(where: { $0.kind == (night ? .nightChime : .dayChime) }) else { return }
        let look = TimerLook.of(spec)
        // No screen (the lid is closed, or a Power Nap woke the Mac in the dark): nothing to show
        // or hear it on. It still goes into the log.
        guard !NSScreen.screens.isEmpty else {
            activity.record(.chime, source: key, name: name, detail: TimerText.label(hour, calendar: calendar) + " (screen off)")
            return
        }
        let ok: () -> Void = { [weak self] in self?.dismissChime(key) }
        activity.record(.chime, source: key, name: name, detail: TimerText.label(hour, calendar: calendar))
        sounds.play(look.tone, for: key, maxSeconds: nil)
        if night {
            let text = TimerText.night(hour, calendar: calendar)
            cards.show(key, at: look.spot, hideAfter: 10 * 60, onEscape: ok) { size in
                NightChimeCard(size: size, look: look, name: name, text: text, ok: ok)
            }
        } else {
            let text = TimerText.day(hour, calendar: calendar)
            cards.show(key, at: look.spot, hideAfter: 30, onEscape: ok) { size in
                DayChimeCard(size: size, look: look, name: name, text: text, ok: ok)
            }
        }
    }

    /// OK on a chime's card: quiet, and put away.
    func dismissChime(_ key: String) {
        sounds.stop(key)
        cards.hide(key)
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
        guard let due = Battery.due(battery, now: now) else { return }
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
    var name = "Day chime"
    let text: (title: String, since: String, left: String, progress: Double)
    let ok: () -> Void

    var body: some View {
        BigCard(size: size, symbol: look.symbol, accent: look.accent, name: name,
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
    var name = "Night watch"
    let text: (title: String, left: String)
    let ok: () -> Void
    @State private var pulse = false

    var body: some View {
        let h = max(36, size.height * 0.1)
        BigCard(size: size, symbol: "exclamationmark.triangle.fill", accent: look.accent, name: "\(name) · it's late",
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
