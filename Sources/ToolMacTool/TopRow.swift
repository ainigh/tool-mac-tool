import AppKit
import SwiftUI
import ToolCore

// The row under the boards at the top of the panel: Unzip to Desktop, then the battery in detail,
// across the rest of the row. The zips downloaded lately are listed under it. (The alarms coming
// up are the notes in the panel's Timers column, and the countdown beside the wrench.)

struct TopRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let files = Tools.files
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: files.title, color: files.color, groups: model.groups, pinID: files.id)
                    ToolTile(tool: Tools.unzip, color: files.color) { model.open(Tools.unzip) }
                }
                .frame(width: MenuView.tile)
                BatteryPanel(board: model.timers, activity: model.activity, color: Tools.batteryColor)
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            RecentZipsList(zips: model.zips)
        }
    }
}

/// A panel in the top row: its title, then a rounded card in its color.
private struct RowCard<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, color: color)
            content()
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(hover ? 0.13 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.2), lineWidth: 0.5))
                .onHover { hover = $0 }
        }
    }
}

// MARK: - The battery

/// The battery in detail: its level now (a gauge with a mark at the next 10% step), when it gets
/// there and when it's empty, when it was last full, and the steps after that. Click the battery
/// to set the next level (100, 80 … 0); right-click to pick one.
struct BatteryPanel: View {
    @ObservedObject var board: TimerBoard
    @ObservedObject var activity: ActivityStore
    let color: Color

    var body: some View {
        RowCard(title: TimerBoard.batteryName, color: color) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: AppClock.time(at: context.date))
            }
        }
        .contextMenu {
            ForEach(Array(Battery.levels.enumerated()), id: \.offset) { i, l in
                Button("Set to \(Int(l))%") { board.chooseBattery(i) }
            }
        }
    }

    private func content(now: Date) -> some View {
        let b = board.battery
        let set = b.start != nil
        let level = Battery.level(b, now: now)
        let steps = Battery.steps(b, now: now)
        let ink = Self.ink(level, set: set)
        let full = Battery.lastFull(b, entries: activity.log.entries)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { board.tapBattery() } label: {
                    Image(systemName: Self.symbol(level, set: set))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(ink)
                        .frame(width: 34, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Click to set it to 100, 80, 60, 40, 20 or 0% (one step each click); right-click to pick. It drains 20% an hour and stops at 0; the Timer log charts it.")
                Text(set ? "\(Int(level.rounded(.up)))%" : "Not set")
                    .font(.system(size: set ? 24 : 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ink)
                    .fixedSize()
                BatteryGauge(level: set ? level : 0, next: steps.first?.level, ink: ink)
                    .frame(height: 20)
            }
            if let next = steps.first {
                HStack(spacing: 12) {
                    Fact(symbol: "arrow.down.right", text: next.level == 0
                         ? "Empty at \(AlarmTime.short(next.at, now: now))"
                         : "\(next.level)% at \(AlarmTime.short(next.at, now: now)) · in \(TimerText.left(next.at.timeIntervalSince(now)))",
                         strong: true, color: ink)
                    if next.level > 0, let empty = Battery.emptyAt(b) {
                        Fact(symbol: "battery.0", text: "Empty \(AlarmTime.short(empty, now: now))")
                    }
                }
            } else {
                Fact(symbol: "info.circle", text: set ? "Empty: click to set it again" : "Click the battery to set it: it drains 20% an hour")
            }
            HStack(spacing: 10) {
                Fact(symbol: "battery.100", text: full.map { "Full \(AlarmTime.short($0, now: now))" } ?? "Not full lately")
                Spacer(minLength: 4)
                // The row is wide: the steps after the next one, up to six of them.
                ForEach(Array(steps.dropFirst().prefix(6).enumerated()), id: \.offset) { _, step in
                    StepChip(level: step.level, at: step.at, now: now)
                }
            }
        }
    }

    /// Green, then amber under half, red under a fifth; gray when it isn't set.
    static func ink(_ level: Double, set: Bool) -> Color {
        guard set else { return .secondary }
        if level > 50 { return Color(red: 0.2, green: 0.72, blue: 0.4) }
        if level > 20 { return Color(red: 0.95, green: 0.6, blue: 0.1) }
        return Color(red: 0.92, green: 0.26, blue: 0.3)
    }

    static func symbol(_ level: Double, set: Bool) -> String {
        guard set else { return "battery.0" }
        switch level {
        case 87.5...: return "battery.100"
        case 62.5..<87.5: return "battery.75"
        case 37.5..<62.5: return "battery.50"
        case 0.5..<37.5: return "battery.25"
        default: return "battery.0"
        }
    }
}

/// A battery drawn wide: its level filled in, a faint tick every 10%, and a mark at the next step.
private struct BatteryGauge: View {
    let level: Double
    let next: Int?
    let ink: Color

    var body: some View {
        GeometryReader { g in
            let shell = max(10, g.size.width - 5)
            let inner = shell - 4
            let h = g.size.height
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2)
                    .frame(width: shell, height: h)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ink.gradient)
                    .frame(width: max(0, inner * min(1, level / 100)), height: h - 4)
                    .offset(x: 2)
                ForEach(1..<10, id: \.self) { k in
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 1, height: h - 8)
                        .offset(x: 2 + inner * Double(k) / 10)
                }
                if let next, next > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 1.5, height: h + 2)
                        .offset(x: 2 + inner * Double(next) / 100)
                        .help("The next step: \(next)%")
                }
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 3, height: h * 0.45)
                    .offset(x: shell + 1)
            }
            .frame(height: h)
        }
        .animation(.linear(duration: 1), value: level)
    }
}

/// "40% 3:12 PM": a step further down, and when.
private struct StepChip: View {
    let level: Int
    let at: Date
    let now: Date

    var body: some View {
        HStack(spacing: 3) {
            Text(level == 0 ? "0%" : "\(level)%").fontWeight(.semibold)
            Text(at.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
        }
        .font(.system(size: 9.5).monospacedDigit())
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("\(level)% at \(AlarmTime.short(at, now: now))")
    }
}

/// An icon and a short line, small.
private struct Fact: View {
    let symbol: String
    let text: String
    var strong = false
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.system(size: 11, weight: strong ? .medium : .regular).monospacedDigit())
        .lineLimit(1)
    }
}

/// The wrench in the menu bar, and beside it the next alarm in the boards: its countdown within
/// the hour, otherwise when it rings ("now" while it's ringing).
struct MenuBarIcon: View {
    @ObservedObject var updater: Updater
    @ObservedObject var boards: BoardStore
    @ObservedObject var modes: ModeCenter = .shared

    var body: some View {
        // The filled icon means an update is waiting; test and quiet mode show their own beside it.
        let icon = Image(systemName: updater.hasUpdate ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
        HStack(spacing: 4) {
            icon
            if modes.mode != .normal { Image(systemName: modes.mode.symbol) }
            if let text = next { Text(text).monospacedDigit() }
        }
    }

    private var next: String? {
        guard let u = boards.upcoming.first else { return nil }
        guard let at = u.at else { return "now" }
        let left = at.timeIntervalSince(boards.now)
        return left < 3600 ? TimerText.clock(left) : AlarmTime.short(at, now: boards.now)
    }
}
