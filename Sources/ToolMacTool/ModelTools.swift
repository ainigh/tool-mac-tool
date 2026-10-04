import AppKit
import AVFoundation
import SwiftUI
import ToolCore

/// Runs the tools built into the app when the chat's model calls them. All one way: what goes
/// back to the model is only that it was done (the diagram is drawn by the diagram tool's own
/// model, and the chat never sees it).
@MainActor
final class ModelTools {
    static let shared = ModelTools()

    /// The app, for the diagram tool.
    weak var app: AppModel?
    /// Closes the chat's window (set when the window is made).
    var closeChat: (() -> Void)?

    func run(_ tool: BuiltinTool, call: ToolCall) -> (result: String, shown: String) {
        let arg = BuiltinTool.argument(call, tool.kind)
        switch tool.kind {
        case .drawDiagram:
            guard let app, !arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("Nothing to draw: give a description.", "Diagram (no description)")
            }
            DiagramWindow.show(app.diagram)
            app.diagram.request(arg)
            return ("Done: the diagram is being drawn in its own window on the user's screen. You can't see it.", "Diagram")
        case .soundAlarm:
            let seconds = BuiltinTool.seconds(arg)
            Alarm.shared.sound(for: seconds)
            return ("Done: the alarm is sounding for \(seconds) seconds (the user can stop it).", "Alarm, \(seconds) s")
        case .openURL:
            guard let url = BuiltinTool.webURL(arg) else {
                return ("That isn't a web address that can be opened (it must be http or https): \(arg)", "Open link (refused)")
            }
            NSWorkspace.shared.open(url)
            return ("Done: \(url.absoluteString) is open in the user's browser.", "Opened \(url.host ?? url.absoluteString)")
        case .copyText:
            Clipboard.copy(arg)
            return ("Done: the text is on the clipboard (\(arg.count) characters).", "Copied \(arg.count) characters")
        case .closeWindow:
            // A moment later, so the reply can finish first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.closeChat?() }
            return ("Done: the chat window is closing.", "Closed the chat")
        }
    }
}

// MARK: - The alarm

/// A loud, repeating two-tone beep for a number of seconds, with a small glass card to stop it.
@MainActor
final class Alarm: ObservableObject {
    static let shared = Alarm()

    @Published private(set) var sounding = false
    @Published private(set) var endsAt: Date?

    /// Shared with nothing else; it takes care of the audio hardware coming and going (see TonePlayer).
    private let sounds = TonePlayer()
    private var stopTask: Task<Void, Never>?

    func sound(for seconds: Int) {
        stop()
        let seconds = max(1, seconds)
        sounds.play(Self.pattern(), loops: true, volume: 0.9, for: "alarm", maxSeconds: TimeInterval(seconds))
        sounding = true
        endsAt = Date().addingTimeInterval(TimeInterval(seconds))
        showCard()
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        sounds.stop("alarm")
        sounding = false
        endsAt = nil
        BigCards.shared.hide("model-alarm")
    }

    /// One second: two short beeps (880 and 1175 Hz), then quiet.
    static func pattern() -> AVAudioPCMBuffer {
        let format = TonePlayer.format
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var v = 0.0
            for (start, freq) in [(0.0, 880.0), (0.22, 1174.7)] where t >= start && t < start + 0.18 {
                let local = t - start
                let envelope = min(1, local / 0.01) * min(1, (0.18 - local) / 0.01)
                v = sin(2 * .pi * freq * t) * envelope * 0.6
            }
            data[i] = Float(v)
        }
        return buffer
    }

    /// A big card covering the top middle quarter of the screen, with the seconds left and Stop.
    private func showCard() {
        BigCards.shared.show("model-alarm", at: .topCenter, onEscape: { [weak self] in self?.stop() }) { size in
            AlarmCard(alarm: self, size: size)
        }
    }
}

struct AlarmCard: View {
    @ObservedObject var alarm: Alarm
    let size: NSSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = alarm.endsAt.map { max(0, Int($0.timeIntervalSince(context.date).rounded())) } ?? 0
            BigCard(size: size, symbol: "alarm.fill", accent: Color(red: 1, green: 0.55, blue: 0.5), name: "Alarm",
                    headline: "ALARM", line: "\(left) s left", mood: .error, close: { alarm.stop() }) {
                HStack {
                    Spacer()
                    BigButton(title: "Stop", symbol: "stop.fill", prominent: true, height: max(36, size.height * 0.1)) { alarm.stop() }
                }
            }
        }
    }
}

// MARK: - This Mac

/// What this Mac is (model, chip, memory, cores, macOS) and when it started up, read once.
enum MacFacts {
    private static var hardware: (model: String, chip: String)?

    /// Reads the marketing name and chip in the background (system_profiler is slow), so later
    /// messages have them.
    static func prepare() {
        guard hardware == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let out = (try? Updater.run("/usr/sbin/system_profiler", ["SPHardwareDataType"])) ?? Data()
            var model = "", chip = ""
            for line in String(decoding: out, as: UTF8.self).components(separatedBy: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "Model Name" { model = parts[1] }
                if parts[0] == "Chip" || parts[0] == "Processor Name" { chip = parts[1] }
            }
            DispatchQueue.main.async { hardware = (model, chip) }
        }
    }

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    static var bootedAt: Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    static func describe(now: Date = Date(), zone: TimeZone) -> String {
        prepare()
        let model = hardware?.model.isEmpty == false ? hardware!.model : sysctl("hw.model")
        let chip = hardware?.chip.isEmpty == false ? hardware!.chip : sysctl("machdep.cpu.brand_string")
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let system = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        let memory = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return MacInfo.describe(model: model, chip: chip, memoryGB: memory, cores: ProcessInfo.processInfo.processorCount,
                                system: system, bootedAt: bootedAt, now: now, zone: zone)
    }
}

// MARK: - The Model tools window

@MainActor
enum ModelToolsWindow {
    static let focus = Focus()

    final class Focus: ObservableObject {
        @Published var kind: BuiltinTool.Kind? = .drawDiagram
    }

    static func show(_ kind: BuiltinTool.Kind? = nil) {
        if let kind { focus.kind = kind }
        Windows.show("model-tools", title: "Model tools", size: NSSize(width: 820, height: 560)) {
            ModelToolsView(prefs: .shared, focus: focus, alarm: .shared)
        }
    }
}

/// The tools built into the app: on or off, when the model should call each, and a way to try it.
struct ModelToolsView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var focus: ModelToolsWindow.Focus
    @ObservedObject var alarm: Alarm
    @State private var trial = ""
    @State private var seconds = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Let the chat's model use tools (these and your shortcuts)", isOn: $prefs.settings.toolsOn)
                .toggleStyle(.switch)
            Text("The chat's model calls these when what you ask matches their description. They're one way: the model is only told it was done, and carries on.")
                .font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                List(selection: $focus.kind) {
                    ForEach(prefs.settings.builtins) { t in
                        HStack {
                            Image(systemName: t.kind.symbol).frame(width: 20)
                            Text(t.kind.title)
                            Spacer()
                            if !t.enabled { Text("off").foregroundStyle(.secondary) }
                        }
                        .tag(t.kind)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(width: 240)
                if let kind = focus.kind {
                    editor(kind)
                } else {
                    Spacer()
                }
            }
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 440)
    }

    func editor(_ kind: BuiltinTool.Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind.title).font(.title3.weight(.semibold))
                Spacer()
                Toggle("On", isOn: field(kind, \.enabled))
            }
            LabeledContent("The model calls it") {
                Text(kind.rawValue).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            Text("When to call it").font(.headline)
            TextEditor(text: field(kind, \.description))
                .font(.system(size: 13))
                .frame(minHeight: 110)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Restore default") {
                    field(kind, \.description).wrappedValue = kind.defaultDescription
                }
            }
            Divider()
            Text("Try it").font(.headline)
            tryRow(kind)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder func tryRow(_ kind: BuiltinTool.Kind) -> some View {
        switch kind {
        case .soundAlarm:
            HStack {
                Slider(value: $seconds, in: 1...30, step: 1) { Text("Seconds") }
                Text("\(Int(seconds)) s").monospacedDigit().frame(width: 40)
                Button(alarm.sounding ? "Stop" : "Sound it") {
                    if alarm.sounding { alarm.stop() } else { alarm.sound(for: Int(seconds)) }
                }
            }
        case .closeWindow:
            Text("Say \u{201C}close\u{201D} or \u{201C}exit\u{201D} while the chat listens and it closes straight away; longer ways of saying it go through the model and this tool.")
                .font(.callout).foregroundStyle(.secondary)
        default:
            HStack {
                TextField("Input", text: $trial, prompt: Text(placeholder(kind))).textFieldStyle(.roundedBorder)
                Button("Run") {
                    let arg: String
                    switch kind {
                    case .drawDiagram: arg = "description"
                    case .openURL: arg = "url"
                    default: arg = "text"
                    }
                    let tool = prefs.settings.builtins.first { $0.kind == kind } ?? BuiltinTool(kind: kind)
                    _ = ModelTools.shared.run(tool, call: ToolCall(name: kind.rawValue, arguments: [arg: trial]))
                }
                .disabled(trial.isEmpty)
            }
        }
    }

    func placeholder(_ kind: BuiltinTool.Kind) -> String {
        switch kind {
        case .drawDiagram: return "e.g. how a web request reaches the database"
        case .openURL: return "e.g. apple.com"
        default: return "Text to copy"
        }
    }

    func field<T>(_ kind: BuiltinTool.Kind, _ key: WritableKeyPath<BuiltinTool, T>) -> Binding<T> {
        Binding(get: { (prefs.settings.builtins.first { $0.kind == kind } ?? BuiltinTool(kind: kind))[keyPath: key] },
                set: { value in
                    if let i = prefs.settings.builtins.firstIndex(where: { $0.kind == kind }) {
                        prefs.settings.builtins[i][keyPath: key] = value
                    }
                })
    }
}
