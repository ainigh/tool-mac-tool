import AppKit
import AVFoundation
import SwiftUI
import ToolCore
import UniformTypeIdentifiers

/// A tool's own glass window, like the memory's: borderless, resizable, floating, ⌘W closes it.
@MainActor
enum GlassWindow {
    static let margin: CGFloat = 30

    /// `content` is handed the window's close action. `closed` runs when it closes (stop the mic).
    static func show<Content: View>(_ id: String, size: CGSize, minSize: CGSize, closed: @escaping () -> Void = {},
                                    content: @escaping (@escaping () -> Void) -> Content) {
        Windows.show(id) {
            let panel = GlassPanel(size: NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin),
                                   resizable: true)
            panel.level = .floating
            panel.minSize = NSSize(width: minSize.width + 2 * margin, height: minSize.height + 2 * margin)
            let close = {
                closed()
                panel.orderOut(nil)
            }
            let host = FirstClickHostingView(rootView: content(close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close]
            panel.center()
            panel.setFrameAutosaveName("ToolMacTool.\(id)")
            return panel
        }
    }

    /// Where Glass keeps its files (the memory's folder's parent).
    static var glassFolder: URL {
        MemoryStore.forCurrentUser().url.deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// The layout every glass tool shares: the status (a light and a few words) with the tool's
/// controls and a close button, the tool itself, the glowing line (filling up like a progress bar
/// when there's `progress`), and a row of actions under it.
struct GlassScaffold<Main: View, Controls: View, Footer: View>: View {
    let clock: GlassClock
    let mood: GlassMood
    let dot: StatusDot.Kind
    let status: String
    let ink: Double
    let progress: Double?
    let close: () -> Void
    let controls: Controls
    let main: Main
    let footer: Footer
    @Environment(\.controlActiveState) private var active

    init(clock: GlassClock, mood: GlassMood, dot: StatusDot.Kind, status: String, ink: Double,
         progress: Double? = nil, close: @escaping () -> Void,
         @ViewBuilder controls: () -> Controls, @ViewBuilder main: () -> Main, @ViewBuilder footer: () -> Footer) {
        self.clock = clock
        self.mood = mood
        self.dot = dot
        self.status = status
        self.ink = ink
        self.progress = progress
        self.close = close
        self.controls = controls()
        self.main = main()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 9) {
                    StatusDot(kind: dot, hue: ink)
                    Text(status)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(dot == .trouble ? Color(red: 1, green: 0.7, blue: 0.75) : .white.opacity(0.72))
                .padding(.leading, 8)
                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .help("Drag to move")
                controls
                GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
                    .padding(.leading, 2)
            }
            .padding(.leading, 18)
            .padding(.trailing, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            main
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            GlowLine(clock: clock, mood: mood, paused: mood == .idle && active == .inactive)
                .overlay(alignment: .leading) {
                    if let progress {
                        GeometryReader { g in
                            Capsule()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: max(4, g.size.width * progress), height: 2)
                                .shadow(color: .hsl(ink, 1, 0.75), radius: 6)
                        }
                        .frame(height: 2)
                        .animation(.easeOut(duration: 0.5), value: progress)
                    }
                }
                .padding(.horizontal, 26)
            footer
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
        }
        .background(GlassCard(clock: clock, mood: mood, paused: mood == .idle && active == .inactive))
        .padding(GlassWindow.margin)
        .opacity(active == .inactive ? 0.94 : 1)
        .animation(.easeInOut(duration: 0.25), value: active)
        .environment(\.colorScheme, .dark)
    }
}

/// A big, rounded text editor on the glass, with a hint while it's empty.
struct GlassEditor: View {
    @Binding var text: String
    let hint: String
    let ink: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(Ink.prompt(ink))
                .tint(.white)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
            if text.isEmpty {
                Text(hint)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Ink.reply(ink))
                    .opacity(0.5)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A pill with the current choice that opens a menu of the others.
struct MenuPill: View {
    let title: String
    let help: String
    let items: [(String, Bool, () -> Void)]
    @State private var hover = false

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold)).opacity(0.6)
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(hover ? 0.2 : 0.1)))
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .help(help)
    }

    func showMenu() {
        let menu = NSMenu()
        for (name, on, run) in items {
            let item = ActionMenuItem(title: name, run: run)
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// The voice and speed every tool speaks with.
struct VoiceChoice: View {
    @State private var voice = VoiceSettings.voice
    @State private var speed = VoiceSettings.speed

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        HStack(spacing: 6) {
            MenuPill(title: voice.name,
                     help: "The voice (all the chats speak with it too): Kokoro, open source, running on this Mac",
                     items: NeuralVoice.all.map { v -> (String, Bool, () -> Void) in
                         (VoiceSettings.label(v), v == voice, {
                             VoiceSettings.voice = v
                             voice = v
                             Speaker.preview()
                         })
                     })
            MenuPill(title: Self.speedLabel(speed), help: "How fast it speaks",
                     items: Self.speeds.map { s -> (String, Bool, () -> Void) in
                         (Self.speedLabel(s), s == speed, {
                             VoiceSettings.speed = s
                             speed = s
                         })
                     })
        }
    }

    static func speedLabel(_ s: Double) -> String {
        (s == s.rounded() ? String(Int(s)) : String(s)) + "×"
    }
}

// MARK: - Read aloud (TTS)

@MainActor
enum ReadAloudWindow {
    static func show(_ speaker: Speaker) {
        GlassWindow.show("read-aloud", size: CGSize(width: 600, height: 520), minSize: CGSize(width: 440, height: 320),
                         closed: { speaker.stop() }) { close in
            ReadAloudView(speaker: speaker, close: close)
        }
    }
}

/// Paste or type something and it's read out, the word being said lit up as it goes.
struct ReadAloudView: View {
    @ObservedObject var speaker: Speaker
    @ObservedObject private var neural = Neural.shared
    let close: () -> Void
    @AppStorage("readAloudText") private var text = ""
    @State private var message: String?
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)

    var words: Int { text.split(whereSeparator: \.isWhitespace).count }

    var body: some View {
        GlassScaffold(clock: clock, mood: speaker.speaking && !speaker.paused ? .streaming : .idle,
                      dot: speaker.speaking ? (speaker.paused ? .thinking : .streaming) : .ready,
                      status: speaker.speaking
                          ? (speaker.paused ? "Paused"
                             : neural.voices.isReady ? "Reading…" : "Reading with the Mac's voice while \(VoiceSettings.voice.name) gets ready…")
                          : (message ?? Neural.status(neural.voices, what: "the voices") ?? "Read aloud"),
                      ink: ink, close: close) {
            VoiceChoice()
        } main: {
            if speaker.speaking {
                ScrollView {
                    reading
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
            } else {
                GlassEditor(text: $text, hint: "Paste or type what to read, then press Read.", ink: ink)
            }
        } footer: {
            HStack(spacing: 8) {
                if speaker.speaking {
                    PillButton(title: speaker.paused ? "Resume" : "Pause", prominent: true) {
                        speaker.paused ? speaker.resume() : speaker.pause()
                    }
                    PillButton(title: "Stop") { speaker.stop() }
                } else {
                    PillButton(title: "Read", prominent: !text.isEmpty) { read() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    PillButton(title: "Paste & read") {
                        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                            text = s
                            read()
                        }
                    }
                    PillButton(title: "Save audio…") { saveAudio() }
                        .disabled(text.isEmpty)
                }
                Spacer()
                KeyHint(key: "⌘⏎", does: "read")
                Text("\(words) words · ~\(Self.minutes(words)) min")
                    .monospacedDigit()
            }
        }
        .onAppear { _ = Neural.shared.voiceModel() }      // the first time, start downloading it now
    }

    /// What's being read, the word being said in white.
    var reading: Text {
        let s = speaker.current
        let base = Text(s)
        guard let r = speaker.word, let range = Range(r, in: s) else {
            return base.font(.system(size: 19, weight: .semibold, design: .rounded))
        }
        return (Text(s[..<range.lowerBound])
                + Text(s[range]).foregroundColor(.white).underline(color: .white.opacity(0.6))
                + Text(s[range.upperBound...]).foregroundColor(Ink.prompt(ink).opacity(0.75)))
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .foregroundColor(Ink.prompt(ink).opacity(0.45))
    }

    func read() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        message = nil
        ink = clock.frame.hue
        clock.nudge()
        speaker.stop()
        speaker.say(t)
    }

    func saveAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Read aloud.wav"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        message = "Saving \(url.lastPathComponent)…"
        SpeechRecorder.record(text, to: url) { problem in
            message = problem.map { "Couldn't save: \($0)" } ?? "Saved \(url.lastPathComponent)"
            if problem == nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    static func minutes(_ words: Int) -> Int {
        max(1, Int((Double(words) / (160 * VoiceSettings.speed)).rounded(.up)))
    }
}

// MARK: - Dictate (STT)

@MainActor
enum DictateWindow {
    static func show(_ listener: Listener) {
        GlassWindow.show("dictate", size: CGSize(width: 600, height: 480), minSize: CGSize(width: 440, height: 300),
                         closed: { listener.stop() }) { close in
            DictateView(listener: listener, close: close)
        }
    }
}

/// Talk and it's written down, as long as you like; pauses don't stop it. Edit it when you've
/// stopped, then copy it or keep it with Glass's other dictations (glass-dictation-<date>.md).
struct DictateView: View {
    @ObservedObject var listener: Listener
    @ObservedObject private var neural = Neural.shared
    let close: () -> Void
    @AppStorage("dictationDraft") private var note = ""
    /// The note as it was when listening started; what's heard goes after it.
    @State private var before = ""
    @State private var message: String?
    @State private var savedTo: URL?
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)

    var words: Int { note.split(whereSeparator: \.isWhitespace).count }
    /// Listening, or writing down the last words after Stop.
    var listening: Bool { listener.on || listener.finishing }

    var body: some View {
        GlassScaffold(clock: clock, mood: listener.on ? (listener.level > 0.35 ? .streaming : .typing) : .idle,
                      dot: listener.problem != nil ? .trouble : listening ? .streaming : .ready,
                      status: Neural.status(neural.ears, what: "speech recognition").map { listening ? $0 + " (it's recording meanwhile)" : $0 }
                          ?? (listener.on ? "Listening… pauses are fine"
                              : listener.finishing ? "Writing down the last words…" : (message ?? "Dictate")),
                      ink: ink, close: close) {
            EmptyView()
        } main: {
            VStack(spacing: 10) {
                if let problem = listener.problem {
                    VoiceProblem(text: problem, action: "Try again") { listener.on ? listener.start() : record() }
                }
                if listening {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(note.isEmpty ? "…" : note)
                                .font(.system(size: 17, weight: .medium, design: .rounded))
                                .foregroundColor(Ink.prompt(ink))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 5)
                            Color.clear.frame(height: 1).id("end")
                        }
                        .onChange(of: note) { _ in proxy.scrollTo("end", anchor: .bottom) }
                    }
                } else {
                    GlassEditor(text: $note, hint: "Press Record and talk. Your words appear here.", ink: ink)
                }
            }
        } footer: {
            HStack(spacing: 8) {
                PillButton(title: listener.on ? "Stop" : "Record", prominent: true) {
                    listener.on ? listener.stop() : record()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(listener.finishing)
                PillButton(title: "Keep note") { keep() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || listening)
                PillButton(title: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note, forType: .string)
                    message = "Copied"
                }
                .disabled(note.isEmpty)
                PillButton(title: "Clear") { note = "" }
                    .disabled(note.isEmpty || listening)
                Spacer()
                if let savedTo {
                    Button { NSWorkspace.shared.show(savedTo) } label: { Text(savedTo.lastPathComponent).underline() }
                        .buttonStyle(.plain)
                        .help("Show in Finder (Glass lists it with its transcripts)")
                }
                Text("\(words) words").monospacedDigit()
            }
        }
        .onChange(of: listener.text) { heard in
            guard listening, !heard.isEmpty else { return }
            note = before.isEmpty ? heard : before + (before.hasSuffix("\n") ? "" : " ") + heard
        }
        .onChange(of: listener.level) { level in
            if level > 0.5 { clock.nudge(0.04) }
        }
        .onAppear { _ = Neural.shared.earModel() }        // the first time, start downloading it now
    }

    func record() {
        before = note.trimmingCharacters(in: .whitespaces)
        message = nil
        ink = clock.frame.hue
        listener.start()
    }

    /// Adds the note to today's glass-dictation file and empties the box for the next one.
    func keep() {
        do {
            let url = try Dictation.append(note, folder: GlassWindow.glassFolder)
            savedTo = url
            message = "Kept in \(url.lastPathComponent)"
            note = ""
            clock.ripple(x: 0.5, y: 0.5, hue: 150)
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

// MARK: - Transcribe a file

@MainActor
enum TranscribeWindow {
    static func show(_ model: TranscribeModel) {
        GlassWindow.show("transcribe", size: CGSize(width: 620, height: 520), minSize: CGSize(width: 460, height: 320)) { close in
            TranscribeView(model: model, close: close)
        }
    }
}

/// One audio file at a time, turned into timed text that can be copied or saved as text or
/// subtitles. It keeps going with the window closed.
@MainActor
final class TranscribeModel: ObservableObject {
    @Published private(set) var file: URL?
    @Published private(set) var segments: [TimedText] = []
    @Published private(set) var progress = 0.0
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published var problem: String?
    private var job: FileTranscriber?

    var name: String { file?.lastPathComponent ?? "" }

    func start(_ url: URL) {
        job?.cancel()
        file = url
        segments = []
        progress = 0
        running = true
        finished = false
        problem = nil
        let job = FileTranscriber()
        self.job = job
        job.onSegment = { [weak self, weak job] s in
            guard let self, self.job === job else { return }
            self.segments.append(s)
        }
        job.onProgress = { [weak self, weak job] p in
            guard let self, self.job === job else { return }
            self.progress = p
        }
        job.onDone = { [weak self, weak job] problem in
            guard let self, self.job === job else { return }
            self.running = false
            self.job = nil
            if let problem {
                if problem != "Stopped" { self.problem = problem }
            } else {
                self.finished = true
                self.progress = 1
            }
        }
        job.start(url)
    }

    func stop() { job?.cancel() }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Captions.plain(segments), forType: .string)
    }

    enum Format: String { case txt, srt, vtt }

    func export(_ format: Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.nameFieldStringValue = (file?.deletingPathExtension().lastPathComponent ?? "Transcript") + "." + format.rawValue
        if let file { panel.directoryURL = file.deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        switch format {
        case .txt: text = Captions.plain(segments)
        case .srt: text = Captions.srt(segments)
        case .vtt: text = Captions.vtt(segments)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

struct TranscribeView: View {
    @ObservedObject var model: TranscribeModel
    @ObservedObject private var neural = Neural.shared
    let close: () -> Void
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @State private var dropping = false

    var status: String {
        if model.running, let getting = Neural.status(neural.ears, what: "speech recognition") { return getting }
        if model.running { return "Transcribing \(model.name)… \(Int(model.progress * 100))%" }
        if model.finished { return "Done: \(model.name)" }
        return "Transcribe a file"
    }

    var body: some View {
        GlassScaffold(clock: clock, mood: model.problem != nil ? .error : model.running ? .thinking : .idle,
                      dot: model.problem != nil ? .trouble : model.running ? .thinking : .ready,
                      status: status, ink: ink, progress: model.running ? model.progress : nil, close: close) {
            EmptyView()
        } main: {
            VStack(spacing: 10) {
                if let problem = model.problem {
                    VoiceProblem(text: problem, action: "Choose another") { model.choose() }
                }
                if model.segments.isEmpty {
                    dropZone
                } else {
                    lines
                }
            }
        } footer: {
            HStack(spacing: 8) {
                if model.running {
                    PillButton(title: "Stop", prominent: true) { model.stop() }
                } else {
                    PillButton(title: "Choose file…", prominent: model.segments.isEmpty) { model.choose() }
                }
                PillButton(title: "Copy") { model.copy() }.disabled(model.segments.isEmpty)
                PillButton(title: ".txt") { model.export(.txt) }.disabled(model.segments.isEmpty)
                PillButton(title: ".srt") { model.export(.srt) }.disabled(model.segments.isEmpty)
                PillButton(title: ".vtt") { model.export(.vtt) }.disabled(model.segments.isEmpty)
                Spacer()
                if let last = model.segments.last {
                    Text("\(model.segments.count) lines · \(Captions.clock(last.end))").monospacedDigit()
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.start(url) } }
            }
            return true
        }
        .onChange(of: model.running) { running in
            if running { ink = clock.frame.hue } else { clock.ripple(x: 0.5, y: 0.5, power: 0.8) }
        }
    }

    var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Ink.reply(ink))
            Text(model.running ? "Listening to \(model.name)…" : "Drop an audio file here")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.reply(ink))
            Text("mp3, m4a, wav, aiff and the sound of a video. It's transcribed on this Mac when it can be.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
            .foregroundStyle(.white.opacity(dropping ? 0.6 : 0.18)))
    }

    var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.segments.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(Captions.clock(s.start))
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 48, alignment: .trailing)
                            Text(s.text)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .foregroundStyle(Ink.prompt(ink))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(i)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.segments.count) { n in
                if model.running, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}
