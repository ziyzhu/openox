import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ChatSpeechInput {
    enum ReleaseAction: String {
        case send
        case cancel
        case edit
    }

    enum State: Equatable {
        case idle
        case preparing(holding: Bool)
        case starting
        case recording(ReleaseAction)
        case finalizing(ReleaseAction)
    }

    private(set) var state = State.idle
    private(set) var level: Float = 0
    private(set) var startedAt = Date()
    private(set) var usesAccessibleControls = false
    var notice: String?
    @ObservationIgnored var cancelFrame = CGRect.zero
    @ObservationIgnored var editFrame = CGRect.zero
    @ObservationIgnored private var session: (any SpeechRecording)?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var completion: ((String, ReleaseAction) -> Void)?

    var isPresented: Bool { state != .idle }

    var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    var selection: ReleaseAction {
        switch state {
        case .recording(let action), .finalizing(let action): action
        default: .send
        }
    }

    func begin(accessible: Bool = false, completion: @escaping (String, ReleaseAction) -> Void) {
        guard state == .idle else { return }
        let id = UUID()
        let recording = makeRecording()
        sessionID = id
        session = recording
        self.completion = completion
        usesAccessibleControls = accessible
        state = .preparing(holding: true)
        level = 0
        notice = nil
        Log.ui.info("SpeechInput.prepare session=\(id) locale=\(AppLocale.shared.locale.identifier)")
        task = Task {
            defer { if Task.isCancelled { recording.cancel() } }
            do {
                let setup = try await recording.prepare(locale: AppLocale.shared.locale)
                try Task.checkCancellation()
                guard sessionID == id else { return }
                guard !setup, state == .preparing(holding: true) else {
                    cancel(reason: "prepared")
                    notice = L10n.string("Ready. Hold the input area to talk, then release to send.", comment: "")
                    return
                }
                state = .starting
                try await recording.start(
                    onLevel: { [weak self] level in
                        guard self?.sessionID == id else { return }
                        self?.level = level
                    },
                    onFailure: { [weak self] error in
                        guard self?.sessionID == id else { return }
                        self?.fail(error)
                    }
                )
                try Task.checkCancellation()
                guard sessionID == id else { return }
                startedAt = Date()
                state = .recording(.send)
                Haptics.impact(.speechStarted)
                deadline?.cancel()
                deadline = nil
                Log.ui.info("SpeechInput.recording session=\(id)")
            } catch where !(error is CancellationError) {
                guard sessionID == id else { return }
                fail(error)
            } catch {}
        }
        setDeadline(seconds: 180, message: L10n.string("Speech setup took too long. Please try again.", comment: ""))
    }

    func move(to point: CGPoint, distance: CGFloat) {
        guard isRecording else { return }
        let action: ReleaseAction = if distance < 32 {
            .send
        } else if cancelFrame.insetBy(dx: 0, dy: -16).contains(point) {
            .cancel
        } else if editFrame.insetBy(dx: 0, dy: -16).contains(point) {
            .edit
        } else {
            .send
        }
        if selection != action {
            state = .recording(action)
            Haptics.impact(.selectionConfirmed)
            Log.ui.info("SpeechInput.selection action=\(action.rawValue)")
        }
    }

    func release(action: ReleaseAction? = nil) {
        if state == .starting {
            cancel(reason: "releasedDuringStartup")
            return
        }
        if case .preparing = state {
            state = .preparing(holding: false)
            return
        }
        guard isRecording, let recording = session, let id = sessionID else { return }
        let action = action ?? selection
        guard action != .cancel else {
            cancel(reason: "slideCancel")
            Haptics.impact(.stop)
            return
        }
        recording.stopCapture()
        state = .finalizing(action)
        level = 0
        Haptics.impact(.speechStopped)
        Log.ui.info("SpeechInput.release session=\(id) action=\(action.rawValue) duration=\(Date().timeIntervalSince(startedAt))")
        setDeadline(seconds: 15, message: L10n.string("Transcription took too long. Nothing was sent. Please try again.", comment: ""))
        task = Task {
            do {
                let text = try await recording.finish()
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let completion = self.completion
                cancel(reason: "finished")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    notice = L10n.string("No speech detected. Nothing was sent.", comment: "")
                    return
                }
                Log.ui.info("SpeechInput.completed session=\(id) action=\(action.rawValue) chars=\(text.count)")
                completion?(text, action)
            } catch where !(error is CancellationError) {
                guard sessionID == id else { return }
                fail(error)
            } catch {}
        }
    }

    func interrupt() {
        if case .preparing = state {
            state = .preparing(holding: false)
        } else if isPresented {
            cancel(reason: "interrupted")
            notice = L10n.string("Recording interrupted. Nothing was sent.", comment: "")
        }
    }

    func cancel(reason: String) {
        guard isPresented else { return }
        Log.ui.info("SpeechInput.cancel reason=\(reason)")
        sessionID = nil
        task?.cancel()
        task = nil
        deadline?.cancel()
        deadline = nil
        session?.cancel()
        session = nil
        completion = nil
        state = .idle
        level = 0
    }

    private func fail(_ error: Error) {
        Log.ui.error("SpeechInput.failed error=\(error.localizedDescription)")
        cancel(reason: "error")
        notice = error.localizedDescription
    }

    private func setDeadline(seconds: Int, message: String) {
        deadline?.cancel()
        deadline = Task {
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            cancel(reason: "timeout")
            notice = message
        }
    }

    private func makeRecording() -> any SpeechRecording {
        #if DEBUG && targetEnvironment(simulator)
        if let fixture = ProcessInfo.processInfo.environment["OX_SPEECH_FIXTURE"] {
            return FixtureSpeechRecording(fixture: fixture)
        }
        #endif
        return OnDeviceSpeechRecording()
    }
}
