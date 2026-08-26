import AVFAudio
import Foundation
import Speech
import Synchronization

@MainActor
protocol SpeechRecording: AnyObject {
    func prepare(locale: Locale) async throws -> Bool
    func start(onLevel: @escaping (Float) -> Void, onFailure: @escaping (Error) -> Void) async throws
    func stopCapture()
    func finish() async throws -> String
    func cancel()
}

@MainActor
final class OnDeviceSpeechRecording: SpeechRecording {
    private let audioSessionID = UUID()
    private var analyzer: SpeechAnalyzer?
    private var module: (any SpeechModule)?
    private var engine: AVAudioEngine?
    private var audioInput: SpeechAudioInput?
    private var resultsTask: Task<String, Error>?
    private var audioSessionActive = false

    func prepare(locale: Locale) async throws -> Bool {
        var needsAnotherPress = false
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            needsAnotherPress = true
            guard await AVAudioApplication.requestRecordPermission() else {
                throw SpeechInputError.microphonePermission
            }
        case .denied:
            throw SpeechInputError.microphonePermission
        case .granted:
            break
        @unknown default:
            throw SpeechInputError.microphonePermission
        }
        try Task.checkCancellation()
        if SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
            module = transcriber
            resultsTask = transcriptionTask(transcriber.results) { $0.text }
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .longDictation)
            module = transcriber
            resultsTask = transcriptionTask(transcriber.results) { $0.text }
        } else {
            throw SpeechInputError.unsupportedLanguage
        }
        guard let module else { throw SpeechInputError.unavailable }
        let assetStatus = await AssetInventory.status(forModules: [module])
        Log.ui.info("SpeechInput.assets module=\(String(describing: type(of: module))) status=\(String(describing: assetStatus)) locale=\(locale.identifier)")
        if assetStatus != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            needsAnotherPress = true
            try await request.downloadAndInstall()
            let installedStatus = await AssetInventory.status(forModules: [module])
            Log.ui.info("SpeechInput.assets prepared status=\(String(describing: installedStatus))")
        }
        try Task.checkCancellation()
        analyzer = SpeechAnalyzer(modules: [module])
        return needsAnotherPress
    }

    func start(onLevel: @escaping (Float) -> Void, onFailure: @escaping (Error) -> Void) async throws {
        guard let module, let analyzer,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SpeechInputError.unavailable
        }
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        try await AppAudioSession.activateRecording(owner: audioSessionID)
        audioSessionActive = true
        try Task.checkCancellation()
        let engine = AVAudioEngine()
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpeechInputError.unavailable
        }
        let input = try SpeechAudioInput(format: inputFormat, outputFormat: format) { level in
            Task { @MainActor in onLevel(level) }
        }
        audioInput = input
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            input.append(buffer)
        }
        self.engine = engine
        try await analyzer.start(inputSequence: input.stream)
        try Task.checkCancellation()
        engine.prepare()
        try engine.start()
        if let resultsTask {
            Task {
                do { _ = try await resultsTask.value }
                catch where !(error is CancellationError) { onFailure(error) }
                catch {}
            }
        }
        Log.ui.info("SpeechInput.capture started sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
    }

    func stopCapture() {
        if let engine {
            let started = ContinuousClock.now
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
            Log.ui.info("SpeechInput.capture stopped duration=\(started.duration(to: .now))")
        }
        audioInput?.finish()
        audioInput = nil
        if audioSessionActive {
            audioSessionActive = false
            AppAudioSession.deactivate(owner: audioSessionID, reason: "speechCaptureStopped")
        }
    }

    func finish() async throws -> String {
        stopCapture()
        guard let analyzer, let resultsTask else { throw SpeechInputError.unavailable }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await resultsTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return text
    }

    func cancel() {
        stopCapture()
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            self.analyzer = nil
            Task { await analyzer.cancelAndFinishNow() }
        }
        module = nil
    }

    private func transcriptionTask<Results: AsyncSequence & Sendable>(
        _ results: Results,
        text: @escaping (Results.Element) -> AttributedString
    ) -> Task<String, Error> where Results.Element: SpeechModuleResult {
        Task {
            var transcript = ""
            for try await result in results {
                try Task.checkCancellation()
                if result.isFinal { transcript += String(text(result).characters) }
            }
            return transcript
        }
    }
}

nonisolated private final class SpeechAudioInput: @unchecked Sendable {
    let stream: AsyncThrowingStream<AnalyzerInput, Error>
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let converter: AVAudioConverter
    private let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var finished = false

    init(format: AVAudioFormat, outputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw SpeechInputError.unavailable
        }
        self.converter = converter
        self.onLevel = onLevel
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            let power = (0..<Int(buffer.frameLength)).reduce(Float.zero) { $0 + samples[$1] * samples[$1] }
            onLevel(min(1, sqrt(power / Float(buffer.frameLength)) * 8))
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * converter.outputFormat.sampleRate / buffer.format.sampleRate)) + 32
        let supplied = Mutex(false)
        convert(capacity: capacity) { _, status in
            let hasSupplied = supplied.withLock { value in
                let previous = value
                value = true
                return previous
            }
            if hasSupplied {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        convert(capacity: 4096) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        finished = true
        continuation.finish()
    }

    private func convert(capacity: AVAudioFrameCount, input: @escaping AVAudioConverterInputBlock) {
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            finished = true
            continuation.finish(throwing: SpeechInputError.unavailable)
            return
        }
        var error: NSError?
        let status = converter.convert(to: output, error: &error, withInputFrom: input)
        if let error {
            finished = true
            continuation.finish(throwing: error)
        } else if status == .error {
            finished = true
            continuation.finish(throwing: SpeechInputError.unavailable)
        } else if output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }
}

nonisolated enum SpeechInputError: LocalizedError {
    case microphonePermission
    case unsupportedLanguage
    case unavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermission:
            L10n.string("Allow microphone access in Settings to use Hold to Talk.", comment: "")
        case .unsupportedLanguage:
            L10n.string("On-device speech recognition is unavailable for this language.", comment: "")
        case .unavailable:
            L10n.string("Speech recognition is unavailable. Please try again.", comment: "")
        }
    }
}
