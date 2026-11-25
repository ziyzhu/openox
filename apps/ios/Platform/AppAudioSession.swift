import AVFAudio
import Foundation
import Synchronization

nonisolated enum AppAudioSession {
    private static let queue = DispatchQueue(label: "ai.openox.audio-session", qos: .userInitiated)
    private static let activeOwner = Mutex<UUID?>(nil)
    private static let recoverableCodes: Set<Int> = [
        AVAudioSession.ErrorCode.expiredSession.rawValue,
        AVAudioSession.ErrorCode.mediaServicesFailed.rawValue,
    ]

    static func activateRecording(owner: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    do {
                        try activate(owner: owner, category: .record, mode: .measurement, options: [.allowBluetoothHFP])
                    } catch let error as NSError where recoverableCodes.contains(error.code) {
                        Log.ui.error("AudioSession.activate retry owner=\(owner) code=\(error.code) error=\(error.localizedDescription)")
                        try activate(owner: owner, category: .record, mode: .measurement, options: [.allowBluetoothHFP])
                    }
                })
            }
        }
    }

    static func deactivate(owner: UUID, reason: String) {
        queue.async {
            guard activeOwner.withLock({ $0 == owner }) else { return }
            let started = ContinuousClock.now
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                activeOwner.withLock { $0 = nil }
                Log.ui.info("AudioSession.deactivated owner=\(owner) reason=\(reason) duration=\(started.duration(to: .now))")
            } catch {
                Log.ui.error("AudioSession.deactivate failed owner=\(owner) reason=\(reason) error=\(error.localizedDescription)")
            }
        }
    }

    private static func activate(owner: UUID, category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: mode, options: options)
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        activeOwner.withLock { $0 = owner }
    }
}
