import Foundation
import QuartzCore

@MainActor
final class ConversationAssistantStream {
    private enum HapticPhase {
        case waitingForDelta
        case deltaReceived
    }

    private enum Delivery {
        case delivered
        case pending
        case awaited(CheckedContinuation<Void, Never>)
    }

    private unowned let conversation: Conversation
    private let execution: any ConversationExecution
    private let feedback: any ConversationFeedback
    private let showText: (String) -> Void
    private let replaceText: (String) -> Void
    private let finishTurn: (AssistantMessage) -> Void
    private let output = OutputDelivery()
    private lazy var frameDriver = execution.frameDriver(handler: { [weak self] timestamp in self?.onFrame(at: timestamp) })
    private var text = ""
    private var textBlockIndex: Int?
    private var hapticPhase = HapticPhase.waitingForDelta
    private var delivery = Delivery.delivered

    init(
        conversation: Conversation,
        execution: any ConversationExecution,
        feedback: any ConversationFeedback,
        showText: @escaping (String) -> Void,
        replaceText: @escaping (String) -> Void,
        finishTurn: @escaping (AssistantMessage) -> Void
    ) {
        self.conversation = conversation
        self.execution = execution
        self.feedback = feedback
        self.showText = showText
        self.replaceText = replaceText
        self.finishTurn = finishTurn
    }

    func setVisible(_ visible: Bool) {
        if visible {
            output.setVisibility(.visible)
            if output.needsFrames { startLink() }
        } else {
            output.setVisibility(.hidden)
            stopLink()
            finalizeHidden()
        }
    }

    func armHaptic() {
        hapticPhase = .waitingForDelta
    }

    func registerDelta() {
        guard hapticPhase == .waitingForDelta else { return }
        hapticPhase = .deltaReceived
        if conversation.isSelected { feedback.receivedAgentDelta() }
    }

    func reset() {
        text = ""
        textBlockIndex = nil
    }

    func appendDelta(_ delta: String, block index: Int) {
        let chunk = textBlockIndex == nil || textBlockIndex == index ? delta : "\n" + delta
        textBlockIndex = index
        text += chunk
        buffer(chunk)
    }

    func flush() {
        let drained = output.drainText()
        guard !drained.isEmpty else { return }
        showText(drained)
    }

    func reconcile(_ assistant: AssistantMessage) {
        let final = Self.text(of: assistant)
        guard !final.hasPrefix(text) else {
            let delta = String(final.dropFirst(text.count))
            text = final
            buffer(delta)
            return
        }
        Log.session.warning("Conversation.stream reconciliation id=\(conversation.id) streamedChars=\(text.count) finalChars=\(final.count)")
        output.discardText()
        text = final
        replaceText(final)
    }

    func present(_ assistant: AssistantMessage) -> String {
        output.discardText()
        text = Self.text(of: assistant)
        return text
    }

    func end(_ assistant: AssistantMessage) {
        delivery = .pending
        output.end(assistant)
        if conversation.isSelected { startLink() } else { finalizeHidden() }
    }

    func waitForDelivery() async {
        guard case .pending = delivery else { return }
        await withCheckedContinuation { delivery = .awaited($0) }
    }

    func cancel() {
        output.reset()
        markDelivered()
        stopLink()
    }

    private func buffer(_ delta: String) {
        output.append(delta)
        startLink()
    }

    private func startLink() {
        guard conversation.isSelected else { return }
        if frameDriver.start() { Log.session.debug("Conversation.streamLink start id=\(conversation.id)") }
    }

    private func stopLink() {
        if frameDriver.stop() { Log.session.debug("Conversation.streamLink stop id=\(conversation.id)") }
    }

    private func onFrame(at timestamp: CFTimeInterval) {
        guard let checkpoint = output.nextFrame(at: timestamp) else { return }
        apply(checkpoint)
    }

    private func finalizeHidden() {
        guard let checkpoint = output.hiddenCheckpoint() else { return }
        Log.session.debug("Conversation.streamLink checkpoint id=\(conversation.id) chars=\(checkpoint.text.count)")
        apply(checkpoint)
    }

    private func apply(_ checkpoint: OutputDelivery.Checkpoint) {
        if !checkpoint.text.isEmpty { showText(checkpoint.text) }
        guard let completion = checkpoint.completion else { return }
        stopLink()
        finishTurn(completion)
        markDelivered()
    }

    private func markDelivered() {
        let pending = delivery
        delivery = .delivered
        if case .awaited(let continuation) = pending { continuation.resume() }
    }

    private static func text(of assistant: AssistantMessage) -> String {
        assistant.content.compactMap { block -> String? in
            if case .text(let value) = block { return value.text }
            return nil
        }.joined(separator: "\n")
    }
}
