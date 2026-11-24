import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ConversationSpeechInput {
    enum ReleaseAction: String {
        case send
        case cancel
    }

    enum Outcome {
        case send(String)
        case draft(String)

        var text: String {
            switch self {
            case .send(let text), .draft(let text): text
            }
        }
    }

    enum State: Equatable {
        case idle
        case preparing(holding: Bool)
        case starting
        case recording(ReleaseAction)
        case finalizing
    }

    private(set) var state = State.idle
    private(set) var level: Float = 0
    private(set) var transcript = ""
    private(set) var startedAt = Date()
    private(set) var usesAccessibleControls = false
    var notice: String?
    @ObservationIgnored var composerFrame = CGRect.zero
    @ObservationIgnored private var session: OnDeviceSpeechRecording?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var completion: ((Outcome) -> Void)?

    var isPresented: Bool { state != .idle }

    var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    var selection: ReleaseAction {
        if case .recording(let action) = state { action } else { .send }
    }

    var showsTranscript: Bool {
        isPresented && !transcript.isEmpty
    }

    func begin(accessible: Bool = false, completion: @escaping (Outcome) -> Void) {
        guard state == .idle else { return }
        let id = UUID()
        let recording = OnDeviceSpeechRecording()
        sessionID = id
        session = recording
        self.completion = completion
        usesAccessibleControls = accessible
        state = .preparing(holding: true)
        level = 0
        transcript = ""
        notice = nil
        Log.ui.info("SpeechInput.prepare session=\(id) locale=\(AppLocale.shared.locale.identifier)")
        task = Task { [self] in
            defer { if Task.isCancelled { recording.cancel() } }
            do {
                let setup = try await recording.prepare(locale: AppLocale.shared.locale) { [weak self] text in
                    guard self?.sessionID == id else { return }
                    self?.transcript = text
                }
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
        let action: ReleaseAction = distance >= 32 && exitsComposer(point) ? .cancel : .send
        if selection != action {
            state = .recording(action)
            Haptics.selection(.speechActionChanged)
            Log.ui.info("SpeechInput.selection action=\(action.rawValue)")
        }
    }

    private func exitsComposer(_ point: CGPoint) -> Bool {
        guard !composerFrame.isEmpty else { return false }
        let slack: CGFloat = selection == .cancel ? 0 : 12
        return point.y < composerFrame.minY - slack || point.x < composerFrame.minX - slack
    }

    func release(action: ReleaseAction? = nil) {
        let released = ContinuousClock.now
        defer { Log.ui.info("SpeechInput.release handled duration=\(released.duration(to: .now))") }
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
            Haptics.impact(.speechCancelled)
            return
        }
        state = .finalizing
        level = 0
        recording.stopCapture()
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
                Log.ui.info("SpeechInput.completed session=\(id) chars=\(text.count)")
                completion?(.send(text))
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
            stop(reason: "interrupted", notice: L10n.string("Recording interrupted. Nothing was sent.", comment: ""))
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
        transcript = ""
    }

    private func fail(_ error: Error) {
        Log.ui.error("SpeechInput.failed error=\(error.localizedDescription)")
        stop(reason: "error", notice: error.localizedDescription)
        Haptics.error(.speechFailed)
    }

    private func setDeadline(seconds: Int, message: String) {
        deadline?.cancel()
        deadline = Task {
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            stop(reason: "timeout", notice: message)
        }
    }

    private func stop(reason: String, notice lost: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = completion
        cancel(reason: reason)
        guard !text.isEmpty else {
            notice = lost
            return
        }
        Log.ui.info("SpeechInput.kept reason=\(reason) chars=\(text.count)")
        completion?(.draft(text))
    }
}
