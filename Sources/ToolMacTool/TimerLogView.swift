import AppKit
import Charts
import SwiftUI
import ToolCore

// The timers' report, on a glass panel as big as the Scheduler's: counts for the span you pick,
// when each alarm went off or was snoozed (a timeline), alarms and snoozes per day (and whether
// anything was set that day), the battery's level, and every entry. Its other side sets the
// thresholds and the web address signals go to.

@MainActor
enum TimerLogWindow {
    static func show(_ app: AppModel) {
        let store = app.activity
        let board = app.timers
        Windows.show("timer-log") {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size)
            panel.level = .floating
            let close = { panel.orderOut(nil) }
            let host = FirstClickHostingView(rootView: TimerLogView(store: store, board: board, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close]
            panel.onEscape = {
                close()
                return true
            }
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        if let panel = Windows.window("timer-log") { GlassPanel.fit(panel) }
    }
}

/// The chart colors, on the dark glass: three that tell apart for every kind of color vision, and
/// grays (with their own shapes) for the rest.
enum LogInk {
    static let set = Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255)       // blue
    static let alarm = Color(red: 0xd9 / 255, green: 0x59 / 255, blue: 0x26 / 255)     // orange
    static let snooze = Color(red: 0x19 / 255, green: 0x9e / 255, blue: 0x70 / 255)    // aqua
    static let battery = Color(red: 0x90 / 255, green: 0x85 / 255, blue: 0xe9 / 255)   // violet
    static let quiet = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.25)

    /// What the timeline shows, in order, with its color.
    static let kinds: [(name: String, color: Color)] = [
        ("Set", set), ("Alarm", alarm), ("Snoozed", snooze), ("Chime", quiet), ("Stopped", faint),
    ]

    static func timelineName(_ kind: LogEntry.Kind) -> String? {
        switch kind {
        case .set, .batterySet: return "Set"
        case .alarm: return "Alarm"
        case .snoozed: return "Snoozed"
        case .chime: return "Chime"
        case .stopped, .batteryEmpty: return "Stopped"
        default: return nil
        }
    }
}

struct TimerLogView: View {
    @ObservedObject var store: ActivityStore
    @ObservedObject var board: TimerBoard
    let close: () -> Void

    enum Span: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            }
        }
    }

    enum Side: String, CaseIterable, Identifiable {
        case report = "Report", signals = "Thresholds & signals"
        var id: String { rawValue }
    }

    @State private var span = Span.week
    @State private var side = Side.report
    @State private var clock = GlassClock()

    var body: some View {
        VStack(spacing: 0) {
            header
            HairLine()
            ScrollView {
                Group {
                    if side == .report {
                        LogReport(store: store, span: span)
                    } else {
                        SignalsPane(store: store)
                    }
                }
                .padding(24)
            }
        }
        .foregroundStyle(.white)
        .background(GlassCard(clock: clock, mood: .idle, radius: 28))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(LogInk.battery)
            Text("Timer log").font(.system(size: 20, weight: .bold, design: .rounded))
            Picker("", selection: $side) {
                ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Spacer()
            if side == .report {
                Picker("", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            GlassIcon(symbol: "folder", help: "Show the log file in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.logURL])
            }
            GlassIcon(symbol: "xmark", help: "Close (Esc)", action: close)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: - The report

private struct LogReport: View {
    @ObservedObject var store: ActivityStore
    let span: TimerLogView.Span
    @State private var hoveredDay: Date?

    var body: some View {
        let cal = store.calendar
        let now = Date()
        let to = cal.dateInterval(of: .day, for: now)?.end ?? now
        let from = cal.date(byAdding: .day, value: -span.days, to: to) ?? now
        let entries = store.log.entries(from: from, to: to)
        let days = store.log.days(from: from, to: now, calendar: cal)
        VStack(alignment: .leading, spacing: 26) {
            Stats(days: days)
            ChartBox(title: "When alarms went off, and snoozes", note: "Each mark is one event, on its timer's row") {
                Timeline(entries: entries, from: from, to: to)
            }
            HStack(alignment: .top, spacing: 20) {
                ChartBox(title: "Alarms and snoozes per day", note: "Hover a day for its numbers") {
                    PerDay(days: days, hovered: $hoveredDay)
                }
                ChartBox(title: "Was anything set?", note: "A filled dot: a timer or the battery was set that day") {
                    SetDays(days: days)
                }
                .frame(width: 300)
            }
            ChartBox(title: "Battery", note: "Its level: set by a click, 20% an hour down to 0") {
                BatteryChart(entries: store.log.entries, from: from, to: min(to, now))
            }
            ChartBox(title: "Every entry", note: "Newest first") {
                EntryList(entries: entries.reversed())
            }
        }
    }
}

/// A titled glass box for a chart.
private struct ChartBox<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(note).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
    }
}

/// The span's totals, as numbers.
private struct Stats: View {
    let days: [DaySummary]

    var body: some View {
        let total = { (f: (DaySummary) -> Int) -> Int in days.map(f).reduce(0, +) }
        let snoozes = total { $0.snoozes }
        let perDay = days.isEmpty ? 0 : Double(snoozes) / Double(days.count)
        let setDays = days.filter(\.anySet).count
        HStack(spacing: 12) {
            Stat(value: "\(total { $0.alarms })", label: "Alarms", color: LogInk.alarm)
            Stat(value: "\(snoozes)", label: "Snoozes", color: LogInk.snooze)
            Stat(value: String(format: "%.1f", perDay), label: "Snoozes a day", color: LogInk.snooze)
            Stat(value: "\(total { $0.sets })", label: "Times set", color: LogInk.set)
            Stat(value: "\(setDays) of \(days.count)", label: "Days with one set", color: LogInk.set)
            Stat(value: "\(total { $0.chimes })", label: "Chimes", color: LogInk.quiet)
            Stat(value: "\(total { $0.batteryEmpties })", label: "Batteries emptied", color: LogInk.battery)
            Stat(value: "\(total { $0.thresholds })", label: "Thresholds crossed", color: Color(red: 1, green: 0.62, blue: 0.3))
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// Every event on a time axis, one row per timer, colored (and shaped) by what happened.
private struct Timeline: View {
    struct Mark: Identifiable {
        let entry: LogEntry
        let what: String
        var id: String { entry.id }
    }

    let entries: [LogEntry]
    let from: Date
    let to: Date

    var body: some View {
        let marks = entries.compactMap { e in LogInk.timelineName(e.kind).map { Mark(entry: e, what: $0) } }
        if marks.isEmpty {
            Empty(text: "Nothing happened in this span")
        } else {
            Chart {
                ForEach(marks) { m in
                    PointMark(x: .value("When", m.entry.at), y: .value("Timer", m.entry.name))
                        .foregroundStyle(by: .value("What", m.what))
                        .symbol(by: .value("What", m.what))
                        .symbolSize(70)
                }
            }
            .chartForegroundStyleScale(domain: LogInk.kinds.map { $0.name }, range: LogInk.kinds.map { $0.color })
            .chartSymbolScale(domain: LogInk.kinds.map { $0.name },
                              range: [BasisChartSymbolShape.circle, .diamond, .triangle, .square, .cross])
            .chartXScale(domain: from...to)
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis { faintAxis }
            .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(.white.opacity(0.75)) } }
            .frame(height: CGFloat(max(3, Set(marks.map { $0.entry.name }).count)) * 34 + 50)
        }
    }

    private var faintAxis: some AxisContent {
        AxisMarks { _ in
            AxisGridLine().foregroundStyle(.white.opacity(0.08))
            AxisValueLabel().foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Alarms and snoozes, side by side for each day.
private struct PerDay: View {
    let days: [DaySummary]
    @Binding var hovered: Date?

    var body: some View {
        Chart {
            ForEach(days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Count", d.alarms))
                    .foregroundStyle(by: .value("What", "Alarms"))
                    .position(by: .value("What", "Alarms"))
                    .cornerRadius(4)
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Count", d.snoozes))
                    .foregroundStyle(by: .value("What", "Snoozes"))
                    .position(by: .value("What", "Snoozes"))
                    .cornerRadius(4)
            }
            if let hovered, let d = days.first(where: { $0.day == hovered }) {
                RuleMark(x: .value("Day", d.day, unit: .day))
                    .foregroundStyle(.white.opacity(0.18))
                    .annotation(position: .top, alignment: .center, spacing: 4) {
                        Text("\(d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(d.alarms) alarms · \(d.snoozes) snoozes\(d.anySet ? "" : " · nothing set")")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.6)))
                    }
            }
        }
        .chartForegroundStyleScale(["Alarms": LogInk.alarm, "Snoozes": LogInk.snooze])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: days.count > 10 ? 5 : 1)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel().foregroundStyle(.white.opacity(0.6))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let plot = proxy.plotFrame else { return }
                            let x = point.x - g[plot].origin.x
                            if let date: Date = proxy.value(atX: x) {
                                hovered = Calendar.current.dateInterval(of: .day, for: date)?.start
                            }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .frame(height: 220)
    }
}

/// A dot per day: filled when something was set, hollow when not.
private struct SetDays: View {
    let days: [DaySummary]

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(30), spacing: 6), count: 7)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(days) { d in
                VStack(spacing: 3) {
                    Circle()
                        .fill(d.anySet ? LogInk.set : .clear)
                        .overlay(Circle().stroke(d.anySet ? LogInk.set : .white.opacity(0.35), lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                    Text(d.day.formatted(.dateTime.day()))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                .help("\(d.day.formatted(date: .complete, time: .omitted)): \(d.anySet ? "\(d.sets) set" : "nothing set")")
            }
        }
    }
}

/// The battery's level over the span.
private struct BatteryChart: View {
    let entries: [LogEntry]
    let from: Date
    let to: Date

    var body: some View {
        let track = Battery.track(entries, from: from, to: to)
        let empties = entries.filter { $0.kind == .batteryEmpty && $0.at >= from && $0.at <= to }
        if track.isEmpty {
            Empty(text: "The battery wasn't set in this span")
        } else {
            Chart {
                ForEach(Array(track.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("When", p.at), y: .value("Level", p.level))
                        .foregroundStyle(LogInk.battery)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    AreaMark(x: .value("When", p.at), y: .value("Level", p.level))
                        .foregroundStyle(LinearGradient(colors: [LogInk.battery.opacity(0.28), LogInk.battery.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                ForEach(empties) { e in
                    PointMark(x: .value("When", e.at), y: .value("Level", 0))
                        .foregroundStyle(LogInk.battery)
                        .symbolSize(60)
                        .annotation(position: .top) {
                            Text("Empty").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        }
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: from...max(to, from.addingTimeInterval(60)))
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel().foregroundStyle(.white.opacity(0.6))
                }
            }
            .chartYAxis {
                AxisMarks(values: [0, 20, 40, 60, 80, 100]) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }.foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(height: 180)
        }
    }
}

/// The entries as a table: when, which, what.
private struct EntryList: View {
    let entries: [LogEntry]

    var body: some View {
        if entries.isEmpty {
            Empty(text: "No entries in this span")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries.prefix(400)) { e in
                    HStack(spacing: 14) {
                        Text(e.at.formatted(.dateTime.weekday(.abbreviated).day().hour().minute()))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 150, alignment: .leading)
                        Text(e.name).frame(width: 110, alignment: .leading)
                        HStack(spacing: 6) {
                            Circle().fill(color(e.kind)).frame(width: 7, height: 7)
                            Text(e.kind.words)
                        }
                        .frame(width: 130, alignment: .leading)
                        Text(e.detail).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 5)
                    Divider().opacity(0.3)
                }
            }
        }
    }

    private func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .set: return LogInk.set
        case .alarm: return LogInk.alarm
        case .snoozed: return LogInk.snooze
        case .batterySet, .batteryLevel, .batteryEmpty: return LogInk.battery
        case .threshold: return Color(red: 1, green: 0.62, blue: 0.3)
        default: return LogInk.quiet
        }
    }
}

private struct Empty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, minHeight: 60)
    }
}

// MARK: - Thresholds and signals

private struct SignalsPane: View {
    @ObservedObject var store: ActivityStore
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ChartBox(title: "Thresholds", note: "The moment a day's count goes over the limit, a card comes up in the middle of the screen (and a signal goes out)") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($store.settings.rules) { $rule in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Picker("", selection: $rule.metric) {
                                ForEach(ThresholdRule.Metric.allCases, id: \.self) { Text($0.words).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            Text("in a day over")
                            Stepper(value: $rule.limit, in: 0...999) {
                                Text("\(rule.limit)").monospacedDigit().frame(minWidth: 30)
                            }
                            Spacer()
                            let today = store.log.days(from: Date(), to: Date(), calendar: store.calendar).first?.count(rule.metric) ?? 0
                            Text("today: \(today)").foregroundStyle(.white.opacity(0.55)).monospacedDigit()
                            GlassIcon(symbol: "trash", help: "Delete this threshold") {
                                store.settings.rules.removeAll { $0.id == rule.id }
                            }
                        }
                        .font(.system(size: 12.5))
                    }
                    Button {
                        store.settings.rules.append(ThresholdRule(metric: .alarms, limit: 10))
                    } label: {
                        Label("Add a threshold", systemImage: "plus")
                    }
                    .buttonStyle(.link)
                }
            }
            ChartBox(title: "Signals", note: "Each one is POSTed as JSON to your address (a Cloudflare worker, say). Unsent ones are kept and retried every minute.") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledField(label: "Address") {
                        TextField("https://your-worker.your-name.workers.dev/signal", text: $store.settings.url)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledField(label: "Secret") {
                        SecureField("Optional: sent as Authorization: Bearer …", text: $store.settings.secret)
                            .textFieldStyle(.roundedBorder)
                    }
                    if !store.settings.url.trimmingCharacters(in: .whitespaces).isEmpty && store.settings.endpoint == nil {
                        Label("That isn't an http(s) address", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5)).foregroundStyle(.orange)
                    }
                    LabeledField(label: "Send") {
                        HStack(spacing: 18) {
                            Toggle("Thresholds crossed", isOn: $store.settings.sendThresholds)
                            Toggle("The battery (set, every 10%, empty)", isOn: $store.settings.sendBattery)
                            Toggle("Every alarm and snooze", isOn: $store.settings.sendAlarms)
                        }
                        .toggleStyle(.checkbox)
                    }
                    HStack(spacing: 12) {
                        Button("Send a test") { store.sendTest() }
                            .disabled(store.settings.endpoint == nil)
                        Button("Retry now (\(store.outbox.count) waiting)") { store.flush() }
                            .disabled(store.outbox.isEmpty || store.settings.endpoint == nil)
                        if store.sending { ProgressView().controlSize(.small) }
                        if let last = store.lastSend {
                            Text(last).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    Text("What a signal looks like:").font(.system(size: 11.5, weight: .semibold)).padding(.top, 4)
                    Text(store.sample)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.3)))
                }
                .font(.system(size: 12.5))
            }
            ChartBox(title: "The log", note: "\(store.log.entries.count) entries in \(store.logURL.lastPathComponent)") {
                Button("Clear the log…") { confirmClear = true }
                    .confirmationDialog("Clear every entry in the timer log?", isPresented: $confirmClear) {
                        Button("Clear the log", role: .destructive) { store.clearLog() }
                    }
            }
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 60, alignment: .trailing)
            content()
        }
    }
}
