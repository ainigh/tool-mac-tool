import SwiftUI

// The look of Glass's own page: a dark glass panel with colors drifting behind it, a glowing
// divider between what was said and what you're typing, and text in colors taken from the hue
// that's moving behind the glass at that moment.

extension Color {
    /// A color from a hue in degrees and a saturation and lightness from 0 to 1, the way Glass's
    /// page (CSS's hsl) writes its colors.
    static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double, opacity: Double = 1) -> Color {
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let s = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: h, saturation: s, brightness: brightness, opacity: opacity)
    }
}

/// The colors of the words on the glass.
enum Ink {
    /// A reply: a band of neighboring hues across the text.
    static func reply(_ hue: Double) -> LinearGradient {
        LinearGradient(colors: [.hsl(hue, 0.95, 0.8), .hsl(hue + 45, 0.95, 0.78), .hsl(hue + 100, 0.95, 0.8)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// What you type: the opposite side of the wheel from the reply.
    static func prompt(_ hue: Double) -> Color { .hsl(hue + 180, 0.9, 0.83) }
}

/// How lively the glass is.
enum GlassMood: Equatable {
    case idle, typing, thinking, streaming, error

    var energy: Double {
        switch self {
        case .idle: return 0.2
        case .typing: return 0.45
        case .thinking: return 0.7
        case .streaming: return 0.95
        case .error: return 0.6
        }
    }

    /// How often the glass is drawn.
    var frameInterval: Double { self == .idle ? 1 / 20 : 1 / 40 }
}

/// The glass's moving parts, stepped once a frame: a hue that goes round the wheel (faster the
/// livelier the glass is), seven colored blobs wandering behind it that gather into a ring while
/// the model thinks, and rings spreading out like drops in water. Views that draw the glass share
/// one clock, and each steps it with the time of its frame.
final class GlassClock {
    struct Blob {
        var x: Double, y: Double, vx: Double, vy: Double
        let size: Double
        let hueOffset: Double
    }

    struct Ring {
        let x: Double, y: Double, hue: Double, power: Double
        var radius = 0.0
        var life = 1.0
    }

    /// What one frame draws.
    struct Frame {
        var time = 0.0
        var hue = 0.0
        /// How lively it is right now (eased towards the mood's energy), plus any kick.
        var energy = 0.2
        /// 1 while the model thinks: the blobs circle and pulse.
        var gather = 0.0
        /// 1 when something went wrong: the colors bleed red.
        var alarm = 0.0
        var blobs: [Blob] = []
        var rings: [Ring] = []

        var glow: Double { min(1.6, energy * 0.55) }

        /// The hue the glass shows, pulled towards red by trouble.
        var shownHue: Double { GlassClock.mix(hue, 352, alarm * 0.8) }

        func blobHue(_ i: Int) -> Double {
            GlassClock.mix(hue + blobs[i].hueOffset, 350 + Double(i % 2) * 18, alarm * 0.85)
        }
    }

    private(set) var frame = Frame()
    private var last: Double?
    private var kick = 0.0

    init() {
        frame.hue = .random(in: 0..<360)
        frame.blobs = (0..<7).map { i in
            Blob(x: .random(in: 0...1), y: .random(in: 0...1),
                 vx: .random(in: -0.12...0.12), vy: .random(in: -0.12...0.12),
                 size: 0.3 + .random(in: 0...0.22), hueOffset: Double(i) * 360 / 7)
        }
    }

    /// A burst of life (you just sent something).
    func nudge(_ amount: Double = 0.6) { kick += amount }

    /// A ring spreading from a point (0...1 across and down the glass).
    func ripple(x: Double, y: Double, hue: Double? = nil, power: Double = 1) {
        frame.rings.append(Ring(x: x, y: y, hue: hue ?? frame.hue, power: power))
        if frame.rings.count > 20 { frame.rings.removeFirst() }
    }

    /// Moves everything on to `date` and hands back the frame to draw.
    @discardableResult
    func step(to date: Date, mood: GlassMood) -> Frame {
        let now = date.timeIntervalSinceReferenceDate
        let dt = min(0.05, max(0, now - (last ?? now)))
        last = now
        if dt > 0 { advance(dt, mood: mood) }
        return frame
    }

    private func advance(_ dt: Double, mood: GlassMood) {
        var f = frame
        f.time += dt
        let ease = { (rate: Double) in min(1, dt * rate) }
        f.energy += (mood.energy - f.energy) * ease(2.5)
        f.gather += ((mood == .thinking ? 1 : 0) - f.gather) * ease(3)
        f.alarm += ((mood == .error ? 1 : 0) - f.alarm) * ease(3)
        kick *= pow(0.2, dt)
        let lively = f.energy + kick
        f.hue = (f.hue + dt * (5 + lively * 75)).truncatingRemainder(dividingBy: 360)
        for i in f.blobs.indices {
            f.blobs[i] = Self.move(f.blobs[i], index: i, time: f.time, dt: dt, lively: lively, gather: f.gather)
        }
        for i in f.rings.indices {
            let p = f.rings[i].power
            f.rings[i].radius += dt * (0.8 + p * 0.9)
            f.rings[i].life -= dt * 0.75 / (0.55 + p * 0.45)
        }
        f.rings.removeAll { $0.life <= 0 }
        frame = f
    }

    /// A blob drifts in curves (its heading turns slowly), is eased back in past the edges, and
    /// while the model thinks it's drawn onto a turning ring.
    private static func move(_ blob: Blob, index i: Int, time t: Double, dt: Double,
                             lively: Double, gather: Double) -> Blob {
        var b = blob
        let k = Double(i)
        let speed = 0.25 + lively * 1.7
        let turn = dt * (0.5 + lively * 0.6) * (sin(t * 0.21 + k * 1.9) + 0.6 * sin(t * 0.53 + k * 0.7))
        let (c, s) = (cos(turn), sin(turn))
        (b.vx, b.vy) = (b.vx * c - b.vy * s, b.vx * s + b.vy * c)
        b.x += b.vx * dt * speed
        b.y += b.vy * dt * speed
        if gather > 0.01 {
            let a = t * 1.9 + k * 2 * .pi / 7
            b.x += (0.5 + cos(a) * 0.26 - b.x) * dt * 2.4 * gather
            b.y += (0.5 + sin(a) * 0.26 - b.y) * dt * 2.4 * gather
        }
        b.vx += (b.x < 0 ? -b.x : b.x > 1 ? 1 - b.x : 0) * dt * 3
        b.vy += (b.y < 0 ? -b.y : b.y > 1 ? 1 - b.y : 0) * dt * 3
        let v = hypot(b.vx, b.vy)
        if v > 0.17 {
            b.vx *= 0.17 / v
            b.vy *= 0.17 / v
        }
        b.x = min(1.25, max(-0.25, b.x))
        b.y = min(1.25, max(-0.25, b.y))
        return b
    }

    /// Mixes two hues the short way round the wheel.
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let d = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
        return (a + d * t + 360).truncatingRemainder(dividingBy: 360)
    }
}

/// The colors behind the glass: the blobs and rings of a frame, blurred together.
struct GlassField: View {
    let frame: GlassClock.Frame

    var body: some View {
        Canvas { context, size in
            Self.draw(frame, in: &context, size: size)
        }
        .blur(radius: 16, opaque: true)
    }

    static func draw(_ f: GlassClock.Frame, in context: inout GraphicsContext, size: CGSize) {
        let all = Path(CGRect(origin: .zero, size: size))
        let m = Double(min(size.width, size.height))
        context.fill(all, with: .color(.hsl(f.hue + 220, 0.45, 0.04)))
        context.blendMode = .plusLighter
        let alpha = min(0.95, 0.32 + 0.38 * min(1, f.energy))
        for (i, b) in f.blobs.enumerated() {
            let k = Double(i)
            let pulse = 0.2 * f.gather * sin(f.time * 5 + k * 1.3)
            let breath = 0.07 * sin(f.time * 0.7 + k * 2.3)
            let radius = b.size * m * 1.7 * (1 + 0.28 * f.energy + pulse + breath)
            let hue = f.blobHue(i)
            let gradient = Gradient(colors: [.hsl(hue, 0.95, 0.55, opacity: alpha), .hsl(hue, 0.95, 0.5, opacity: 0)])
            let center = CGPoint(x: b.x * size.width, y: b.y * size.height)
            context.fill(all, with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
        }
        for r in f.rings {
            let center = CGPoint(x: r.x * size.width, y: r.y * size.height)
            let radius = r.radius * m
            let strength = r.life * min(1, r.power + 0.2)
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
            context.stroke(circle, with: .color(.hsl(r.hue, 1, 0.72, opacity: 0.85 * strength)),
                           lineWidth: max(1, m * 0.035 * r.life * min(1.4, r.power)))
        }
    }
}

/// The glass panel itself, with nothing on it: the colors moving behind it, frosted and darkened
/// so text on it reads well, a bright rim, and a glow around it in the moving hue that grows with
/// how lively it is. `swell` puffs it up a little, the way Glass's panel bulges when text changes.
struct GlassCard: View {
    let clock: GlassClock
    let mood: GlassMood
    var swell = false
    /// Hold still (calm, in the background).
    var paused = false
    var radius: CGFloat = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: mood.frameInterval, paused: paused)) { timeline in
            let f = clock.step(to: timeline.date, mood: mood)
            GlassLayers(frame: f, swell: swell, radius: radius)
        }
        .scaleEffect(swell ? 1.03 : 1)
    }
}

private struct GlassLayers: View {
    let frame: GlassClock.Frame
    let swell: Bool
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: swell ? radius + 6 : radius, style: .continuous)
        let hue = frame.shownHue
        ZStack {
            shape.fill(Color.hsl(hue, 1, 0.62))
                .blur(radius: 10 + frame.glow * 12)
                .opacity(0.14 + frame.glow * 0.3)
            shape.fill(Color.black.opacity(0.35))
                .blur(radius: 16)
                .offset(y: 10)
            shape.fill(.ultraThinMaterial)
            GlassField(frame: frame)
                .opacity(0.9)
                .clipShape(shape)
            shape.fill(Color.black.opacity(0.3))
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0),
                                              .init(color: .white.opacity(0.03), location: 0.45),
                                              .init(color: .white.opacity(0.07), location: 1)],
                                      startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1)))
            shape.fill(Color(red: 10 / 255, green: 10 / 255, blue: 22 / 255).opacity(0.34))
            shape.fill(RadialGradient(colors: [.white.opacity(0.2), .clear], center: UnitPoint(x: 0.5, y: -0.1),
                                      startRadius: 0, endRadius: 340))
                .opacity(swell ? 1 : 0)
            shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .clear],
                                              startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.06)),
                               lineWidth: 1)
        }
        .animation(.timingCurve(0.45, 0, 0.2, 1, duration: swell ? 0.75 : 2.6), value: swell)
    }
}

/// The glowing line between the two halves of the glass: the moving hue and its neighbors, brighter
/// and thicker the livelier the glass is.
struct GlowLine: View {
    let clock: GlassClock
    let mood: GlassMood
    var paused = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { timeline in
            let f = clock.step(to: timeline.date, mood: mood)
            let hue = f.shownHue
            Capsule()
                .fill(LinearGradient(colors: [.clear, .hsl(hue, 1, 0.72), .hsl(hue + 90, 1, 0.72),
                                              .hsl(hue + 180, 1, 0.72), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 2)
                .scaleEffect(x: 1, y: 1 + f.gather * 0.6 * (1 + sin(f.time * 5)) / 2)
                .opacity(0.3 + min(1, f.glow) * 0.7)
                .shadow(color: .hsl(hue, 1, 0.65, opacity: 0.7), radius: 3 + f.glow * 9)
        }
        .frame(height: 2)
    }
}

/// The light at the start of the status line: green when ready, a pulsing yellow while the model
/// thinks, the moving hue while it replies, red when something's wrong.
struct StatusDot: View {
    enum Kind { case ready, thinking, streaming, trouble }

    let kind: Kind
    let hue: Double

    var color: Color {
        switch kind {
        case .ready: return Color(red: 0.43, green: 1, blue: 0.69)
        case .thinking: return Color(red: 1, green: 0.83, blue: 0.42)
        case .streaming: return .hsl(hue, 1, 0.7)
        case .trouble: return Color(red: 1, green: 0.42, blue: 0.51)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: kind != .thinking)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = kind == .thinking ? (1 - cos(t * 2 * .pi)) / 2 : 0
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color, radius: 5)
                .scaleEffect(1 - 0.45 * pulse)
                .opacity(1 - 0.4 * pulse)
        }
        .frame(width: 9, height: 9)
    }
}

/// A thin line that fades out at both ends.
struct HairLine: View {
    var body: some View {
        LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 0.5)
    }
}

/// A round icon button on the glass, with a hover highlight and a tooltip.
struct GlassIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? (hover ? 1 : 0.72) : 0.28))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(hover && enabled ? 0.14 : 0.06)))
                .overlay(Circle().stroke(.white.opacity(hover && enabled ? 0.28 : 0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// A capsule button with a word on it: filled white for the main choice, glassy for the other.
struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(prominent ? Color.white.opacity(hover ? 1 : 0.88)
                                                     : Color.white.opacity(hover ? 0.2 : 0.1)))
                .overlay(Capsule().stroke(.white.opacity(prominent ? 0 : 0.16), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A small capsule button with an icon and a word, for actions under a reply.
struct ActionChip: View {
    let title: String
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(hover ? 0.95 : 0.62))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(.white.opacity(hover ? 0.15 : 0.07)))
                .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help)
    }
}

/// "⏎ send": a key in a faint box and what it does.
struct KeyHint: View {
    let key: String
    let does: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 15)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.08)))
            Text(does)
        }
    }
}
