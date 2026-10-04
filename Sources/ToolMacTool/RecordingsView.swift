import AppKit
import AVFoundation
import AVKit
import SwiftUI
import ToolCore

// Record audio (the microphone only, to an .m4a) and Recordings: every video and audio file in the
// Glass folder in a grid on a big glass panel, to play and to transcribe. A transcript is saved
// beside its recording, with the same name and .txt at the end.

// MARK: - Record audio

@MainActor
final class AudioRecorder: ObservableObject {
    enum State { case idle, recording, paused }

    @Published private(set) var state = State.idle
    /// Seconds recorded so far (pauses left out).
    @Published private(set) var elapsed = 0.0
    /// How loud it is, 0 to 1.
    @Published private(set) var level: Float = 0
    @Published private(set) var lastSaved: URL?
    @Published var problem: String?
    /// Called with each recording that was saved.
    var onSaved: ((URL) -> Void)?

    private var recorder: AVAudioRecorder?
    private var ticker: Timer?

    func start() {
        guard state == .idle else { return }
        problem = nil
        Listener.authorize { [weak self] problem in
            guard let self else { return }
            if let problem { self.problem = problem } else { self.begin() }
        }
    }

    private func begin() {
        let folder = GlassWindow.glassFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: Recordings.newURL(.audio, folder: folder), settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                problem = "Couldn't start recording (is a microphone connected?)"
                return
            }
            recorder = r
            state = .recording
            elapsed = 0
            ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            problem = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        state = .paused
        level = 0
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        if recorder.record() { state = .recording } else { problem = "Couldn't carry on recording" }
    }

    /// Stops and keeps it.
    func stop() {
        guard let recorder else { return }
        let url = recorder.url
        let long = recorder.currentTime
        recorder.stop()
        end()
        if long > 0 || FileManager.default.fileExists(atPath: url.path) {
            lastSaved = url
            onSaved?(url)
        }
    }

    /// Stops and throws it away.
    func discard() {
        guard let recorder else { return }
        recorder.stop()
        recorder.deleteRecording()
        end()
    }

    private func end() {
        ticker?.invalidate()
        ticker = nil
        recorder = nil
        state = .idle
        level = 0
    }

    private func tick() {
        guard let recorder, state != .idle else { return }
        elapsed = recorder.currentTime
        guard state == .recording else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = level * 0.5 + max(0, min(1, (db + 55) / 45)) * 0.5
    }
}

@MainActor
enum AudioRecorderWindow {
    static func show(_ recorder: AudioRecorder, recordings: @escaping () -> Void) {
        GlassWindow.show("record-audio", size: CGSize(width: 520, height: 320), minSize: CGSize(width: 440, height: 260),
                         closed: { recorder.stop() }) { close in
            AudioRecorderView(recorder: recorder, close: close, recordings: recordings)
        }
    }
}

/// Record (⌘R), Pause, Resume, Stop: the microphone to glass-audio-<time>.m4a in the Glass folder.
struct AudioRecorderView: View {
    @ObservedObject var recorder: AudioRecorder
    let close: () -> Void
    let recordings: () -> Void
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)

    var status: String {
        switch recorder.state {
        case .recording: return "Recording…"
        case .paused: return "Paused"
        case .idle: return recorder.lastSaved.map { "Saved \($0.lastPathComponent)" } ?? "Record audio"
        }
    }

    var body: some View {
        GlassScaffold(clock: clock, mood: recorder.state == .recording ? (recorder.level > 0.35 ? .streaming : .typing) : .idle,
                      dot: recorder.problem != nil ? .trouble : recorder.state == .recording ? .streaming
                          : recorder.state == .paused ? .thinking : .ready,
                      status: status, ink: ink, close: close) {
            EmptyView()
        } main: {
            VStack(spacing: 16) {
                if let problem = recorder.problem {
                    VoiceProblem(text: problem, action: "Try again") { recorder.start() }
                }
                Spacer(minLength: 0)
                Text(Captions.clock(recorder.elapsed))
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Ink.reply(ink))
                LevelBars(level: recorder.state == .recording ? recorder.level : 0, ink: ink)
                    .frame(height: 28)
                    .opacity(recorder.state == .idle ? 0.25 : 1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        } footer: {
            HStack(spacing: 8) {
                switch recorder.state {
                case .idle:
                    PillButton(title: "Record", prominent: true) {
                        ink = clock.frame.hue
                        clock.nudge()
                        recorder.start()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                case .recording, .paused:
                    PillButton(title: recorder.state == .paused ? "Resume" : "Pause", prominent: true) {
                        recorder.state == .paused ? recorder.resume() : recorder.pause()
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    PillButton(title: "Stop") {
                        recorder.stop()
                        clock.ripple(x: 0.5, y: 0.5, hue: 150)
                    }
                    PillButton(title: "Discard") { recorder.discard() }
                }
                PillButton(title: "Recordings") { recordings() }
                Spacer()
                if let saved = recorder.lastSaved, recorder.state == .idle {
                    Button { NSWorkspace.shared.show(saved) } label: { Text(saved.lastPathComponent).underline() }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                } else {
                    KeyHint(key: "⌘R", does: recorder.state == .idle ? "record" : recorder.state == .paused ? "resume" : "pause")
                }
            }
        }
        .onChange(of: recorder.level) { level in
            if level > 0.5 { clock.nudge(0.04) }
        }
    }
}

/// A row of bars that rise with how loud it is.
struct LevelBars: View {
    let level: Float
    let ink: Double
    static let count = 24

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<Self.count, id: \.self) { i in
                let middle = 1 - abs(Double(i) - Double(Self.count - 1) / 2) / (Double(Self.count) / 2)
                Capsule()
                    .fill(Color.hsl(ink + Double(i) * 6, 0.95, 0.75))
                    .frame(width: 5, height: max(4, 28 * CGFloat(Double(level) * (0.35 + 0.65 * middle))))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

// MARK: - Recordings

/// The recordings in the Glass folder, what's known about each (length, sound, a picture), and
/// transcribing them, one at a time, into <name>.txt beside each.
@MainActor
final class RecordingsModel: ObservableObject {
    struct Info {
        var duration: Double?
        var hasSound: Bool?
        var thumbnail: NSImage?
    }

    @Published private(set) var items: [Recordings.Item] = []
    @Published private(set) var info: [Recordings.Item: Info] = [:]
    /// The recordings that have a transcript beside them (by id).
    @Published private(set) var transcripts: Set<String> = []
    /// The one being transcribed, how far it's got and its lines so far; the ones waiting.
    @Published private(set) var transcribing: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var segments: [TimedText] = []
    @Published private(set) var waiting: [String] = []
    /// What went wrong, by recording.
    @Published private(set) var problems: [String: String] = [:]
    @Published private(set) var problem: String?
    /// The recording open on its own (playing, with its transcript).
    @Published var selected: Recordings.Item?
    @Published private(set) var transcriptText = ""

    var folder: URL { GlassWindow.glassFolder }
    private var job: FileTranscriber?

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    func reload() {
        let folder = self.folder
        do {
            items = try Recordings.list(in: folder)
            problem = nil
        } catch {
            items = []
            problem = FileManager.default.fileExists(atPath: folder.path) ? "Couldn't read \(folder.path): \(error.localizedDescription)" : nil
        }
        transcripts = Set(items.filter { FileManager.default.fileExists(atPath: $0.transcript.path) }.map(\.id))
        let current = Set(items)
        info = info.filter { current.contains($0.key) }
        for item in items where info[item] == nil { load(item) }
        if let selected, !items.contains(where: { $0.id == selected.id }) { self.selected = nil }
    }

    /// Its length, whether it has sound, and a picture from early on.
    private func load(_ item: Recordings.Item) {
        info[item] = Info()
        Task {
            let asset = AVURLAsset(url: item.url)
            var found = Info()
            if let duration = try? await asset.load(.duration), duration.isNumeric { found.duration = duration.seconds }
            if let tracks = try? await asset.loadTracks(withMediaType: .audio) { found.hasSound = !tracks.isEmpty }
            if item.isVideo {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 720, height: 720)
                let at = CMTime(seconds: min(1, (found.duration ?? 0) / 2), preferredTimescale: 600)
                if let picture = try? await generator.image(at: at) {
                    found.thumbnail = NSImage(cgImage: picture.image, size: .zero)
                }
            }
            if self.info[item] != nil { self.info[item] = found }
        }
    }

    func select(_ item: Recordings.Item?) {
        selected = item
        loadTranscript()
    }

    private func loadTranscript() {
        guard let selected else {
            transcriptText = ""
            return
        }
        transcriptText = (try? String(contentsOf: selected.transcript, encoding: .utf8)) ?? ""
    }

    func isWaiting(_ item: Recordings.Item) -> Bool { waiting.contains(item.id) }
    func isTranscribing(_ item: Recordings.Item) -> Bool { transcribing == item.id }
    func hasTranscript(_ item: Recordings.Item) -> Bool { transcripts.contains(item.id) }

    /// Writes down what's said in it, into <name>.txt beside it (after the ones already waiting).
    func transcribe(_ item: Recordings.Item) {
        guard !isTranscribing(item), !isWaiting(item) else { return }
        problems[item.id] = nil
        waiting.append(item.id)
        _ = Neural.shared.earModel()                    // the first time, start downloading it now
        next()
    }

    /// Stops it, or takes it out of the queue.
    func cancel(_ item: Recordings.Item) {
        guard isTranscribing(item) else {
            waiting.removeAll { $0 == item.id }
            return
        }
        // Still taking a video's sound out (no job yet): it stops as soon as that's done.
        if let job { job.cancel() } else { stopping = item.id }
    }

    /// A transcription stopped before its job started.
    private var stopping: String?

    private func next() {
        guard transcribing == nil, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard let item = items.first(where: { $0.id == id }) else { return next() }
        transcribing = id
        progress = 0
        segments = []
        Task {
            do {
                // A video's sound is taken out first, so the transcriber reads plain audio.
                let audio = item.isVideo ? try await Self.soundTrack(of: item.url) : item.url
                if self.stopping == id {
                    if item.isVideo { try? FileManager.default.removeItem(at: audio) }
                    return self.done(item, problem: "Stopped")
                }
                self.run(item, audio: audio, temporary: item.isVideo)
            } catch {
                self.done(item, problem: error.localizedDescription)
            }
        }
    }

    private func run(_ item: Recordings.Item, audio: URL, temporary: Bool) {
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
        job.onDone = { [weak self] problem in
            if temporary { try? FileManager.default.removeItem(at: audio) }
            self?.done(item, problem: problem)
        }
        job.start(audio)
    }

    private func done(_ item: Recordings.Item, problem: String?) {
        job = nil
        stopping = nil
        if let problem {
            if problem != "Stopped" { problems[item.id] = problem }
        } else {
            let text = segments.isEmpty ? "" : Captions.plain(segments)
            do {
                try text.write(to: item.transcript, atomically: true, encoding: .utf8)
                transcripts.insert(item.id)
                if selected?.id == item.id { loadTranscript() }
            } catch {
                problems[item.id] = "Couldn't save the transcript: \(error.localizedDescription)"
            }
        }
        transcribing = nil
        progress = 0
        next()
    }

    /// The sound of a video as an .m4a in the temporary folder.
    private static func soundTrack(of url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Problem("This recording has no sound to transcribe") }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Problem("Couldn't read its sound")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ToolMacTool-\(UUID().uuidString).m4a")
        export.outputURL = out
        export.outputFileType = .m4a
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { done.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw Problem("Couldn't read its sound: \(export.error?.localizedDescription ?? "the export failed")")
        }
        return out
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
    }

    /// To the Trash, with its transcript.
    func trash(_ item: Recordings.Item) {
        cancel(item)
        let fm = FileManager.default
        do {
            try fm.trashItem(at: item.url, resultingItemURL: nil)
            if fm.fileExists(atPath: item.transcript.path) { try? fm.trashItem(at: item.transcript, resultingItemURL: nil) }
        } catch {
            problems[item.id] = "Couldn't move it to the Trash: \(error.localizedDescription)"
        }
        if selected?.id == item.id { select(nil) }
        reload()
    }
}

@MainActor
enum RecordingsWindow {
    static let margin: CGFloat = 24

    /// As big as the diagram's canvas: 90% of the screen.
    static func show(_ app: AppModel) {
        let model = app.recordings
        Windows.show("recordings") {
            let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = NSSize(width: (screen.width * 0.9).rounded(), height: (screen.height * 0.9).rounded())
            let panel = GlassPanel(size: size)
            panel.level = .floating
            let close = {
                model.select(nil)
                panel.orderOut(nil)
            }
            let host = FirstClickHostingView(rootView: RecordingsView(model: model, app: app, close: close))
            host.sizingOptions = []
            panel.contentView = host
            panel.commands = ["w": close]
            panel.onEscape = {
                if model.selected != nil { model.select(nil) } else { close() }
                return true
            }
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2))
            return panel
        }
        if let panel = Windows.window("recordings") { GlassPanel.fit(panel) }
        model.reload()
    }

    static func hide() {
        Windows.window("recordings")?.orderOut(nil)
    }
}

/// Every recording in a grid; click one to play it beside its transcript.
struct RecordingsView: View {
    @ObservedObject var model: RecordingsModel
    @ObservedObject private var neural = Neural.shared
    let app: AppModel
    let close: () -> Void
    @State private var clock = GlassClock()
    @State private var ink = Double.random(in: 0..<360)
    @State private var filter = Filter.all
    @State private var player: AVPlayer?
    @Environment(\.controlActiveState) private var active

    enum Filter: String, CaseIterable {
        case all = "All", videos = "Videos", audio = "Audio"
    }

    var shown: [Recordings.Item] {
        switch filter {
        case .all: return model.items
        case .videos: return model.items.filter(\.isVideo)
        case .audio: return model.items.filter { !$0.isVideo }
        }
    }

    var mood: GlassMood { model.problem != nil ? .error : model.transcribing != nil ? .thinking : .idle }
    var still: Bool { mood == .idle && active == .inactive }

    var status: String {
        if let id = model.transcribing, let item = model.items.first(where: { $0.id == id }) {
            if let getting = Neural.status(neural.ears, what: "speech recognition") { return getting }
            return "Transcribing \(item.name)… \(Int(model.progress * 100))%"
        }
        if let problem = model.problem { return problem }
        let n = model.items.count
        return n == 0 ? "Recordings" : "Recordings · \(n)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Group {
                if let item = model.selected {
                    RecordingDetail(item: item, model: model, player: player, ink: ink)
                } else if shown.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            GlowLine(clock: clock, mood: mood, paused: still)
                .overlay(alignment: .leading) {
                    if model.transcribing != nil {
                        GeometryReader { g in
                            Capsule()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: max(4, g.size.width * model.progress), height: 2)
                                .shadow(color: .hsl(ink, 1, 0.75), radius: 6)
                        }
                        .frame(height: 2)
                        .animation(.easeOut(duration: 0.5), value: model.progress)
                    }
                }
                .padding(.horizontal, 26)
            footer
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
        }
        .background(GlassCard(clock: clock, mood: mood, paused: still, radius: 30))
        .padding(RecordingsWindow.margin)
        .environment(\.colorScheme, .dark)
        .onVisibleTick(every: 3) { model.reload() }
        .onChange(of: model.selected) { item in
            player?.pause()
            player = item.map { AVPlayer(url: $0.url) }
            player?.play()
        }
        .onChange(of: model.transcribing) { id in
            if id != nil { ink = clock.frame.hue } else { clock.ripple(x: 0.5, y: 0.5, power: 0.8) }
        }
    }

    var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 9) {
                StatusDot(kind: model.problem != nil ? .trouble : model.transcribing != nil ? .thinking : .ready, hue: ink)
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.leading, 8)
            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .help("Drag to move")
            ForEach(Filter.allCases, id: \.self) { f in
                PillButton(title: f.rawValue, prominent: filter == f) {
                    filter = f
                    model.select(nil)
                }
            }
            GlassIcon(symbol: "folder", help: "Show the folder in Finder (\(model.folder.path))") {
                NSWorkspace.shared.show(model.folder)
            }
            .padding(.leading, 6)
            GlassIcon(symbol: "xmark", help: "Close (⌘W)", action: close)
                .padding(.leading, 2)
        }
    }

    var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 18)], spacing: 22) {
                ForEach(shown) { item in
                    RecordingTile(item: item, model: model, ink: ink)
                }
            }
            .padding(.vertical, 6)
        }
    }

    var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Ink.reply(ink))
            Text(filter == .audio ? "No audio recordings yet" : filter == .videos ? "No screen recordings yet" : "No recordings yet")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Ink.reply(ink))
            Text("Record a box of the screen or your voice and it shows up here, ready to play and transcribe.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var footer: some View {
        HStack(spacing: 8) {
            PillButton(title: "Record screen", prominent: true) {
                close()
                app.screenRecorder.begin(audio: true)
            }
            .disabled(app.screenRecorder.busy)
            PillButton(title: "Screen only") {
                close()
                app.screenRecorder.begin(audio: false)
            }
            .disabled(app.screenRecorder.busy)
            PillButton(title: "Record audio") {
                AudioRecorderWindow.show(app.audioRecorder) { RecordingsWindow.show(app) }
            }
            if !model.waiting.isEmpty {
                Text("\(model.waiting.count) waiting to be transcribed").monospacedDigit()
            }
            Spacer()
            KeyHint(key: "esc", does: model.selected == nil ? "close" : "back")
            Text(model.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A recording in the grid: its picture (click to play), name, when, how long, and what to do with it.
struct RecordingTile: View {
    let item: Recordings.Item
    @ObservedObject var model: RecordingsModel
    let ink: Double
    @State private var hover = false

    var info: RecordingsModel.Info? { model.info[item] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.select(item) } label: { picture }
                .buttonStyle(.plain)
                .help("Play it, beside its transcript")
            Text(item.name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(RecordingTile.when(item))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            actions
            if let problem = model.problems[item.id] {
                Text(problem)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.75))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(hover ? 0.09 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(hover ? 0.2 : 0.08), lineWidth: 0.5))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            Button("Play") { model.select(item) }
            Button(model.hasTranscript(item) ? "Transcribe again" : "Transcribe") { model.transcribe(item) }
                .disabled(info?.hasSound == false || model.isTranscribing(item))
            if model.hasTranscript(item) {
                Button("Open the transcript") { NSWorkspace.shared.open(item.transcript) }
            }
            Button("Show in Finder") { NSWorkspace.shared.show(item.url) }
            Divider()
            Button("Move to Trash") { model.trash(item) }
        }
    }

    var picture: some View {
        Color.black.opacity(0.35)
            .aspectRatio(1.6, contentMode: .fit)
            .overlay {
                if let image = info?.thumbnail {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isVideo ? "film" : "waveform")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Ink.reply(ink))
                }
            }
            .overlay {
                if hover {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.4), radius: 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let duration = info?.duration {
                    Badge(text: Captions.clock(duration))
                        .padding(7)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 5) {
                    if !item.isVideo { Badge(text: "Audio", symbol: "waveform") }
                    if info?.hasSound == false { Badge(text: "No sound", symbol: "speaker.slash") }
                    if model.hasTranscript(item) { Badge(text: "Transcript", symbol: "text.alignleft") }
                }
                .padding(7)
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder var actions: some View {
        HStack(spacing: 6) {
            if model.isTranscribing(item) {
                ActionChip(title: "Stop · \(Int(model.progress * 100))%", symbol: "stop.fill", help: "Stop transcribing") {
                    model.cancel(item)
                }
            } else if model.isWaiting(item) {
                ActionChip(title: "Waiting…", symbol: "clock", help: "Waiting its turn: click to take it out") {
                    model.cancel(item)
                }
            } else if model.hasTranscript(item) {
                ActionChip(title: "Transcript", symbol: "text.alignleft", help: "Play it beside its transcript (\(item.transcript.lastPathComponent))") {
                    model.select(item)
                }
            } else {
                ActionChip(title: "Transcribe", symbol: "text.bubble",
                           help: info?.hasSound == false ? "It has no sound to transcribe"
                                                         : "Write down what's said into \(item.transcript.lastPathComponent)") {
                    model.transcribe(item)
                }
                .disabled(info?.hasSound == false)
                .opacity(info?.hasSound == false ? 0.4 : 1)
            }
            ActionChip(title: "Finder", symbol: "folder", help: "Show it in Finder") { NSWorkspace.shared.show(item.url) }
            Spacer(minLength: 0)
            GlassIcon(symbol: "trash", help: "Move it (and its transcript) to the Trash") { model.trash(item) }
                .scaleEffect(0.85)
        }
    }

    static func when(_ item: Recordings.Item) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return "\(f.string(from: item.date)) · \(size)"
    }
}

/// A small dark label over a picture.
struct Badge: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text).monospacedDigit()
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.6)))
    }
}

/// One recording on its own: it plays on the left, its transcript (or what's being written down)
/// is on the right.
struct RecordingDetail: View {
    let item: Recordings.Item
    @ObservedObject var model: RecordingsModel
    let player: AVPlayer?
    let ink: Double

    var live: Bool { model.isTranscribing(item) }
    var hasSound: Bool { model.info[item]?.hasSound != false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ActionChip(title: "All recordings", symbol: "chevron.left", help: "Back to the grid (Esc)") { model.select(nil) }
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                ActionChip(title: "Finder", symbol: "folder", help: "Show it in Finder") { NSWorkspace.shared.show(item.url) }
            }
            HStack(spacing: 18) {
                Group {
                    if let player {
                        VideoPlayer(player: player) {
                            if !item.isVideo {
                                Image(systemName: "waveform")
                                    .font(.system(size: 64, weight: .medium))
                                    .foregroundStyle(Ink.reply(ink))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .allowsHitTesting(false)
                            }
                        }
                    } else {
                        Color.black
                    }
                }
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                transcript
                    .frame(width: 400)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(live ? "Transcribing… \(Int(model.progress * 100))%" : "Transcript")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if live {
                    ActionChip(title: "Stop", symbol: "stop.fill", help: "Stop transcribing") { model.cancel(item) }
                } else if model.isWaiting(item) {
                    ActionChip(title: "Waiting…", symbol: "clock", help: "Waiting its turn: click to take it out") { model.cancel(item) }
                } else if hasSound {
                    ActionChip(title: model.hasTranscript(item) ? "Again" : "Transcribe", symbol: "text.bubble",
                               help: "Write down what's said into \(item.transcript.lastPathComponent)") { model.transcribe(item) }
                }
                if model.hasTranscript(item), !live {
                    ActionChip(title: "Copy", symbol: "doc.on.doc", help: "Copy the transcript") { model.copyTranscript() }
                    ActionChip(title: "Open", symbol: "doc.text", help: "Open \(item.transcript.lastPathComponent)") {
                        NSWorkspace.shared.open(item.transcript)
                    }
                }
            }
            if let problem = model.problems[item.id] {
                Text(problem)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 1, green: 0.7, blue: 0.75))
                    .textSelection(.enabled)
            }
            ScrollView {
                Group {
                    if live {
                        Text(model.segments.isEmpty ? "…" : model.segments.map(\.text).joined(separator: " "))
                    } else if model.hasTranscript(item) {
                        Text(model.transcriptText.isEmpty ? "(Nothing was said.)" : model.transcriptText)
                    } else {
                        Text(hasSound ? "Not transcribed yet. Transcribe writes down what's said into \(item.transcript.lastPathComponent), beside the recording."
                                      : "This recording has no sound, so there's nothing to transcribe.")
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(Ink.prompt(ink))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
    }
}
