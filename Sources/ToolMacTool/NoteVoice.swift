import AppKit
import AVFoundation
import SwiftUI
import ToolCore
import UniformTypeIdentifiers

// Speaking into a note, or dropping a sound file on it: what's said is written down (by the same
// on-device model as Dictate and Transcribe) and added at the end of the note, on a line of its
// own. One note listens at a time (the mic under its pin, again to stop); sound files dropped on
// notes (or picked with the waveform under the mic) are written down one at a time, in turn.

@MainActor
final class NoteVoice: ObservableObject {
    static let shared = NoteVoice()

    /// The note listening now (its `key`), if one is.
    @Published private(set) var listening: String?
    /// Stopped: the last words of this note's are still being written down.
    @Published private(set) var finishing: String?
    /// What's been said so far into the note listening.
    @Published private(set) var live = ""
    /// How loud it is, 0 to 1.
    @Published private(set) var level: Float = 0
    /// The notes with sound files to write down: how far along the one being written is (0 to 1),
    /// and how many are waiting.
    @Published private(set) var transcribing: [String: Double] = [:]
    @Published private(set) var waiting: [String: Int] = [:]
    /// The file being written down now.
    @Published private(set) var file: String?
    /// What went wrong, per note (shown on it until it's dismissed).
    @Published var problems: [String: String] = [:]

    private let listener = Listener()
    private var poll: Timer?
    /// Where what's said goes.
    private var target: Target?
    /// The note to listen for next, once the last words of the one before are in.
    private var pending: Target?
    private var queue: [(url: URL, target: Target)] = []
    private var busy = false
    private var job: FileTranscriber?
    /// The note whose file was stopped while a video's sound was still being taken out (no job
    /// to cancel yet): it's dropped as soon as that's done.
    private var stopping: String?

    private struct Target {
        let store: BoardStore
        let board: BoardStore.Kind
        let index: Int
        var key: String { NoteVoice.key(board, index) }
    }

    nonisolated static func key(_ board: BoardStore.Kind, _ i: Int) -> String { "\(board.id)-\(i)" }

    /// A file the model can write down: sound, or a video's sound.
    nonisolated static func isSound(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    // MARK: Speaking into a note

    func isListening(_ board: BoardStore.Kind, _ i: Int) -> Bool { listening == Self.key(board, i) }
    func isFinishing(_ board: BoardStore.Kind, _ i: Int) -> Bool { finishing == Self.key(board, i) }

    /// Starts listening for this note, or stops (what was said goes into it). Another note
    /// listening stops first, its words going into it.
    func toggle(_ store: BoardStore, _ board: BoardStore.Kind, _ i: Int) {
        let key = Self.key(board, i)
        if listening == key { return stop() }
        if pending?.key == key {
            pending = nil
            return
        }
        if listening != nil { stop() }
        let target = Target(store: store, board: board, index: i)
        problems[key] = nil
        // The last words of the one before are still being written down: this one starts after.
        if finishing != nil {
            pending = target
            return
        }
        begin(target)
    }

    private func begin(_ new: Target) {
        target = new
        listening = new.key
        live = ""
        listener.pauseToEnd = nil
        listener.clear()
        listener.start()
        watch()
    }

    /// Stops listening: what's said last is written down, then it all goes into the note.
    func stop() {
        guard let key = listening else { return }
        listening = nil
        finishing = key
        listener.stop()
        check()
    }

    private func watch() {
        poll?.invalidate()
        let t = Timer(timeInterval: 0.15, repeats: true) { _ in
            Task { @MainActor in NoteVoice.shared.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Keeps up with the listener: what's said live, how loud, and (stopped) when it's done.
    private func check() {
        live = listener.text
        level = listener.level
        if let key = listening, let problem = listener.problem, !listener.on {
            // The microphone couldn't be had (or the model): nothing to add.
            problems[key] = problem
            listening = nil
            end()
            return
        }
        // Done when the last words are in, or the model couldn't write them down.
        guard let key = finishing, !listener.on, !listener.finishing || listener.problem != nil else { return }
        if let problem = listener.problem { problems[key] = problem }
        if let target, target.key == key { target.store.append(listener.text, target.board, target.index) }
        finishing = nil
        end()
        if let next = pending {
            pending = nil
            begin(next)
        }
    }

    private func end() {
        poll?.invalidate()
        poll = nil
        listener.clear()
        target = nil
        live = ""
        level = 0
    }

    // MARK: Sound files

    /// Sound (or video) files to write down and add to the note, one after another.
    func transcribe(_ urls: [URL], into store: BoardStore, _ board: BoardStore.Kind, _ i: Int) {
        let target = Target(store: store, board: board, index: i)
        let sounds = urls.filter(Self.isSound)
        guard !sounds.isEmpty else {
            problems[target.key] = "That isn't a sound or video file"
            return
        }
        problems[target.key] = nil
        for url in sounds {
            queue.append((url, target))
            waiting[target.key, default: 0] += 1
        }
        _ = Neural.shared.earModel()                    // the first time, start downloading it now
        next()
    }

    /// Picks sound files to write down into the note.
    func choose(into store: BoardStore, _ board: BoardStore.Kind, _ i: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .audiovisualContent]
        panel.allowsMultipleSelection = true
        panel.message = "Pick sound or video files: what's said in them is added to the note"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        transcribe(panel.urls, into: store, board, i)
    }

    func isTranscribing(_ board: BoardStore.Kind, _ i: Int) -> Bool {
        let key = Self.key(board, i)
        return transcribing[key] != nil || (waiting[key] ?? 0) > 0
    }

    /// Stops writing down this note's files (the one going, and the ones waiting).
    func cancel(_ board: BoardStore.Kind, _ i: Int) {
        let key = Self.key(board, i)
        queue.removeAll { $0.target.key == key }
        waiting[key] = nil
        if transcribing[key] != nil {
            if let job { job.cancel() } else { stopping = key }
        }
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (url, target) = queue.removeFirst()
        let key = target.key
        waiting[key] = max(0, (waiting[key] ?? 1) - 1)
        if waiting[key] == 0 { waiting[key] = nil }
        transcribing[key] = 0
        file = url.lastPathComponent
        Task {
            do {
                // A video's sound is taken out first, so the transcriber reads plain audio.
                let video = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .movie) == true
                let audio = video ? try await RecordingsModel.soundTrack(of: url) : url
                if stopping == key {
                    if video { try? FileManager.default.removeItem(at: audio) }
                    return done(target, problem: nil)
                }
                run(url, audio: audio, temporary: video, target: target)
            } catch {
                done(target, problem: "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func run(_ url: URL, audio: URL, temporary: Bool, target: Target) {
        var segments: [TimedText] = []
        let job = FileTranscriber()
        self.job = job
        job.onSegment = { segments.append($0) }
        job.onProgress = { [weak self] p in self?.transcribing[target.key] = p }
        job.onDone = { [weak self] problem in
            if temporary { try? FileManager.default.removeItem(at: audio) }
            guard let self else { return }
            if let problem {
                self.done(target, problem: problem == "Stopped" ? nil : "\(url.lastPathComponent): \(problem)")
            } else if segments.isEmpty {
                self.done(target, problem: "No speech found in \(url.lastPathComponent)")
            } else {
                target.store.append(Captions.plain(segments), target.board, target.index)
                self.done(target, problem: nil)
            }
        }
        job.start(audio)
    }

    private func done(_ target: Target, problem: String?) {
        job = nil
        stopping = nil
        busy = false
        file = nil
        transcribing[target.key] = nil
        if let problem { problems[target.key] = problem }
        next()
    }
}

/// Under a note's pin: the mic (speak into the note; again to stop and add what was said) and the
/// waveform (pick sound files to write down into it; dropping them on the note does the same).
struct NoteVoiceButtons: View {
    @ObservedObject var voice = NoteVoice.shared
    let store: BoardStore
    let board: BoardStore.Kind
    let index: Int
    /// Room for the waveform too (else only the mic).
    var both = true

    var body: some View {
        let on = voice.isListening(board, index)
        let finishing = voice.isFinishing(board, index)
        let transcribing = voice.isTranscribing(board, index)
        BoxButton(symbol: on ? "mic.fill" : finishing ? "ellipsis" : "mic",
                  help: on ? "Listening: click to stop, and what you said is added to the end of this note"
                      : finishing ? "Writing down the last words…"
                      : "Speak into this note: click, talk, click again, and what you said is added at its end (on this Mac)",
                  tint: on ? Color(red: 0.86, green: 0.22, blue: 0.28) : nil, lit: on) {
            voice.toggle(store, board, index)
        }
        if both || transcribing {
            BoxButton(symbol: transcribing ? "xmark.circle" : "waveform",
                      help: transcribing ? "Writing down a sound file into this note: click to stop"
                          : "Add what's said in sound or video files to this note (or drop them on it)",
                      tint: transcribing ? Color(red: 0.45, green: 0.32, blue: 0.9) : nil) {
                if transcribing { voice.cancel(board, index) } else { voice.choose(into: store, board, index) }
            }
        }
    }
}

/// Along a note's bottom while it listens or writes a file down (or when that went wrong): what's
/// going on, and a way to stop it or put the message away.
struct NoteVoiceStrip: View {
    @ObservedObject var voice = NoteVoice.shared
    let board: BoardStore.Kind
    let index: Int

    var body: some View {
        let key = NoteVoice.key(board, index)
        Group {
            if voice.listening == key {
                strip(color: Color(red: 0.86, green: 0.22, blue: 0.28)) {
                    Circle().fill(.white).frame(width: 6, height: 6)
                        .opacity(0.5 + Double(voice.level) * 0.5)
                        .scaleEffect(0.8 + CGFloat(voice.level) * 0.6)
                    Text(voice.live.isEmpty ? "Listening… speak, then click the mic to add it" : voice.live)
                        .truncationMode(.head)
                    Spacer(minLength: 2)
                    button("stop.fill", help: "Stop, and add what was said") { voice.stop() }
                }
            } else if voice.finishing == key {
                strip(color: Color.black.opacity(0.66)) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Writing down the last words…")
                    Spacer(minLength: 2)
                }
            } else if let progress = voice.transcribing[key] {
                strip(color: Color(red: 0.45, green: 0.32, blue: 0.9)) {
                    Image(systemName: "waveform")
                    Text("\(voice.file ?? "Sound") · \(Int(progress * 100))%" + ((voice.waiting[key] ?? 0) > 0 ? " · \(voice.waiting[key] ?? 0) more" : ""))
                        .monospacedDigit()
                        .truncationMode(.middle)
                        .help(voice.file ?? "Sound")
                    Spacer(minLength: 2)
                    button("xmark", help: "Stop writing it down") { voice.cancel(board, index) }
                }
            } else if (voice.waiting[key] ?? 0) > 0 {
                strip(color: Color.black.opacity(0.66)) {
                    Image(systemName: "hourglass")
                    Text("Waiting to write down \(voice.waiting[key] ?? 0) sound file\(voice.waiting[key] == 1 ? "" : "s")")
                    Spacer(minLength: 2)
                    button("xmark", help: "Don't write them down") { voice.cancel(board, index) }
                }
            } else if let problem = voice.problems[key] {
                strip(color: Color(red: 0.88, green: 0.5, blue: 0.08)) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(problem).help(problem)
                    Spacer(minLength: 2)
                    button("xmark", help: "Dismiss") { voice.problems[key] = nil }
                }
            }
        }
        // Every strip slides in and out, not only the listening one.
        .animation(.easeInOut(duration: 0.2), value: voice.listening)
        .animation(.easeInOut(duration: 0.2), value: voice.finishing)
        .animation(.easeInOut(duration: 0.2), value: voice.transcribing[key] == nil)
        .animation(.easeInOut(duration: 0.2), value: voice.waiting[key] == nil)
        .animation(.easeInOut(duration: 0.2), value: voice.problems[key])
    }

    private func strip<Content: View>(color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.leading, 9)
            .padding(.trailing, 4)
            .frame(height: 22)
            .background(Capsule().fill(color))
            .padding(.horizontal, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(0.22)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
