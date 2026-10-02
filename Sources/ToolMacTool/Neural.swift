import AVFoundation
import FluidAudio
import Foundation
import ToolCore

// The voice tools speak and listen with open-source models that run on this Mac, through
// FluidAudio (Core ML, on the Neural Engine): Kokoro-82M for the voices and Parakeet TDT v3 to
// write down what's said. Each is downloaded once, the first time it's needed, into
// ~/.cache/fluidaudio; after that everything works offline.

/// The two models: loaded (downloaded the first time) when first wanted, then kept.
final class Neural: ObservableObject {
    static let shared = Neural()

    enum Readiness: Equatable {
        case notYet
        /// Downloading or loading; how far, when it's known (0 to 1).
        case loading(Double?)
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    /// Kokoro, the voices.
    @Published private(set) var voices: Readiness = .notYet
    /// Parakeet, the listening.
    @Published private(set) var ears: Readiness = .notYet

    private var voiceLoad: Task<KokoroAneManager, Error>?
    private var earLoad: Task<AsrManager, Error>?

    /// Kokoro, loading it if it isn't yet. On the main thread.
    func voiceModel() -> Task<KokoroAneManager, Error> {
        if let voiceLoad { return voiceLoad }
        voices = .loading(nil)
        let load = Task.detached(priority: .userInitiated) { () async throws -> KokoroAneManager in
            let model = KokoroAneManager(defaultVoice: NeuralVoice.all[0].id)
            try await model.initialize(preloadVoices: Set(NeuralVoice.all.map(\.id)))
            return model
        }
        voiceLoad = load
        Task.detached { [weak self] in
            let result = await load.result
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.voices = .ready
                case .failure(let error):
                    self.voices = .failed(error.localizedDescription)
                    self.voiceLoad = nil       // try again next time
                }
            }
        }
        return load
    }

    /// Parakeet, loading it if it isn't yet. On the main thread.
    func earModel() -> Task<AsrManager, Error> {
        if let earLoad { return earLoad }
        ears = .loading(nil)
        let load = Task.detached(priority: .userInitiated) { [weak self] () async throws -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: { progress in
                let done = progress.fractionCompleted
                DispatchQueue.main.async {
                    if case .loading = self?.ears { self?.ears = .loading(done) }
                }
            })
            let asr = AsrManager()
            try await asr.loadModels(models)
            return asr
        }
        earLoad = load
        Task.detached { [weak self] in
            let result = await load.result
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.ears = .ready
                case .failure(let error):
                    self.ears = .failed(error.localizedDescription)
                    self.earLoad = nil
                }
            }
        }
        return load
    }

    /// Writes down 16 kHz mono audio. Very short audio is padded (the model wants at least a bit).
    static func write(_ samples: [Float], with asr: AsrManager) async throws -> ASRResult {
        var audio = samples
        if audio.count < PhraseCutter.rate { audio += [Float](repeating: 0, count: PhraseCutter.rate - audio.count) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(audio, decoderState: &state)
    }

    /// "Getting the voices ready… 40%": what a tool shows while a model loads; nil once it's there.
    static func status(_ r: Readiness, what: String) -> String? {
        switch r {
        case .notYet, .ready: return nil
        case .loading(let done):
            let first = "Getting \(what) ready (the first time it downloads it)…"
            guard let done, done > 0, done < 1 else { return first }
            return first + " \(Int(done * 100))%"
        case .failed(let problem): return "Couldn't get \(what): \(problem)"
        }
    }
}

/// Turns any audio into the 16 kHz mono the recognizer takes. Keeps its state from one buffer to
/// the next, so a stream of buffers converts without clicks at the joins.
final class Resampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PhraseCutter.rate),
                                      channels: 1, interleaved: false)!
    private let converter: AVAudioConverter?

    init(from format: AVAudioFormat) {
        converter = AVAudioConverter(from: format, to: Self.target)
        converter?.downmix = true
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, buffer.frameLength > 0 else { return [] }
        let ratio = Self.target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
