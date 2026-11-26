import CoreGraphics
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ConversationSpeechInput {
    enum ReleaseAction: String {
        case send
        case cancel
    }

    enum Trigger: Equatable {
        case hold(ReleaseAction)
        case tap

        var name: String {
            switch self {
            case .hold: "hold"
            case .tap: "tap"
            }
        }
    }

    enum Destination: String {
        case send
        case draft
    }

    enum Outcome {
        case finished(String)
        case interrupted(String)

        var text: String {
            switch self {
            case .finished(let text), .interrupted(let text): text
            }
        }
    }

    enum State: Equatable {
        case idle
        case preparing(Trigger?)
        case downloading(percent: Int)
        case starting(Trigger)
        case recording(Trigger)
        case finalizing
    }

    private static let tapDuration = Duration.milliseconds(350)
    private static let captureTail = Duration.milliseconds(250)
    private static let downloadNoticeDelay = Duration.seconds(1)

    private(set) var state = State.idle
    private(set) var level: Float = 0
    private(set) var transcript = ""
    private(set) var destination = Destination.send
    var notice: Toast?
    @ObservationIgnored var composerFrame = CGRect.zero
    @ObservationIgnored private var pressedAt = ContinuousClock.now
    @ObservationIgnored private var recordingStartedAt = ContinuousClock.now
    @ObservationIgnored private var session: OnDeviceSpeechRecording?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var completion: ((Outcome) -> Void)?

    init() {
        OnDeviceSpeechRecording.warmUp(locale: SpeechLanguage.locale)
    }

    var isPresented: Bool { state != .idle }

    var isRecording: Bool {
        if case .recording = state { true } else { false }
    }

    var selection: ReleaseAction {
        if case .recording(.hold(let action)) = state { action } else { .send }
    }

    var isHandsFree: Bool {
        switch state {
        case .preparing(.some(.tap)), .starting(.tap), .recording(.tap): true
        default: false
        }
    }

    var showsCancel: Bool {
        switch state {
        case .preparing(.none), .downloading: true
        default: isHandsFree
        }
    }

    func begin(_ trigger: Trigger, destination: Destination, completion: @escaping (Outcome) -> Void) {
        guard state == .idle else { return }
        let id = UUID()
        let recording = OnDeviceSpeechRecording()
        let locale = SpeechLanguage.locale
        sessionID = id
        session = recording
        self.completion = completion
        self.destination = destination
        pressedAt = .now
        state = .preparing(trigger)
        level = 0
        transcript = ""
        notice = nil
        Log.ui.info("SpeechInput.prepare session=\(id) locale=\(locale.identifier) trigger=\(trigger.name) destination=\(destination.rawValue)")
        task = Task { [self] in
            defer { if Task.isCancelled { recording.cancel() } }
            do {
                let promptedForPermission = try await recording.prepare(
                    locale: locale,
                    onDownload: { [weak self] percent in self?.downloading(percent, session: id) },
                    onTranscript: { [weak self] text in
                        guard self?.sessionID == id else { return }
                        self?.transcript = text
                    }
                )
                try Task.checkCancellation()
                guard sessionID == id else { return }
                guard !promptedForPermission, case .preparing(let requested?) = state else {
                    cancel(reason: "prepared")
                    notice = Toast(
                        message: L10n.string("Voice input is ready. Tap or hold the microphone to talk.", comment: "Notice shown after microphone permission or the speech model finishes setting up."),
                        duration: 5
                    )
                    return
                }
                state = .starting(requested)
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
                guard sessionID == id, case .starting(let trigger) = state else { return }
                recordingStartedAt = .now
                state = .recording(trigger)
                UIApplication.shared.isIdleTimerDisabled = true
                Haptics.impact(.speechStarted)
                setDeadline(seconds: 300, message: L10n.string("Recording reached the five-minute limit. Nothing was sent.", comment: ""))
                Log.ui.info("SpeechInput.recording session=\(id) trigger=\(trigger.name) startup=\(pressedAt.duration(to: .now))")
            } catch where !(error is CancellationError) {
                guard sessionID == id else { return }
                fail(error)
            } catch {}
        }
        setDeadline(seconds: 180, message: L10n.string("Speech setup took too long. Please try again.", comment: ""))
    }

    func move(to point: CGPoint, distance: CGFloat) {
        guard case .recording(.hold(let current)) = state else { return }
        let action: ReleaseAction = distance >= 32 && exitsComposer(point, from: current) ? .cancel : .send
        guard action != current else { return }
        state = .recording(.hold(action))
        Haptics.selection(.speechActionChanged)
        Log.ui.info("SpeechInput.selection action=\(action.rawValue)")
    }

    private func exitsComposer(_ point: CGPoint, from current: ReleaseAction) -> Bool {
        guard !composerFrame.isEmpty else { return false }
        let slack: CGFloat = current == .cancel ? 0 : 12
        return point.y < composerFrame.minY - slack || point.x < composerFrame.minX - slack
    }

    func lift() {
        let held = pressedAt.duration(to: .now)
        switch state {
        case .preparing(.some(.hold)) where held < Self.tapDuration:
            state = .preparing(.tap)
        case .starting(.hold) where held < Self.tapDuration:
            state = .starting(.tap)
        case .preparing(.some(.hold)), .starting(.hold):
            cancel(reason: "releasedBeforeStart")
            notice = Toast(message: L10n.string("No speech detected. Nothing was sent.", comment: ""), duration: 5)
            Haptics.impact(.speechCancelled)
        case .recording(.hold(.cancel)):
            cancel(reason: "slideCancel")
            Haptics.impact(.speechCancelled)
        case .recording(.hold(.send)) where held < Self.tapDuration:
            state = .recording(.tap)
        case .recording(.hold(.send)):
            finish()
        default:
            return
        }
        Log.ui.info("SpeechInput.lift held=\(held) handsFree=\(isHandsFree)")
    }

    func finish() {
        guard case .recording(let trigger) = state, let recording = session, let id = sessionID else { return }
        state = .finalizing
        level = 0
        Haptics.impact(.speechStopped)
        Log.ui.info("SpeechInput.finish session=\(id) trigger=\(trigger.name) duration=\(recordingStartedAt.duration(to: .now))")
        setDeadline(seconds: 15, message: L10n.string("Transcription took too long. Nothing was sent. Please try again.", comment: ""))
        task = Task {
            do {
                try await Task.sleep(for: Self.captureTail)
                let text = try await recording.finish()
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let completion = self.completion
                cancel(reason: "finished")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    notice = Toast(message: L10n.string("No speech detected. Nothing was sent.", comment: ""), duration: 5)
                    return
                }
                Log.ui.info("SpeechInput.completed session=\(id) chars=\(text.count)")
                completion?(.finished(text))
            } catch where !(error is CancellationError) {
                guard sessionID == id else { return }
                fail(error)
            } catch {}
        }
    }

    func interrupt(reason: String) {
        switch state {
        case .idle, .downloading:
            break
        case .preparing:
            Log.ui.info("SpeechInput.interrupt reason=\(reason) state=preparing")
            state = .preparing(nil)
        case .starting, .recording, .finalizing:
            stop(reason: reason, notice: Toast(message: L10n.string("Recording interrupted. Nothing was sent.", comment: ""), duration: 5))
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
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func downloading(_ percent: Int, session id: UUID) {
        guard sessionID == id else { return }
        switch state {
        case .preparing where pressedAt.duration(to: .now) >= Self.downloadNoticeDelay:
            deadline?.cancel()
            deadline = nil
            Log.ui.info("SpeechInput.download started session=\(id)")
            state = .downloading(percent: percent)
        case .downloading(let current) where current != percent:
            state = .downloading(percent: percent)
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        Log.ui.error("SpeechInput.failed state=\(String(describing: state)) domain=\(nsError.domain) code=\(nsError.code) error=\(error.localizedDescription)")
        let denied = error as? SpeechInputError == .microphonePermission
        stop(reason: "error", notice: Toast(
            message: error is SpeechInputError ? error.localizedDescription : SpeechInputError.unavailable.localizedDescription,
            role: .error,
            action: denied ? .openSettings : nil,
            duration: 5
        ))
        Haptics.error(.speechFailed)
    }

    private func setDeadline(seconds: Int, message: String) {
        deadline?.cancel()
        deadline = Task {
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            stop(reason: "timeout", notice: Toast(message: message, duration: 5))
        }
    }

    private func stop(reason: String, notice lost: Toast) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = completion
        cancel(reason: reason)
        guard !text.isEmpty else {
            notice = lost
            return
        }
        Log.ui.info("SpeechInput.kept reason=\(reason) chars=\(text.count)")
        completion?(.interrupted(text))
    }
}
