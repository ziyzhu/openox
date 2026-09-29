import AVFAudio
import Foundation

@MainActor
final class KokoroAudioPlayback {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var queued = 0
    private var generation = UUID()
    private var roomWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.format)
    }

    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    func begin(generation: UUID) {
        self.generation = generation
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, generation expectedGeneration: UUID) async throws {
        guard expectedGeneration == generation else { throw CancellationError() }
        while queued >= 2 {
            await withCheckedContinuation { roomWaiters.append($0) }
            guard expectedGeneration == generation else { throw CancellationError() }
        }
        if !engine.isRunning { try engine.start() }
        let activeGeneration = expectedGeneration
        queued += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.completed(generation: activeGeneration)
            }
        }
        if !node.isPlaying { node.play() }
    }

    func waitUntilFinished() async {
        guard queued > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func stop() {
        generation = UUID()
        node.stop()
        engine.stop()
        queued = 0
        let waiters = roomWaiters + drainWaiters
        roomWaiters.removeAll()
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func completed(generation completedGeneration: UUID) {
        guard completedGeneration == generation else { return }
        queued = max(0, queued - 1)
        if queued < 2 {
            let waiters = roomWaiters
            roomWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if queued == 0 {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
