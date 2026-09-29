import AVFAudio
import Foundation

actor KokoroMandarinTTS {
    static let shared = KokoroMandarinTTS()

    private struct Runtime {
        let pipeline: KokoroMandarinPipeline
        let tokenizer: KokoroTokenizer
        let g2p: MandarinG2P
        let voice: KokoroVoice
    }

    private var runtime: Runtime?
    private var playback: KokoroAudioPlayback?
    private var generation = UUID()
    private var audioSessionID: UUID?
    private var activeOperations = 0

    func prepare() async throws {
        guard runtime == nil else { return }
        guard let directory = await KokoroMandarinModelStore.shared.assetsDirectory else {
            throw KokoroAssetError.notInstalled
        }
        let bundle = try KokoroAssets()
        let tokenizer = try KokoroTokenizer(jsonURL: directory.appendingPathComponent("vocab.json"))
        let g2p = try MandarinG2P(assets: directory, bundle: bundle, tokenizer: tokenizer)
        let voice = try KokoroVoice(rawURL: directory.appendingPathComponent("voices/zf_001.bin"))
        let pipeline = KokoroMandarinPipeline()
        try await pipeline.prepare(directory: directory)
        runtime = Runtime(pipeline: pipeline, tokenizer: tokenizer, g2p: g2p, voice: voice)
        playback = await MainActor.run { KokoroAudioPlayback() }
        Log.ui.info("KokoroMandarin.prepare done voiceRows=\(voice.rowCount)")
    }

    func synthesize(_ text: String, speed: Float = 1) async throws -> AVAudioPCMBuffer {
        guard speed.isFinite, speed > 0 else { throw KokoroAssetError.invalid("speed") }
        activeOperations += 1
        defer { activeOperations -= 1 }
        try await prepare()
        guard let runtime else { throw KokoroAssetError.missing("Mandarin runtime") }
        var samples: [Float] = []
        for chunk in try chunks(text, runtime: runtime) {
            try Task.checkCancellation()
            samples.append(contentsOf: try await render(chunk, runtime: runtime, speed: speed))
        }
        return try KokoroTTS.buffer(samples)
    }

    func speak(_ text: String, speed: Float = 1) async throws {
        guard speed.isFinite, speed > 0 else { throw KokoroAssetError.invalid("speed") }
        activeOperations += 1
        defer { activeOperations -= 1 }
        try await prepare()
        guard let runtime, let playback else { throw KokoroAssetError.missing("Mandarin runtime") }
        let parts = try chunks(text, runtime: runtime)
        guard !parts.isEmpty else { return }
        await stop()
        try Task.checkCancellation()
        let activeGeneration = generation
        await playback.begin(generation: activeGeneration)
        let sessionID = UUID()
        audioSessionID = sessionID
        do {
            try AppAudioSession.activatePlayback(owner: sessionID)
            Log.ui.info("KokoroMandarin.speak start chunks=\(parts.count) speed=\(speed)")
            for chunk in parts {
                try Task.checkCancellation()
                guard activeGeneration == generation else { throw CancellationError() }
                let samples = try await render(chunk, runtime: runtime, speed: speed)
                guard activeGeneration == generation else { throw CancellationError() }
                try await playback.enqueue(KokoroTTS.buffer(samples), generation: activeGeneration)
            }
            await playback.waitUntilFinished()
            guard activeGeneration == generation else { throw CancellationError() }
            AppAudioSession.deactivate(owner: sessionID, reason: "kokoro.mandarin.finished")
            if audioSessionID == sessionID { audioSessionID = nil }
        } catch {
            AppAudioSession.deactivate(owner: sessionID, reason: "kokoro.mandarin.failed")
            if audioSessionID == sessionID { audioSessionID = nil }
            if activeGeneration == generation { await stop() }
            Log.ui.error("KokoroMandarin.speak failed error=\(error.localizedDescription)")
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        let sessionID = audioSessionID
        audioSessionID = nil
        await playback?.stop()
        if let sessionID { AppAudioSession.deactivate(owner: sessionID, reason: "kokoro.mandarin.stopped") }
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
            AppAudioSession.deactivate(owner: stoppedSessionID, reason: "kokoro.mandarin.unloaded")
        }
        Log.ui.info("KokoroMandarin.unload reason=\(reason)")
    }

    func unloadIfIdle(reason: String) async -> Bool {
        guard activeOperations == 0 else {
            Log.ui.info("KokoroMandarin.unload skipped reason=\(reason) active=\(activeOperations)")
            return false
        }
        await unload(reason: reason)
        return true
    }

    private func chunks(_ text: String, runtime: Runtime) throws -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try split(trimmed, runtime: runtime, depth: 0)
    }

    private func split(_ text: String, runtime: Runtime, depth: Int) throws -> [String] {
        let phonemes = try runtime.g2p.phonemize(text)
        if runtime.tokenizer.tokenCount(phonemes) <= 110 { return [text] }
        guard depth < 10, let (left, right) = halve(text) else { throw KokoroAssetError.chunkTooLong }
        return try split(left, runtime: runtime, depth: depth + 1)
            + split(right, runtime: runtime, depth: depth + 1)
    }

    private func halve(_ text: String) -> (String, String)? {
        let characters = Array(text)
        guard characters.count > 1 else { return nil }
        let midpoint = characters.count / 2
        for delimiters in [".?!。！？", ";:；：", ",，、", " "] {
            let positions = characters.indices.filter {
                $0 > 0 && $0 < characters.count - 1 && delimiters.contains(characters[$0])
            }
            if let position = positions.min(by: { abs($0 - midpoint) < abs($1 - midpoint) }) {
                let left = String(characters[...position]).trimmingCharacters(in: .whitespaces)
                let right = String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty && !right.isEmpty { return (left, right) }
            }
        }
        let left = String(characters[..<midpoint])
        let right = String(characters[midpoint...])
        return (left, right)
    }

    private func render(_ text: String, runtime: Runtime, speed: Float, depth: Int = 0) async throws -> [Float] {
        let phonemes = try runtime.g2p.phonemize(text)
        let ids = try runtime.tokenizer.encode(phonemes)
        guard ids.count <= 128 else {
            return try await splitAndRender(text, runtime: runtime, speed: speed, depth: depth)
        }
        let embedding = runtime.voice.embedding(forTokenCount: ids.count - 2)
        do {
            return try await runtime.pipeline.synthesize(ids: ids, voice: embedding, speed: speed)
        } catch KokoroAssetError.chunkTooLong {
            return try await splitAndRender(text, runtime: runtime, speed: speed, depth: depth)
        }
    }

    private func splitAndRender(_ text: String, runtime: Runtime, speed: Float, depth: Int) async throws -> [Float] {
        guard depth < 10, let (left, right) = halve(text) else { throw KokoroAssetError.chunkTooLong }
        let first = try await render(left, runtime: runtime, speed: speed, depth: depth + 1)
        let second = try await render(right, runtime: runtime, speed: speed, depth: depth + 1)
        return first + second
    }
}
