import AppKit
import SwiftUI
import ToolCore

// The big glass cards the timers put on screen: each covers a quarter of the screen (half as wide
// and half as tall), in its own spot, with its words zoomed to fill it. Each stays until it's put
// away; a crossed threshold waits for OK in the middle.

/// Where on the screen a card shows: each timer has its own, so two at once never cover each other.
enum ScreenSpot {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight, center

    /// The card's origin for its size, inside the screen's visible part.
    func origin(for size: NSSize, in v: NSRect, margin: CGFloat = 16) -> NSPoint {
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = v.minX + margin
        case .topCenter, .bottomCenter, .center: x = v.midX - size.width / 2
        case .topRight, .bottomRight: x = v.maxX - size.width - margin
        }
        let y: CGFloat
        switch self {
        case .topLeft, .topCenter, .topRight: y = v.maxY - size.height - margin
        case .center: y = v.midY - size.height / 2
        default: y = v.minY + margin
        }
        return NSPoint(x: x, y: y)
    }

    var words: String {
        switch self {
        case .topLeft: return "top left"
        case .topCenter: return "top middle"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomCenter: return "bottom middle"
        case .bottomRight: return "bottom right"
        case .center: return "middle"
        }
    }

    /// The screen with the pointer: where you're looking.
    static var screen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// A quarter of the screen: half its width and half its height (less a margin).
    static func quarter(of v: NSRect) -> NSSize {
        NSSize(width: (v.width / 2 - 24).rounded(), height: (v.height / 2 - 24).rounded())
    }
}

/// The big cards, one per id, each in its own floating panel. A card stays until it's put away
/// (its OK, its ✕ or Esc): nothing fades out by itself. In quiet mode a card waits, and comes up
/// when quiet mode ends.
@MainActor
final class BigCards {
    static let shared = BigCards()
    private var panels: [String: GlassPanel] = [:]
    /// Bumped on each show, so a fade-out under way doesn't put away a newer card.
    private var shown: [String: Int] = [:]

    func isShown(_ id: String) -> Bool { panels[id]?.isVisible == true }

    /// Shows a card a quarter of the screen in size at `spot`, until it's hidden. Esc on it runs
    /// `onEscape`.
    func show<V: View>(_ id: String, at spot: ScreenSpot, onEscape: (() -> Void)? = nil,
                       @ViewBuilder content: @escaping (NSSize) -> V) {
        if ModeCenter.shared.hold("big-\(id)", { [weak self] in self?.show(id, at: spot, onEscape: onEscape, content: content) }) {
            return
        }
        guard let screen = ScreenSpot.screen else { return }
        let v = screen.visibleFrame
        let size = ScreenSpot.quarter(of: v)
        let panel = panels[id] ?? {
            let p = GlassPanel(size: size)
            p.level = .floating
            self.panels[id] = p
            return p
        }()
        panel.dragsAnywhere = true
        panel.ignoresMouseEvents = false
        if let onEscape {
            panel.onEscape = {
                onEscape()
                return true
            }
        } else {
            panel.onEscape = nil
        }
        panel.contentView = FirstClickHostingView(rootView: content(size).frame(width: size.width, height: size.height))
        panel.setContentSize(size)
        panel.setFrameOrigin(spot.origin(for: size, in: v))
        let mine = (shown[id] ?? 0) + 1
        shown[id] = mine
        // Already up (shown again, or fading out): carry on from where it is rather than blinking
        // out and back in.
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide(_ id: String, fade: TimeInterval = 0.2) {
        // Put away while quiet mode held it: it never comes up.
        ModeCenter.shared.drop("big-\(id)")
        guard let panel = panels[id], panel.isVisible else { return }
        let mine = shown[id]
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                if self?.shown[id] == mine { panel.orderOut(nil) }
            }
        })
    }
}

// MARK: - The parts of a big card

/// Words that grow to fill the space they're given (and shrink to fit it).
struct ZoomText: View {
    let text: String
    var weight: Font.Weight = .heavy
    var color: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 400, weight: weight, design: .rounded))
            .minimumScaleFactor(0.01)
            .lineLimit(1)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A big capsule button for the big cards.
struct BigButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var height: CGFloat = 44
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: height * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.white.opacity(0.92))
            .padding(.horizontal, height * 0.55)
            .frame(height: height)
            .background(Capsule().fill(prominent ? Color.white.opacity(hover ? 1 : 0.9) : Color.white.opacity(hover ? 0.22 : 0.12)))
            .overlay(Capsule().stroke(.white.opacity(prominent ? 0 : 0.2), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .fixedSize()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A quarter-of-the-screen glass card: a header (icon, name, what it is, close), a headline
/// zoomed to fill most of it, a line under that (also zoomed), then whatever else it holds.
struct BigCard<Extra: View>: View {
    let size: NSSize
    let symbol: String
    let accent: Color
    let name: String
    let headline: String
    let line: String
    var mood: GlassMood = .idle
    var close: (() -> Void)?
    @ViewBuilder let extra: () -> Extra
    @State private var clock = GlassClock()

    var body: some View {
        let h = size.height
        let pad = max(18, h * 0.06)
        VStack(alignment: .leading, spacing: h * 0.025) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(accent.opacity(0.22))
                    Image(systemName: symbol)
                        .font(.system(size: h * 0.045, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: h * 0.09, height: h * 0.09)
                Text(name)
                    .font(.system(size: max(13, h * 0.04), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let close { GlassIcon(symbol: "xmark", help: "Close (Esc)", action: close) }
            }
            ZoomText(text: headline, color: accent)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
            ZoomText(text: line, weight: .semibold, color: .white.opacity(0.9))
                .frame(height: h * 0.12)
            extra()
        }
        .padding(pad)
        .frame(width: size.width, height: size.height)
        .background(GlassCard(clock: clock, mood: mood, radius: max(22, h * 0.05)))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - A crossed threshold

/// A count gone over its limit (a scheduler job that waits for that, and reminds): big, in the
/// middle of the screen, with the job's text.
@MainActor
enum ThresholdCard {
    static func show(title: String, metric: ThresholdRule.Metric, count: Int, limit: Int, text: String) {
        let id = "threshold"
        let at = AppClock.now()
        // Held whole in quiet mode (the card's own key), so its sound comes with it.
        if ModeCenter.shared.hold("big-\(id)", {
            show(title: title, metric: metric, count: count, limit: limit, text: text)
        }) { return }
        NSSound(named: NSSound.Name("Funk"))?.play()
        BigCards.shared.show(id, at: .center, onEscape: { BigCards.shared.hide(id) }) { size in
            BigCard(size: size, symbol: "exclamationmark.octagon.fill", accent: Color(red: 1, green: 0.62, blue: 0.3),
                    name: "Threshold crossed · \(title)",
                    headline: "\(count) \(metric.words.lowercased())",
                    line: text.isEmpty ? "today: over your limit of \(limit)" : text, mood: .error) {
                HStack {
                    Text(at.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: max(12, size.height * 0.035), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    BigButton(title: "OK", prominent: true, height: max(36, size.height * 0.1)) { BigCards.shared.hide(id) }
                }
            }
        }
    }
}
