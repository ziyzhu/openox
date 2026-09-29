import AVFAudio
import Foundation

public actor KokoroTTS {
    public static let shared = KokoroTTS()

    private struct Runtime {
        let pipeline: KokoroPipeline
        let tokenizer: KokoroTokenizer
        let g2p: EnglishG2P
        let voice: KokoroVoice

        var segmenter: KokoroSegmenter {
            KokoroSegmenter(g2p: g2p, tokenizer: tokenizer)
        }
    }

    private var runtime: Runtime?
    private var playback: KokoroAudioPlayback?
    private var generation = UUID()
    private var audioSessionID: UUID?
    private var activeOperations = 0

    public init() {}

    public func prepare() async throws {
        guard runtime == nil else { return }
        guard let modelsDirectory = await KokoroModelStore.shared.modelsDirectory else {
            throw KokoroAssetError.notInstalled
        }
        let assets = try KokoroAssets()
        let tokenizer = try KokoroTokenizer(url: assets.url("Vocabulary/kokoro-vocab.bin"))
        let g2p = try EnglishG2P(url: assets.url("G2P/english.dict"), tokenizer: tokenizer)
        let voice = try KokoroVoice(url: assets.url("Voice/af_heart.bin"))
        let harmonic = try KokoroHarmonicWeights(url: assets.url("harmonic-weights.bin"))
        let pipeline = try KokoroPipeline(
            modelsDirectory: modelsDirectory,
            buckets: [7],
            linearWeights: harmonic.weights,
            linearBias: harmonic.bias
        )
        guard let choice = pipeline.durationModelChoices().first else {
            throw KokoroAssetError.missing("duration model")
        }
        _ = try pipeline.durationModel(choice: choice)
        try pipeline.prepareForBucket(bucketSec: 7, tFrames: 280)
        runtime = Runtime(pipeline: pipeline, tokenizer: tokenizer, g2p: g2p, voice: voice)
        playback = await MainActor.run { KokoroAudioPlayback() }
        Log.ui.info("Kokoro.prepare done modelStages=4 voiceRows=\(voice.rowCount) buckets=7")
    }

    public func synthesize(_ text: String, speed: Float = 1) async throws -> AVAudioPCMBuffer {
        guard speed.isFinite, speed > 0 else { throw KokoroAssetError.invalid("speed") }
        if MandarinG2P.containsHanzi(text) {
            return try await KokoroMandarinTTS.shared.synthesize(text, speed: speed)
        }
        activeOperations += 1
        defer { activeOperations -= 1 }
        try await prepare()
        guard let runtime else { throw KokoroAssetError.missing("runtime") }
        let chunks = try runtime.segmenter.split(text, speed: speed)
        guard !chunks.isEmpty else { throw KokoroAssetError.unsupportedText }
        var samples: [Float] = []
        for chunk in chunks {
            try Task.checkCancellation()
            samples.append(contentsOf: try render(chunk, runtime: runtime, speed: speed))
        }
        return try Self.buffer(samples)
    }

    public func speak(_ text: String, speed: Float = 1) async throws {
        guard speed.isFinite, speed > 0 else { throw KokoroAssetError.invalid("speed") }
        try Task.checkCancellation()
        if MandarinG2P.containsHanzi(text) {
            await stop()
            try await KokoroMandarinTTS.shared.speak(text, speed: speed)
            return
        }
        activeOperations += 1
        defer { activeOperations -= 1 }
        try await prepare()
        try Task.checkCancellation()
        guard let runtime, let playback else { throw KokoroAssetError.missing("runtime") }
        let chunks = try runtime.segmenter.split(text, speed: speed)
        guard !chunks.isEmpty else { return }
        try Task.checkCancellation()
        await stop()
        try Task.checkCancellation()
        let activeGeneration = generation
        await playback.begin(generation: activeGeneration)
        guard activeGeneration == generation else { throw CancellationError() }
        let sessionID = UUID()
        audioSessionID = sessionID
        do {
            try AppAudioSession.activatePlayback(owner: sessionID)
            Log.ui.info("Kokoro.speak start chunks=\(chunks.count) speed=\(speed)")
            for chunk in chunks {
                try Task.checkCancellation()
                guard activeGeneration == generation else { throw CancellationError() }
                let samples = try render(chunk, runtime: runtime, speed: speed)
                guard activeGeneration == generation else { throw CancellationError() }
                try await playback.enqueue(Self.buffer(samples), generation: activeGeneration)
            }
            await playback.waitUntilFinished()
            guard activeGeneration == generation else { throw CancellationError() }
            AppAudioSession.deactivate(owner: sessionID, reason: "kokoro.finished")
            if audioSessionID == sessionID { audioSessionID = nil }
            Log.ui.info("Kokoro.speak finished chunks=\(chunks.count)")
        } catch {
            AppAudioSession.deactivate(owner: sessionID, reason: "kokoro.failed")
            if audioSessionID == sessionID { audioSessionID = nil }
            if activeGeneration == generation { await stop() }
            Log.ui.error("Kokoro.speak failed error=\(error.localizedDescription)")
            throw error
        }
    }

    public func stop() async {
        generation = UUID()
        let stoppedSessionID = audioSessionID
        audioSessionID = nil
        await playback?.stop()
        if let stoppedSessionID {
            AppAudioSession.deactivate(owner: stoppedSessionID, reason: "kokoro.stopped")
        }
        await KokoroMandarinTTS.shared.stop()
        Log.ui.info("Kokoro.stop")
    }

    func unload(reason: String = "modelReplaced") async {
        generation = UUID()
        let stoppedPlayback = playback
        let stoppedSessionID = audioSessionID
        runtime = nil
        playback = nil
        audioSessionID = nil
        await stoppedPlayback?.stop()
        if let stoppedSessionID {
            AppAudioSession.deactivate(owner: stoppedSessionID, reason: "kokoro.unloaded")
        }
        Log.ui.info("Kokoro.unload reason=\(reason)")
    }

    func unloadIfIdle(reason: String) async -> Bool {
        guard activeOperations == 0 else {
            Log.ui.info("Kokoro.unload skipped reason=\(reason) active=\(activeOperations)")
            return false
        }
        await unload(reason: reason)
        return true
    }

    private func render(_ text: String, runtime: Runtime, speed: Float, depth: Int = 0) throws -> [Float] {
        try Task.checkCancellation()
        let phonemes = try runtime.g2p.phonemize(text)
        let ids = try runtime.tokenizer.encode(phonemes)
        if ids.count > 128 {
            return try splitAndRender(text, runtime: runtime, speed: speed, depth: depth)
        }
        let refS = runtime.voice.embedding(forTokenCount: ids.count - 2)
        do {
            let result = try runtime.pipeline.synthesize(
                inputIds: ids,
                attentionMask: Array(repeating: 1, count: ids.count),
                refS: refS,
                speed: speed
            )
            let peak = result.audio.reduce(Float.zero) { max($0, abs($1)) }
            let rms = sqrt(result.audio.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(result.audio.count, 1)))
            Log.ui.info("Kokoro.chunk tokens=\(ids.count) frames=\(result.trimSampleCount) seconds=\(result.audioDurationSeconds) wall=\(result.wallTimeSeconds) peak=\(peak) rms=\(rms)")
            guard peak > 0.0001, rms > 0.00001 else { throw KokoroAssetError.silentAudio }
            return result.audio
        } catch PipelineError.noBucketAvailable {
            return try splitAndRender(text, runtime: runtime, speed: speed, depth: depth)
        }
    }

    private func splitAndRender(_ text: String, runtime: Runtime, speed: Float, depth: Int) throws -> [Float] {
        guard depth < 8, let (left, right) = runtime.segmenter.halve(text) else {
            throw KokoroAssetError.chunkTooLong
        }
        return try render(left, runtime: runtime, speed: speed, depth: depth + 1)
            + render(right, runtime: runtime, speed: speed, depth: depth + 1)
    }

    nonisolated static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard samples.count <= Int(UInt32.max),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?.pointee
        else {
            throw KokoroAssetError.invalid("audio buffer")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: samples.count)
            }
        }
        return buffer
    }
}

enum KokoroRuntimeLifecycle {
    static func enterBackground() async {
        await KokoroTTS.shared.unload(reason: "background")
        await KokoroMandarinTTS.shared.unload(reason: "background")
    }

    static func receiveMemoryWarning() async {
        _ = await KokoroTTS.shared.unloadIfIdle(reason: "memoryWarning")
        _ = await KokoroMandarinTTS.shared.unloadIfIdle(reason: "memoryWarning")
    }
}
