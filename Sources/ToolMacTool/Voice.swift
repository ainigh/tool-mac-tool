import AVFoundation
import Foundation
import Speech
import ToolCore

// The voice tools all speak and listen through macOS itself: AVSpeechSynthesizer for the voice
// and the Speech framework (on this Mac when it can) for listening. Nothing to install.

/// The voice and speed every tool speaks with (Read aloud sets them).
enum VoiceSettings {
    private static let defaults = UserDefaults.standard

    /// Voices nobody wants reading to them (Bells, Zarvox…).
    private static let novelty: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
                                               "Deranged", "Good News", "Hysterical", "Jester", "Organ", "Pipe Organ",
                                               "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox"]

    /// The voices for this Mac's language, best first (premium, then enhanced, then the rest).
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !novelty.contains($0.name) && !isNovelty($0) }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
            }
    }

    private static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if #available(macOS 14, *) { return voice.voiceTraits.contains(.isNoveltyVoice) }
        return false
    }

    static var voiceID: String? {
        get { defaults.string(forKey: "ttsVoice") }
        set { defaults.set(newValue, forKey: "ttsVoice") }
    }

    /// The chosen voice, or the best one there is.
    static func voice() -> AVSpeechSynthesisVoice? {
        if let id = voiceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices().first
    }

    /// 0.5 to 2: how fast, against the voice's normal pace.
    static var speed: Double {
        get { defaults.object(forKey: "ttsSpeed") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "ttsSpeed") }
    }

    static func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = voice()
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate)
        let rate = speed >= 1 ? normal + (speed - 1) * 0.35 : normal - (1 - speed) * 0.3
        u.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate), max(Double(AVSpeechUtteranceMinimumSpeechRate), rate)))
        return u
    }

    /// "Ava (Premium)": a voice as a menu shows it.
    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return voice.name
        }
    }
}

/// Says things out loud, one after another. Text given while it's talking waits its turn;
/// `stop` drops everything.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    @Published private(set) var paused = false
    /// What's being said now, and the word being said (a range in it).
    @Published private(set) var current = ""
    @Published private(set) var word: NSRange?
    /// Nothing left to say (it finished, not stopped).
    var onDone: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var queued: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        let u = VoiceSettings.utterance(text)
        queued.insert(ObjectIdentifier(u))
        speaking = true
        synth.speak(u)
    }

    func stop() {
        queued = []
        synth.stopSpeaking(at: .immediate)
        speaking = false
        paused = false
        word = nil
    }

    func pause() {
        if synth.pauseSpeaking(at: .word) { paused = true }
    }

    func resume() {
        if synth.continueSpeaking() { paused = false }
    }

    private func ended(_ u: AVSpeechUtterance) {
        guard queued.remove(ObjectIdentifier(u)) != nil, queued.isEmpty else { return }
        speaking = false
        paused = false
        word = nil
        onDone?()
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
}

/// Writes speech to an audio file instead of the speakers.
final class SpeechRecorder: NSObject, AVSpeechSynthesizerDelegate {
    private static var running: [SpeechRecorder] = []

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

    /// Speaks `text` into `url` (.wav, .aiff or .caf); `done` gets nil, or what went wrong.
    static func record(_ text: String, to url: URL, done: @escaping (String?) -> Void) {
        let r = SpeechRecorder(url: url, done: done)
        running.append(r)
        r.synth.write(VoiceSettings.utterance(text)) { [weak r] buffer in
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

/// Listens to the microphone and writes down what's said, live. With `pauseToEnd` set, a pause
/// that long ends what was said: it goes to `onUtterance` and listening carries on fresh. Without
/// it, it keeps going (dictation) and `text` grows until it's stopped.
final class Listener: ObservableObject {
    @Published private(set) var on = false
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
    private var recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Counts recognition tasks, so a finished or cancelled one can't touch the next one's text.
    private var generation = 0
    /// What earlier tasks wrote down (the recognizer stops now and then and is started again).
    private var committed = ""
    private var quiet: Timer?
    private var failures: [Date] = []

    func start() {
        guard !on else { return }
        problem = nil
        Self.authorize { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.problem = problem
            } else {
                self.begin()
            }
        }
    }

    func stop() {
        quiet?.invalidate()
        generation += 1
        task?.cancel()
        task = nil
        setRequest(nil)
        if on {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        on = false
        held = false
        level = 0
    }

    /// Stops writing down (keeps the mic open) until `release`.
    func hold() {
        guard on, !held else { return }
        held = true
        quiet?.invalidate()
        generation += 1
        task?.cancel()
        task = nil
        setRequest(nil)
        committed = ""
        text = ""
    }

    func release() {
        guard on, held else { return }
        held = false
        newTask()
    }

    /// Ends what's been said now, without waiting for the pause.
    func endUtterance() {
        quiet?.invalidate()
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        committed = ""
        text = ""
        restart()
        if !said.isEmpty { onUtterance?(said) }
    }

    /// Clears what's been written down (dictation: after it was saved).
    func clear() {
        committed = ""
        text = ""
        if on && !held { restart() }
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now (it needs Siri's language models or a network)"
            return
        }
        self.recognizer = recognizer
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone found"
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.heard(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        on = true
        held = false
        committed = ""
        text = ""
        failures = []
        newTask()
    }

    /// On the audio thread.
    private func heard(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(buffer)
        let l = Self.level(buffer)
        DispatchQueue.main.async { self.level = self.level * 0.5 + l * 0.5 }
    }

    private func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request = r
        lock.unlock()
    }

    private func newTask() {
        guard let recognizer, on, !held else { return }
        generation += 1
        let mine = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        setRequest(req)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let said = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                self?.recognized(said, isFinal: isFinal, failed: failed, generation: mine)
            }
        }
    }

    private func restart() {
        generation += 1
        task?.cancel()
        task = nil
        setRequest(nil)
        newTask()
    }

    private func recognized(_ said: String?, isFinal: Bool, failed: Bool, generation mine: Int) {
        guard mine == generation, on, !held else { return }
        if let said {
            text = Self.join(committed, said)
            if !said.isEmpty { waitForPause() }
            if isFinal {
                committed = text
                restart()
            }
        } else if failed {
            // The recognizer gave up (a long silence, its time limit): carry on with a new one,
            // unless it keeps failing straight away.
            let now = Date()
            failures = failures.filter { now.timeIntervalSince($0) < 10 } + [now]
            if failures.count > 5 {
                problem = "Speech recognition keeps stopping. Is Dictation or Siri turned off in System Settings?"
                stop()
                return
            }
            committed = text
            restart()
        }
    }

    private func waitForPause() {
        guard let pause = pauseToEnd else { return }
        quiet?.invalidate()
        quiet = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            self?.endUtterance()
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

    /// Asks for speech recognition and the microphone; the answer is nil, or what to switch on.
    static func authorize(_ done: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    done("Speech recognition is off for Tool Mac Tool: turn it on in System Settings → Privacy & Security → Speech Recognition")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    done(granted ? nil : "The microphone is off for Tool Mac Tool: turn it on in System Settings → Privacy & Security → Microphone")
                }
            }
        }
    }
}

/// Turns an audio file into timed text. Long files go to the recognizer in pieces of under a
/// minute (its limit), each cut at the quietest moment near its end; silent pieces are skipped.
final class FileTranscriber {
    /// What's happening, on the main thread.
    var onSegment: ((TimedText) -> Void)?
    var onProgress: ((Double) -> Void)?
    /// nil when it finished, else what went wrong ("Stopped" when cancelled).
    var onDone: ((String?) -> Void)?

    private var cancelled = false
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?

    static let piece = 50.0
    static let search = 12.0

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func start(_ url: URL) {
        Listener.authorize { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.onDone?(problem)
                return
            }
            Thread.detachNewThread { self.run(url) }
        }
    }

    private func main(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    private func run(_ url: URL) {
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            main { self.onDone?("Speech recognition isn't available right now") }
            return
        }
        recognizer.queue = OperationQueue()
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            main { self.onDone?("Couldn't read that file as audio: \(error.localizedDescription)") }
            return
        }
        let format = file.processingFormat
        let rate = format.sampleRate
        let total = file.length
        let pieceFrames = AVAudioFrameCount(Self.piece * rate)
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
            if Self.loudest(buffer) > 0.02 {
                let (segments, problem) = recognize(buffer, with: recognizer, offset: offset)
                if isCancelled {
                    main { self.onDone?("Stopped") }
                    return
                }
                if let problem, segments.isEmpty, problem != "nothing heard" {
                    main { self.onDone?(problem) }
                    return
                }
                for s in segments { main { self.onSegment?(s) } }
            }
            position += AVAudioFramePosition(buffer.frameLength)
            let progress = Double(position) / Double(max(total, 1))
            main { self.onProgress?(progress) }
        }
        main { self.onDone?(nil) }
    }

    /// One piece, start to end: its sentences, timed from the start of the file.
    private func recognize(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer,
                           offset: Double) -> ([TimedText], String?) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()
        let done = DispatchSemaphore(value: 0)
        var out: [TimedText] = []
        var problem: String?
        var finished = false
        let t = recognizer.recognitionTask(with: request) { result, error in
            guard !finished else { return }
            if let result, result.isFinal {
                out = Self.sentences(result.bestTranscription, offset: offset)
                finished = true
                done.signal()
            } else if let error {
                let code = (error as NSError).code
                problem = code == 1110 ? "nothing heard" : error.localizedDescription   // 1110: no speech
                finished = true
                done.signal()
            }
        }
        lock.lock()
        task = t
        lock.unlock()
        if done.wait(timeout: .now() + 180) == .timedOut {
            t.cancel()
            problem = "The recognizer took too long on one part"
        }
        return (out, problem)
    }

    /// The recognized words grouped into sentences, each timed by its first and last word.
    static func sentences(_ t: SFTranscription, offset: Double) -> [TimedText] {
        let words = t.segments
        guard !words.isEmpty else { return [] }
        var out: [TimedText] = []
        var i = 0
        for sentence in SpokenText.sentences(t.formattedString) {
            let count = max(1, sentence.split(whereSeparator: \.isWhitespace).count)
            let first = words[min(i, words.count - 1)]
            let last = words[min(i + count - 1, words.count - 1)]
            out.append(TimedText(start: offset + first.timestamp, end: offset + last.timestamp + last.duration,
                                 text: sentence))
            i += count
        }
        return out
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
