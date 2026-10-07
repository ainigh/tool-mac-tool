import AppKit
import AVFoundation
import FluidAudio
import Foundation
import ToolCore

// The voice tools speak with Kokoro and listen with Parakeet (see Neural.swift). While Kokoro is
// still downloading the first time, the Mac's own voice reads instead, so nothing waits.

/// The voice and speed every tool speaks with (Read aloud sets them).
enum VoiceSettings {
    private static let defaults = UserDefaults.standard

    /// One of the four (NeuralVoice.all).
    static var voice: NeuralVoice {
        get { NeuralVoice.named(defaults.string(forKey: "neuralVoice")) }
        set { defaults.set(newValue.id, forKey: "neuralVoice") }
    }

    /// 0.5 to 2: how fast, against the voice's normal pace.
    static var speed: Double {
        get { defaults.object(forKey: "ttsSpeed") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "ttsSpeed") }
    }

    /// Voices nobody wants reading to them (Bells, Zarvox…).
    private static let novelty: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
                                               "Deranged", "Good News", "Hysterical", "Jester", "Organ", "Pipe Organ",
                                               "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox"]

    /// The Mac's own voice standing in for the chosen one: the best it has of the same sex.
    static func systemVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) && !novelty.contains($0.name) }
        let infos = all.map { v -> VoiceInfo in
            let quality: VoiceInfo.Quality = v.quality == .premium ? .premium : v.quality == .enhanced ? .enhanced : .standard
            let female: Bool? = v.gender == .female ? true : v.gender == .male ? false : nil
            return VoiceInfo(identifier: v.identifier, name: v.name, language: v.language, quality: quality, female: female)
        }
        let best = VoiceLineup.best(infos, female: Self.voice.female).first ?? VoiceLineup.pick(infos).first
        return best.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) } ?? AVSpeechSynthesisVoice(language: nil)
    }

    static func systemUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = systemVoice()
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let rate = speed >= 1 ? normal + (speed - 1) * 0.35 : normal - (1 - speed) * 0.3
        u.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), max(Double(AVSpeechUtteranceMinimumSpeechRate), rate)))
        return u
    }

    /// "Heart · woman": a voice as a menu shows it.
    static func label(_ v: NeuralVoice) -> String {
        "\(v.name) · \(v.female ? "woman" : "man")"
    }

    /// Kokoro reads `text` in the chosen voice: 24 kHz mono samples.
    static func render(_ text: String, with model: Task<KokoroAneManager, Error>) -> Task<[Float], Error> {
        let voiceID = Self.voice.id
        let pace = Float(Self.speed)
        return Task.detached(priority: .userInitiated) {
            try await model.value.synthesizeDetailed(text: text, voice: voiceID, speed: pace).samples
        }
    }

    static let sampleRate = 24_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
}

/// Says things out loud, one after another. Text given while it's talking waits its turn;
/// `stop` drops everything. Each sentence is made while the one before it plays, so there are
/// no gaps between them.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    @Published private(set) var paused = false
    /// What's being said now, and the word being said (a range in it).
    @Published private(set) var current = ""
    @Published private(set) var word: NSRange?
    /// Nothing left to say (it finished, not stopped).
    var onDone: (() -> Void)?

    // Kokoro: sentences waiting, the next one being made, the player.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var lines: [String] = []
    private var ahead: (text: String, audio: Task<[Float], Error>)?
    /// A sentence is being made or played.
    private var busy = false
    /// Counts stops, so audio made or played for what was stopped is dropped.
    private var epoch = 0
    /// For lighting up the word: when the line started, how long it is, time spent paused.
    private var lineStarted = Date()
    private var lineLength = 0.0
    private var pausedAt: Date?
    private var pausedFor = 0.0
    private var ticker: Timer?

    // The Mac's voice, while Kokoro isn't there yet.
    private let synth = AVSpeechSynthesizer()
    private var queued: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        synth.delegate = self
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: VoiceSettings.format)
    }

    func say(_ text: String) {
        let parts = SpokenText.sentences(text)
        guard !parts.isEmpty else { return }
        // Starting afresh: what was said last time isn't shown while the first sentence is made.
        if !speaking {
            current = ""
            word = nil
        }
        speaking = true
        // Kokoro once it's there (and the Mac's voice isn't part way through something).
        if !Neural.shared.voices.isReady || !queued.isEmpty {
            _ = Neural.shared.voiceModel()
            let u = VoiceSettings.systemUtterance(text)
            queued.insert(ObjectIdentifier(u))
            synth.speak(u)
            return
        }
        lines += parts
        if !busy { next() }
    }

    func stop() {
        epoch += 1
        lines = []
        ahead?.audio.cancel()
        ahead = nil
        busy = false
        player.stop()
        if engine.isRunning { engine.stop() }
        ticker?.invalidate()
        queued = []
        synth.stopSpeaking(at: .immediate)
        speaking = false
        paused = false
        pausedAt = nil
        word = nil
    }

    func pause() {
        guard speaking, !paused else { return }
        if !queued.isEmpty {
            if synth.pauseSpeaking(at: .word) { paused = true }
            return
        }
        player.pause()
        paused = true
        pausedAt = Date()
    }

    func resume() {
        guard paused else { return }
        if !queued.isEmpty {
            if synth.continueSpeaking() { paused = false }
            return
        }
        paused = false
        if let pausedAt { pausedFor += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        if busy, engine.isRunning { player.play() }
    }

    /// Plays the next sentence (made ahead, or made now), or finishes.
    private func next() {
        let line: (text: String, audio: Task<[Float], Error>)
        if let ahead {
            line = ahead
            self.ahead = nil
        } else if !lines.isEmpty {
            let text = lines.removeFirst()
            line = (text, VoiceSettings.render(text, with: Neural.shared.voiceModel()))
        } else {
            finished()
            return
        }
        busy = true
        let mine = epoch
        Task.detached { [weak self] in
            let audio = try? await line.audio.value
            DispatchQueue.main.async {
                guard let self, mine == self.epoch else { return }
                self.play(line.text, audio ?? [])
            }
        }
    }

    private func play(_ text: String, _ audio: [Float]) {
        // Make the next one while this one plays.
        if ahead == nil, !lines.isEmpty {
            let t = lines.removeFirst()
            ahead = (t, VoiceSettings.render(t, with: Neural.shared.voiceModel()))
        }
        guard !audio.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: VoiceSettings.format, frameCapacity: AVAudioFrameCount(audio.count)),
              let data = buffer.floatChannelData?[0] else {
            next()
            return
        }
        audio.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: audio.count) }
        buffer.frameLength = AVAudioFrameCount(audio.count)
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                next()
                return
            }
        }
        current = text
        word = nil
        lineStarted = Date()
        lineLength = Double(audio.count) / VoiceSettings.sampleRate
        pausedFor = 0
        pausedAt = paused ? Date() : nil
        let mine = epoch
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, mine == self.epoch else { return }
                self.busy = false
                self.next()
            }
        }
        if !paused { player.play() }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Lights up the word being said, spreading the line's time over its words.
    private func tick() {
        guard busy, !paused, lineLength > 0 else { return }
        let elapsed = Date().timeIntervalSince(lineStarted) - pausedFor
        word = SpokenText.wordRange(in: current, at: elapsed / lineLength)
    }

    private func finished() {
        busy = false
        ticker?.invalidate()
        player.stop()
        if engine.isRunning { engine.stop() }
        speaking = false
        paused = false
        word = nil
        onDone?()
    }

    // MARK: The Mac's voice

    private func ended(_ u: AVSpeechUtterance) {
        guard queued.remove(ObjectIdentifier(u)) != nil, queued.isEmpty else { return }
        if !lines.isEmpty || busy { return }
        finished()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        DispatchQueue.main.async {
            self.current = text
            self.word = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.word = characterRange }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.ended(utterance) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.ended(utterance) }
    }

    /// Says a few words in the chosen voice, so choosing one lets you hear it.
    static func preview() {
        sampler.stop()
        sampler.say("Hi, I'm \(VoiceSettings.voice.name). This is how I sound.")
    }

    private static let sampler = Speaker()
}

/// Writes speech to an audio file instead of the speakers.
enum SpeechRecorder {
    /// Speaks `text` into `url` (.wav); `done` gets nil, or what went wrong. On the main thread.
    static func record(_ text: String, to url: URL, done: @escaping (String?) -> Void) {
        guard Neural.shared.voices.isReady else {
            SystemRecorder.record(text, to: url, done: done)
            return
        }
        let audio = VoiceSettings.render(text, with: Neural.shared.voiceModel())
        Task.detached {
            var problem: String?
            do {
                let samples = try await audio.value
                let file = try AVAudioFile(forWriting: url, settings: VoiceSettings.format.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: false)
                if !samples.isEmpty,
                   let buffer = AVAudioPCMBuffer(pcmFormat: VoiceSettings.format, frameCapacity: AVAudioFrameCount(samples.count)),
                   let data = buffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: samples.count) }
                    buffer.frameLength = AVAudioFrameCount(samples.count)
                    try file.write(from: buffer)
                }
            } catch {
                problem = error.localizedDescription
            }
            DispatchQueue.main.async { done(problem) }
        }
    }
}

/// The Mac's voice into a file, while Kokoro isn't there yet.
private final class SystemRecorder: NSObject, AVSpeechSynthesizerDelegate {
    private static var running: [SystemRecorder] = []

    private let synth = AVSpeechSynthesizer()
    private let url: URL
    private let done: (String?) -> Void
    private var file: AVAudioFile?
    private var failure: String?
    private var finished = false

    private init(url: URL, done: @escaping (String?) -> Void) {
        self.url = url
        self.done = done
        super.init()
        synth.delegate = self
    }

    static func record(_ text: String, to url: URL, done: @escaping (String?) -> Void) {
        let r = SystemRecorder(url: url, done: done)
        running.append(r)
        r.synth.write(VoiceSettings.systemUtterance(text)) { [weak r] buffer in
            r?.write(buffer)
        }
    }

    private func write(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            DispatchQueue.main.async { self.finish() }
            return
        }
        guard failure == nil else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        file = nil                    // closes it
        done(failure)
        Self.running.removeAll { $0 === self }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The last buffer may still be on its way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finish() }
    }
}

/// Listens to the microphone and writes down what's said. The audio is cut into phrases at the
/// pauses (PhraseCutter) and each phrase is written down whole by Parakeet, in order; while a
/// phrase is still being said, it's written down every so often to show it live. With
/// `pauseToEnd` set, a pause that long ends what was said: it goes to `onUtterance` and listening
/// carries on fresh. Without it, it keeps going (dictation) and `text` grows until it's stopped.
///
/// No audio is thrown away once someone speaks: phrases wait while the model downloads (or if it
/// couldn't be had), stopping writes down the last one, and a microphone change (AirPods
/// connecting) re-wires the input and carries on.
final class Listener: ObservableObject {
    @Published private(set) var on = false
    /// Stopped, and the last words are still being written down.
    @Published private(set) var finishing = false
    /// Listening is paused (the mic stays open, nothing is written down), e.g. while a reply is spoken.
    @Published private(set) var held = false
    /// What's been said so far.
    @Published private(set) var text = ""
    /// How loud it is, 0 to 1.
    @Published private(set) var level: Float = 0
    @Published var problem: String?

    var pauseToEnd: TimeInterval?
    var onUtterance: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var resampler: Resampler?            // used on the audio thread, under the lock
    private var cutter = PhraseCutter(pause: 0.8)
    private var rewiring: NSObjectProtocol?

    /// Written down: finished phrases, and the live guess at the one being said.
    private var done = ""
    private var guess = ""
    /// Phrases waiting to be written down, oldest first (`send`: it ends what was said).
    private var waiting: [(samples: [Float], send: Bool)] = []
    private var writing = false
    /// Counts clears, so what's written down for something cleared is dropped.
    private var generation = 0
    /// Counts phrases, so a live guess at one that has since ended is dropped.
    private var phraseNumber = 0
    private var guessing = false
    private var ticker: Timer?

    func start() {
        problem = nil
        if on {
            writeNext()                             // "Try again" after the model failed
            return
        }
        Self.authorize { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.problem = problem
            } else {
                self.begin()
            }
        }
    }

    /// Stops listening. What was said last is still written down (`finishing` meanwhile).
    func stop() {
        guard on else { return }
        closeMic()
        if !held, let last = cutter.flush() { enqueue(last, send: false) }
        cutter.reset()
        held = false
        finishing = writing || !waiting.isEmpty
    }

    private func closeMic() {
        ticker?.invalidate()
        if let rewiring { NotificationCenter.default.removeObserver(rewiring) }
        rewiring = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        on = false
        level = 0
    }

    /// Stops writing down (keeps the mic open) until `release`; what's half said is dropped.
    func hold() {
        guard on, !held else { return }
        held = true
        dropAll()
    }

    func release() {
        guard on, held else { return }
        cutter.reset()
        held = false
    }

    /// Ends what's been said now, without waiting for the pause.
    func endUtterance() {
        enqueue(cutter.flush() ?? [], send: true)
    }

    /// Clears what's been written down.
    func clear() {
        dropAll()
    }

    private func dropAll() {
        generation += 1
        cutter.reset()
        waiting = []
        done = ""
        guess = ""
        text = ""
    }

    private func begin() {
        _ = Neural.shared.earModel()                // start getting it, if it isn't here yet
        if let problem = openMic() {
            self.problem = problem
            return
        }
        rewiring = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in self?.rewire() }
        cutter = PhraseCutter(pause: pauseToEnd ?? 0.8)
        on = true
        held = false
        finishing = false
        if waiting.isEmpty && !writing {
            done = ""
            guess = ""
            text = ""
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.guessLive() }
        writeNext()                                 // anything left from before
    }

    /// Taps the microphone and starts the engine; nil, or what went wrong.
    private func openMic() -> String? {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No microphone found" }
        lock.lock()
        resampler = Resampler(from: format)
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.heard(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return "Couldn't start the microphone: \(error.localizedDescription)"
        }
        return nil
    }

    /// The microphone changed: the engine has stopped, so start it again on the new one.
    private func rewire() {
        guard on else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let problem = openMic() {
            self.problem = problem
            stop()
        }
    }

    /// On the audio thread.
    private func heard(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let samples = resampler?.convert(buffer) ?? []
        lock.unlock()
        let l = Self.level(buffer)
        DispatchQueue.main.async {
            // A buffer that arrives after the mic was closed leaves the level at 0.
            guard self.on else { return }
            self.level = self.level * 0.5 + l * 0.5
            guard !self.held else { return }
            for phrase in self.cutter.add(samples) {
                self.enqueue(phrase.samples, send: phrase.paused && self.pauseToEnd != nil)
            }
        }
    }

    private func enqueue(_ samples: [Float], send: Bool) {
        phraseNumber += 1
        waiting.append((samples, send))
        writeNext()
    }

    /// Writes down the oldest waiting phrase, then the next, one at a time so they stay in order.
    private func writeNext() {
        guard !writing, let item = waiting.first else {
            if !writing && waiting.isEmpty { finishing = false }
            return
        }
        writing = true
        let mine = generation
        let model = Neural.shared.earModel()
        Task.detached { [weak self] in
            var said = ""
            var problem: String?
            if !item.samples.isEmpty {
                do {
                    said = try await Neural.write(item.samples, with: model.value).text
                } catch {
                    problem = error.localizedDescription
                }
            }
            DispatchQueue.main.async { self?.written(said, send: item.send, problem: problem, generation: mine) }
        }
    }

    private func written(_ said: String, send: Bool, problem: String?, generation mine: Int) {
        writing = false
        guard mine == generation else {
            writeNext()
            return
        }
        if let problem {
            // The model isn't there (no network the first time?): the phrase waits for "Try again".
            self.problem = "Couldn't write it down: \(problem)"
            finishing = false
            return
        }
        if !waiting.isEmpty { waiting.removeFirst() }
        done = Self.join(done, said.trimmingCharacters(in: .whitespacesAndNewlines))
        if waiting.isEmpty { guess = "" }
        text = Self.join(done, guess)
        if send {
            let all = done
            done = ""
            guess = ""
            text = ""
            if !all.isEmpty { onUtterance?(all) }
        }
        writeNext()
    }

    /// While a phrase is being said, writes down what's been said of it so far, to show it live.
    private func guessLive() {
        guard on, !held, !guessing, !writing, waiting.isEmpty, cutter.spoke,
              cutter.open.count > PhraseCutter.rate / 2, Neural.shared.ears.isReady else { return }
        guessing = true
        let mine = (generation, phraseNumber)
        let audio = cutter.open
        let model = Neural.shared.earModel()
        Task.detached { [weak self] in
            let said = (try? await Neural.write(audio, with: model.value).text) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.guessing = false
                guard mine == (self.generation, self.phraseNumber), self.on, !self.held, self.waiting.isEmpty else { return }
                self.guess = said.trimmingCharacters(in: .whitespacesAndNewlines)
                self.text = Self.join(self.done, self.guess)
            }
        }
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Loudness of a buffer, 0 (quiet) to 1 (loud), on a decibel scale.
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        return max(0, min(1, (db + 55) / 45))
    }

    /// Asks for the microphone; the answer is nil, or what to switch on.
    static func authorize(_ done: @escaping (String?) -> Void) {
        // Asked for the first time, macOS's question must not end up under a floating window.
        let asking = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        if asking { Task { @MainActor in PromptSafety.lower() } }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if asking { Task { @MainActor in PromptSafety.restore() } }
            DispatchQueue.main.async {
                done(granted ? nil : "The microphone is off for Tool Mac Tool: turn it on in System Settings → Privacy & Security → Microphone")
            }
        }
    }
}

/// Turns an audio file into timed text. It goes to the recognizer in pieces of under a minute,
/// each cut at the quietest moment near its end; silent pieces are skipped.
final class FileTranscriber {
    /// What's happening, on the main thread.
    var onSegment: ((TimedText) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// nil when it finished, else what went wrong ("Stopped" when cancelled).
    var onDone: ((String?) -> Void)?

    private var job: Task<Void, Never>?
    private let lock = NSLock()
    private var cancelled = false

    static let piece = 50.0
    static let search = 12.0

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        job?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// On the main thread.
    func start(_ url: URL) {
        let model = Neural.shared.earModel()
        job = Task.detached { [weak self] in await self?.run(url, model: model) }
    }

    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    private func run(_ url: URL, model: Task<AsrManager, Error>) async {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            main { self.onDone?("Couldn't read that file as audio: \(error.localizedDescription)") }
            return
        }
        let asr: AsrManager
        do {
            asr = try await model.value
        } catch {
            main { self.onDone?("Couldn't get speech recognition: \(error.localizedDescription)") }
            return
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        let total = file.length
        let pieceFrames = AVAudioFrameCount(Self.piece * rate)
        let resampler = Resampler(from: format)
        var position: AVAudioFramePosition = 0
        while position < total {
            if isCancelled {
                main { self.onDone?("Stopped") }
                return
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: pieceFrames) else { break }
            do {
                file.framePosition = position
                try file.read(into: buffer, frameCount: pieceFrames)
            } catch {
                main { self.onDone?("Couldn't read the audio: \(error.localizedDescription)") }
                return
            }
            if buffer.frameLength == 0 { break }
            if position + AVAudioFramePosition(buffer.frameLength) < total {
                buffer.frameLength = Self.cutPoint(buffer, rate: rate)
            }
            let offset = Double(position) / rate
            let samples = resampler.convert(buffer)
            if Self.loudest(buffer) > 0.02, !samples.isEmpty {
                do {
                    let result = try await Neural.write(samples, with: asr)
                    let words = buildWordTimings(from: result.tokenTimings ?? []).map {
                        TimedWord(word: $0.word, start: $0.startTime, end: $0.endTime)
                    }
                    for s in Captions.sentences(result.text, words: words, offset: offset) { main { self.onSegment?(s) } }
                } catch {
                    let stopped = isCancelled
                    main { self.onDone?(stopped ? "Stopped" : "Couldn't write it down: \(error.localizedDescription)") }
                    return
                }
            }
            position += AVAudioFramePosition(buffer.frameLength)
            let progress = Double(position) / Double(max(total, 1))
            main { self.onProgress?(progress) }
        }
        main { self.onDone?(nil) }
    }

    /// Where to end a piece that isn't the last: the quietest tenth of a second in its last
    /// `search` seconds.
    static func cutPoint(_ buffer: AVAudioPCMBuffer, rate: Double) -> AVAudioFrameCount {
        guard let data = buffer.floatChannelData?[0] else { return buffer.frameLength }
        let frame = max(1, Int(rate / 10))
        let n = Int(buffer.frameLength)
        var levels: [Float] = []
        var start = 0
        while start + frame <= n {
            var sum: Float = 0
            for i in start..<(start + frame) { sum += data[i] * data[i] }
            levels.append(sum / Float(frame))
            start += frame
        }
        let from = max(0, levels.count - Int(search * 10))
        let cut = QuietCut.cut(levels: levels, from: from)
        return AVAudioFrameCount(max(frame, min(n, cut * frame + frame / 2)))
    }

    static func loudest(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 1 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        return peak
    }
}
