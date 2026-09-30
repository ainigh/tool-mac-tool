import SwiftUI

/// A soft squircle whose edge ripples. `wobble` is how far the edge moves (points; animatable, so
/// it eases between calm and lively), `phase` moves the ripples along (advance it every frame).
struct Blob: Shape {
    var wobble: Double
    var phase: Double
    /// Higher is squarer: 2 is an ellipse, 4 a squircle. Square enough that a card of text fits.
    var squareness: Double = 8

    var animatableData: Double {
        get { wobble }
        set { wobble = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let a = Double(rect.width) / 2 - abs(wobble), b = Double(rect.height) / 2 - abs(wobble)
        let cx = Double(rect.midX), cy = Double(rect.midY)
        let e = 2 / squareness
        let steps = 180
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for i in 0..<steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = a * copysign(pow(abs(c), e), c)
            let y = b * copysign(pow(abs(s), e), s)
            let ripple = 0.6 * sin(3 * t + phase) + 0.4 * sin(5 * t - phase * 1.7)
            let len = max(sqrt(x * x + y * y), 0.001)
            let d = wobble * ripple
            points.append(CGPoint(x: cx + x + x / len * d, y: cy + y + y / len * d))
        }
        var p = Path()
        p.addLines(points)
        p.closeSubpath()
        return p
    }
}

/// How lively the glass is.
enum GlassMood {
    case calm, thinking, speaking

    var wobble: Double {
        switch self {
        case .calm: return 0.8
        case .thinking: return 4
        case .speaking: return 2
        }
    }

    /// How fast the ripples and colors move.
    var speed: Double {
        switch self {
        case .calm: return 0.35
        case .thinking: return 1.6
        case .speaking: return 0.9
        }
    }
}

/// The glass itself, with no background of its own: frosted blur of whatever is behind the window,
/// a faint turning rainbow inside it, a dark tint so text on it reads well, a bright rim and a
/// colored glow, all in the shape of a softly rippling card. Put content on top of it.
struct GlassSurface: View {
    var mood: GlassMood
    var time: Double

    var body: some View {
        let shape = Blob(wobble: mood.wobble, phase: time * mood.speed * 2)
        let hue = (time * mood.speed * 0.02).truncatingRemainder(dividingBy: 1)
        ZStack {
            shape.fill(Color(hue: hue, saturation: 0.8, brightness: 1).opacity(mood == .calm ? 0.22 : 0.4))
                .blur(radius: 20)
            shape.fill(.ultraThinMaterial)
            GlassColors(hue: hue, angle: time * mood.speed * 25)
                .opacity(0.55)
                .clipShape(shape)
            shape.fill(Color.black.opacity(0.45))
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear, .white.opacity(0.06)],
                                      startPoint: .top, endPoint: .bottom))
            shape.stroke(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.12), .white.opacity(0.35)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing),
                         lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.9), value: mood.wobble)
    }
}

/// The colors moving inside the glass (Glass's hue wheel, blurred).
struct GlassColors: View {
    var hue: Double
    var angle: Double

    var body: some View {
        let colors = (0...6).map { i in
            Color(hue: (hue + Double(i) / 6).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 1)
        }
        AngularGradient(colors: colors, center: .center, angle: .degrees(angle))
            .blur(radius: 40)
            .opacity(0.4)
    }
}
