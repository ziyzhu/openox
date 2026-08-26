#if DEBUG && targetEnvironment(simulator)
import Foundation

@MainActor
final class FixtureSpeechRecording: SpeechRecording {
    private let fixture: String

    init(fixture: String) {
        self.fixture = fixture
    }

    func prepare(locale: Locale) async throws -> Bool {
        if fixture == "permission-denied" { throw SpeechInputError.microphonePermission }
        if fixture == "setup" {
            try await Task.sleep(for: .seconds(2))
            return true
        }
        return false
    }

    func start(onLevel: @escaping (Float) -> Void, onFailure: @escaping (Error) -> Void) async throws {
        Log.ui.info("SpeechInput.fixture enabled")
        if fixture == "startup" { try await Task.sleep(for: .seconds(2)) }
        onLevel(0.65)
    }

    func stopCapture() {}

    func finish() async throws -> String {
        try await Task.sleep(for: .milliseconds(350))
        switch fixture {
        case "silence": return ""
        case "error": throw SpeechInputError.unavailable
        case "timeout":
            try await Task.sleep(for: .seconds(30))
            return "This late result must never be sent."
        case "late":
            await withCheckedContinuation { continuation in
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    continuation.resume()
                }
            }
            return "Late transcript."
        default: return fixture
        }
    }

    func cancel() {}
}
#endif
