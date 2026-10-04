import AVFoundation
import AppKit
import SwiftUI
import ToolCore

// The timers' tiles in the panel, what runs them (a check every second, from launch on), their
// sounds, and the cards they pop up: each timer has its own sound and its own spot on the screen.

/// Where on the screen a timer's card shows: each has its own, so two at once never cover each other.
enum ScreenSpot {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    /// The card's origin for its size, inside the screen's visible part.
    func origin(for size: NSSize, in v: NSRect, margin: CGFloat = 20) -> NSPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = v.minX + margin
        case .topCenter, .bottomCenter: x = v.midX - size.width / 2
        case .topRight, .bottomRight: x = v.maxX - size.width - margin
        }
        let top: Bool
        switch self {
        case .topLeft, .topCenter, .topRight: top = true
        default: top = false
        }
        return NSPoint(x: x, y: top ? v.maxY - size.height - margin : v.minY + margin)
    }

    var words: String {
        switch self {
        case .topLeft: return "top left"
        case .topCenter: return "top middle"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomCenter: return "bottom middle"
        case .bottomRight: return "bottom right"
        }
    }
}

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
        case "day-chime": return TimerLook(symbol: "sun.max", tone: .ding, spot: .topCenter, accent: Color(red: 1, green: 0.85, blue: 0.4))
        default: return TimerLook(symbol: "moon.zzz", tone: .dingDong, spot: .bottomCenter, accent: Color(red: 1, green: 0.35, blue: 0.3))
        }
    }
}

@MainActor
final class TimerBoard: ObservableObject {
    @Published private(set) var states: [String: TimerState] = [:]

    let specs = TimerSpec.all
    private let sounds = TonePlayer()
    private let cards = TimerCards()
    private var ticker: Timer?
    private static let key = "timers"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: TimerState].self, from: data) {
            states = saved
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
        set(spec, spec.cycled(state(spec.id), now: Date()))
    }

    func choose(_ spec: TimerSpec, _ choice: Int) {
        set(spec, spec.chose(choice, now: Date()))
    }

    func stop(_ spec: TimerSpec) {
        set(spec, TimerState())
    }

    /// Restart the countdown it's on, from the top.
    func restart(_ spec: TimerSpec) {
        guard let c = state(spec.id).choice else { return }
        choose(spec, c)
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
        sounds.stop(spec.id)
        cards.hide(spec.id)
        if spec.kind == .once, spec.phase(state(spec.id), now: Date()) == .finished { stop(spec) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(states) { UserDefaults.standard.set(data, forKey: Self.key) }
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
            }
            guard let due = spec.due(s, now: now, calendar: cal) else { continue }
            states[spec.id] = due.state.isOn ? due.state : nil
            save()
            if let event = due.event { fire(spec, event, now: now) }
        }
    }

    private func fire(_ spec: TimerSpec, _ event: TimerEvent, now: Date) {
        let look = TimerLook.of(spec)
        // The alarms ring until OK (for two minutes at most); the rest play once.
        sounds.play(look.tone, for: spec.id, maxSeconds: look.tone.loops ? 120 : nil)
        let view: AnyView
        var hideAfter: TimeInterval?
        switch event {
        case .finished(let at):
            let length = state(spec.id).choice.map { spec.presets[$0] } ?? 0
            view = AnyView(CountdownDoneCard(spec: spec, look: look, length: length, at: at,
                                             ok: { [weak self] in self?.dismiss(spec) },
                                             again: { [weak self] in self?.restart(spec) }))
        case .roundDone(let round):
            view = AnyView(RoundDoneCard(spec: spec, look: look, board: self, round: round,
                                         ok: { [weak self] in self?.dismiss(spec) },
                                         stop: { [weak self] in self?.stop(spec) }))
        case .chime(let at):
            if spec.kind == .dayChime {
                view = AnyView(DayChimeCard(look: look, text: TimerText.day(at, calendar: calendar),
                                            ok: { [weak self] in self?.dismiss(spec) }))
                hideAfter = 30
            } else {
                view = AnyView(NightChimeCard(look: look, text: TimerText.night(at, calendar: calendar),
                                              ok: { [weak self] in self?.dismiss(spec) }))
                hideAfter = 10 * 60
            }
        }
        cards.show(spec.id, view, at: look.spot, hideAfter: hideAfter) { [weak self] in self?.dismiss(spec) }
    }
}

// MARK: - Sounds

/// Plays each timer's sound on its own player, so one stopping never cuts another off.
@MainActor
final class TonePlayer {
    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var stops: [String: Task<Void, Never>] = [:]
    private var buffers: [Tone: AVAudioPCMBuffer] = [:]
    private static let format = AVAudioFormat(standardFormatWithSampleRate: Tone.rate, channels: 1)!

    func play(_ tone: Tone, for id: String, maxSeconds: TimeInterval?) {
        stop(id)
        let player = players[id] ?? {
            let p = AVAudioPlayerNode()
            self.engine.attach(p)
            self.engine.connect(p, to: self.engine.mainMixerNode, format: Self.format)
            self.players[id] = p
            return p
        }()
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            NSSound.beep()
            return
        }
        let b = buffer(tone)
        player.scheduleBuffer(b, at: nil, options: tone.loops ? .loops : [])
        player.volume = tone.volume
        player.play()
        // Stopped when it's done (a loop, after `maxSeconds`), so the engine can rest.
        let seconds = tone.loops ? (maxSeconds ?? 120) : Double(b.frameLength) / Tone.rate + 0.3
        stops[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.stop(id) }
        }
    }

    func stop(_ id: String) {
        stops[id]?.cancel()
        stops[id] = nil
        players[id]?.stop()
        // Nothing playing: pause the engine (a running one keeps the audio hardware, and the Mac, awake).
        if stops.isEmpty, engine.isRunning { engine.pause() }
    }

    private func buffer(_ tone: Tone) -> AVAudioPCMBuffer {
        if let b = buffers[tone] { return b }
        let samples = tone.samples()
        let b = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        buffers[tone] = b
        return b
    }
}

// MARK: - Cards

/// One floating glass card per timer, in that timer's spot on the screen.
@MainActor
final class TimerCards {
    private var panels: [String: GlassPanel] = [:]
    private var hides: [String: Task<Void, Never>] = [:]

    func isShown(_ id: String) -> Bool { panels[id]?.isVisible == true }

    func show(_ id: String, _ view: AnyView, at spot: ScreenSpot, hideAfter: TimeInterval?, onEscape: @escaping () -> Void) {
        hide(id)
        let panel = panels[id] ?? {
            let p = GlassPanel(size: NSSize(width: 360, height: 160))
            p.dragsAnywhere = true
            p.level = .floating
            self.panels[id] = p
            return p
        }()
        panel.onEscape = {
            onEscape()
            return true
        }
        let host = FirstClickHostingView(rootView: view)
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        // The screen with the pointer: where you're looking.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let screen { panel.setFrameOrigin(spot.origin(for: size, in: screen.visibleFrame)) }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
        if let hideAfter {
            hides[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(hideAfter * 1_000_000_000))
                if !Task.isCancelled { self?.hide(id) }
            }
        }
    }

    func hide(_ id: String) {
        hides[id]?.cancel()
        hides[id] = nil
        panels[id]?.orderOut(nil)
    }
}

/// The parts every timer card shares: an icon in its accent, a title and a line under it, a close
/// button, then the card's own content.
private struct TimerCardFrame<Content: View>: View {
    let look: TimerLook
    let title: String
    let subtitle: String
    var mood: GlassMood = .idle
    var width: CGFloat = 330
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var clock = GlassClock()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(look.accent.opacity(0.22))
                    Image(systemName: look.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(look.accent)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                GlassIcon(symbol: "xmark", help: "Close (Esc)", action: close)
            }
            content()
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: width)
        .background(GlassCard(clock: clock, mood: mood, radius: 22))
        .padding(20)
        .environment(\.colorScheme, .dark)
    }
}

/// Timer 1 and 2 at zero: rings until OK.
struct CountdownDoneCard: View {
    let spec: TimerSpec
    let look: TimerLook
    let length: TimeInterval
    let at: Date
    let ok: () -> Void
    let again: () -> Void

    var body: some View {
        TimerCardFrame(look: look, title: "Time's up", subtitle: "\(spec.name) · \(TimerText.duration(length)) · done at \(at.formatted(date: .omitted, time: .shortened))",
                       mood: .error, close: ok) {
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: "Again (\(TimerText.duration(length)))", action: again)
                    .help("Start the same countdown again")
                PillButton(title: "OK", prominent: true, action: ok)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Repeat 1 and 2 at zero: when the next round starts, and a way to stop.
struct RoundDoneCard: View {
    let spec: TimerSpec
    let look: TimerLook
    @ObservedObject var board: TimerBoard
    let round: Int
    let ok: () -> Void
    let stop: () -> Void

    var body: some View {
        let s = board.state(spec.id)
        let length = spec.duration(s) ?? 0
        TimerCardFrame(look: look, title: "Round \(round) done", subtitle: "\(spec.name) · every \(TimerText.duration(length))", close: ok) {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if case .holding(let left, _) = spec.phase(s, now: context.date) {
                        Label("Next round in \(TimerText.clock(left))", systemImage: "arrow.clockwise")
                            .monospacedDigit()
                    } else {
                        Label("Next round started", systemImage: "play.fill")
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(look.accent)
                Spacer()
                PillButton(title: "Stop timer", action: stop)
                    .help("Stop \(spec.name): no more rounds")
                PillButton(title: "OK", prominent: true, action: ok)
            }
        }
    }
}

/// The day chime: the hour, hours since 6 AM and to 10 PM, and how far through the day it is.
struct DayChimeCard: View {
    let look: TimerLook
    let text: (title: String, since: String, left: String, progress: Double)
    let ok: () -> Void

    var body: some View {
        TimerCardFrame(look: look, title: text.title, subtitle: "Day chime", close: ok) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(text.since, systemImage: "sunrise")
                    Spacer()
                    Label(text.left, systemImage: "sunset")
                }
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(LinearGradient(colors: [look.accent.opacity(0.7), look.accent],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, g.size.width * text.progress))
                    }
                }
                .frame(height: 6)
                .help("How much of the day (6 AM to 10 PM) has gone")
            }
        }
    }
}

/// The night watch: a warning, the hour and how many hours are left before 6 AM.
struct NightChimeCard: View {
    let look: TimerLook
    let text: (title: String, left: String)
    let ok: () -> Void
    @State private var pulse = false

    var body: some View {
        TimerCardFrame(look: look, title: text.title, subtitle: "Night watch", mood: .error, width: 380, close: ok) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .bold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, look.accent)
                        .scaleEffect(pulse ? 1.08 : 0.94)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text.left.uppercased())
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                            .foregroundStyle(look.accent)
                        Text("It's late. Wrap up and get some sleep.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                HStack {
                    Spacer()
                    PillButton(title: "OK", prominent: true, action: ok)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(look.accent.opacity(pulse ? 0.95 : 0.35), lineWidth: 2.5)
                .padding(20)
                .allowsHitTesting(false)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

// MARK: - In the panel

/// The six timer tiles: click to step through each one's choices; the ring shows what's left.
struct TimerGrid: View {
    @ObservedObject var board: TimerBoard
    let color: Color

    var body: some View {
        LazyVGrid(columns: MenuView.columns, alignment: .leading, spacing: MenuView.gap) {
            ForEach(board.specs) { spec in
                TimerTile(spec: spec, state: board.state(spec.id), color: color, board: board)
            }
        }
    }
}

struct TimerTile: View {
    let spec: TimerSpec
    let state: TimerState
    let color: Color
    let board: TimerBoard
    @State private var hover = false

    var body: some View {
        let look = TimerLook.of(spec)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = spec.phase(state, now: context.date)
            ZStack(alignment: .topTrailing) {
                Button { board.tap(spec) } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(state.isOn ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.28)))
                            Image(systemName: look.symbol)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.white)
                                .symbolEffect(.pulse, isActive: phase == .finished)
                            ProgressRing(fraction: fraction(phase), color: color)
                        }
                        .frame(width: 40, height: 40)
                        .scaleEffect(hover ? 1.06 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover)
                        Text(spec.name)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Text(status(phase, now: context.date))
                            .font(.system(size: 10, weight: state.isOn ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(state.isOn ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    .frame(width: MenuView.tile, height: 84)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hover ? color.opacity(0.14) : .clear))
                }
                .buttonStyle(PressStyle())
                .help(tip)
                .contextMenu { menu }

                if state.isOn {
                    Button { board.stop(spec) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, color)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .padding(.trailing, 6)
                    .help("Stop \(spec.name)")
                    .transition(.scale.combined(with: .opacity))
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
            if !spec.isChime { Button("Restart") { board.restart(spec) } }
            Button("Stop") { board.stop(spec) }
        }
    }

    /// What's left, as a fraction of the countdown (nil: no ring).
    private func fraction(_ phase: TimerPhase) -> Double? {
        if case .counting(let left, let total, _) = phase, total > 0 { return left / total }
        if case .holding = phase { return 0 }
        return nil
    }

    private func status(_ phase: TimerPhase, now: Date) -> String {
        switch phase {
        case .off: return "Off"
        case .counting(let left, _, let round): return TimerText.clock(left) + (round > 0 ? " · #\(round + 1)" : "")
        case .finished: return "Time's up"
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
            what = "Counts down, then rings with a card to click OK."
        case .repeating:
            what = "Counts down, rings softly, stays at 0:00 for 5 minutes, then starts again, until you stop it."
        case .dayChime:
            what = "Every hour from 6 AM to 10 PM: a ding, and a card with the time, hours since 6 AM and hours to 10 PM."
        case .nightChime:
            what = "Every hour from 11 PM to 5 AM: a ding, and a warning card with the time and the hours left before 6 AM."
        }
        let steps = (spec.choices + ["Off"]).joined(separator: " → ")
        return "\(spec.name)\n\n\(what) Its card shows at the \(TimerLook.of(spec).spot.words) of the screen.\n\nClick: \(steps). Right-click to pick one."
    }
}

/// The thin ring around a running timer's icon: what's left of the countdown.
private struct ProgressRing: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        if let fraction {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.001, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: fraction)
            }
            .frame(width: 52, height: 52)
            .allowsHitTesting(false)
        }
    }
}
