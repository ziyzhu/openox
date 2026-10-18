import Foundation
import Observation

@MainActor
final class ConversationInteractionGate {
    typealias PendingPrompt = Conversation.PendingPrompt
    typealias PendingServiceControl = Conversation.PendingServiceControl

    private enum PromptResult {
        case answered(String)
        case cancelled
    }

    private enum Waiter {
        case prompt(PendingPrompt, CheckedContinuation<PromptResult, Never>)
        case serviceControl(PendingServiceControl, CheckedContinuation<JSONValue?, Never>)

        var interaction: Conversation.Interaction {
            switch self {
            case .prompt(let prompt, _): .prompt(prompt)
            case .serviceControl(let control, _): .serviceControl(control)
            }
        }

        var id: UUID {
            switch self {
            case .prompt(let prompt, _): prompt.id
            case .serviceControl(let control, _): control.id
            }
        }

        var backgroundPhase: ConversationBackgroundPhase {
            switch interaction {
            case .prompt(let prompt) where prompt.kind == .permission: .permissionNeeded
            case .prompt: .inputNeeded
            case .serviceControl(let control):
                switch control.control {
                case .signIn: .signInNeeded
                case .botControl: .verificationNeeded
                case .payment: .paymentNeeded
                }
            }
        }

        var serviceDomain: String? {
            guard case .serviceControl(let control, _) = self else { return nil }
            return control.control.domain
        }

        func cancel() {
            switch self {
            case .prompt(let prompt, let continuation):
                prompt.secretEntry?.cancel()
                continuation.resume(returning: .cancelled)
            case .serviceControl(_, let continuation): continuation.resume(returning: nil)
            }
        }
    }

    private enum State {
        case idle
        case presenting(Waiter, queued: [Waiter])
    }

    private unowned let conversation: Conversation
    private let feedback: any ConversationFeedback
    private let present: (Conversation.Interaction, ConversationBackgroundPhase) -> Void
    private let settle: () -> Void
    private let dismiss: () -> Void
    private let permissionNeeded: () -> Void
    private let answered: () -> Void
    private var state = State.idle
    private var attentionNotificationID: String?

    init(
        conversation: Conversation,
        feedback: any ConversationFeedback,
        present: @escaping (Conversation.Interaction, ConversationBackgroundPhase) -> Void,
        settle: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        permissionNeeded: @escaping () -> Void,
        answered: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.feedback = feedback
        self.present = present
        self.settle = settle
        self.dismiss = dismiss
        self.permissionNeeded = permissionNeeded
        self.answered = answered
    }

    private var serviceManager: ServiceManager { conversation.serviceManager }

    private var activeID: UUID? {
        guard case .presenting(let waiter, _) = state else { return nil }
        return waiter.id
    }

    func resolveServiceControl(id controlID: UUID, result: JSONValue?) {
        guard case .presenting(.serviceControl(let control, let continuation), let queued) = state else {
            Log.session.warning("Conversation.resolveServiceControl ignored id=\(controlID) reason=no-active-service-control")
            return
        }
        guard control.id == controlID else {
            Log.session.warning("Conversation.resolveServiceControl ignored id=\(controlID) active=\(control.id) reason=id-mismatch")
            return
        }
        advance(queued)
        continuation.resume(returning: result)
        Log.session.info("Conversation.resolveServiceControl id=\(controlID) succeeded=\(result != nil)")
    }

    func waitForServiceControl(_ control: PendingServiceControl) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            guard conversation.isBusy else {
                continuation.resume(returning: nil)
                return
            }
            enqueue(.serviceControl(control, continuation))
        }
    }

    private func enqueue(_ waiter: Waiter) {
        guard case .presenting(let active, let queued) = state else {
            activate(waiter, queued: [])
            return
        }
        state = .presenting(active, queued: queued + [waiter])
        Log.session.info("Conversation.interaction queued id=\(waiter.id) depth=\(queued.count + 1)")
    }

    private func activate(_ waiter: Waiter, queued: [Waiter]) {
        state = .presenting(waiter, queued: queued)
        present(waiter.interaction, waiter.backgroundPhase)
        Log.session.info("Conversation.interaction active id=\(waiter.id) queued=\(queued.count)")
        observeActionPolicy()
        notifyPending()
    }

    func notifyPending() {
        guard case .presenting(let waiter, _) = state,
              attentionNotificationID == nil,
              feedback.isBackground else { return }
        deliverAttentionNotification(interactionID: waiter.id, phase: waiter.backgroundPhase)
    }

    private func observeActionPolicy() {
        guard case .presenting(.prompt(let prompt, _), _) = state,
              let approval = prompt.autoApproval else { return }
        let policy = withObservationTracking {
            serviceManager.actionPolicy(for: approval.action, default: approval.defaultPolicy)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.activeID == prompt.id else { return }
                self.observeActionPolicy()
            }
        }
        switch policy {
        case .allow:
            Log.session.info("Conversation.interaction policyResolved id=\(prompt.id) action=\(approval.action) policy=allow")
            resolvePrompt(blockId: prompt.id, answer: approval.approve)
        case .block:
            Log.session.info("Conversation.interaction policyResolved id=\(prompt.id) action=\(approval.action) policy=block")
            resolvePrompt(blockId: prompt.id, answer: approval.deny)
        case .ask:
            break
        }
    }

    private func advance(_ queued: [Waiter]) {
        state = .idle
        clearAttentionNotification()
        var remaining = queued[...]
        while let waiter = remaining.popFirst() {
            if case .prompt(let prompt, let continuation) = waiter,
               let approval = prompt.autoApproval {
                switch serviceManager.actionPolicy(for: approval.action, default: approval.defaultPolicy) {
                case .allow:
                    Log.session.info("Conversation.interaction policyResolved id=\(prompt.id) action=\(approval.action) policy=allow")
                    continuation.resume(returning: .answered(approval.approve))
                    continue
                case .block:
                    Log.session.info("Conversation.interaction policyResolved id=\(prompt.id) action=\(approval.action) policy=block")
                    continuation.resume(returning: .answered(approval.deny))
                    continue
                case .ask:
                    break
                }
            }
            activate(waiter, queued: Array(remaining))
            return
        }
        settle()
    }

    func cancelAll() {
        clearAttentionNotification()
        let waiters: [Waiter] = if case .presenting(let active, let queued) = state { [active] + queued } else { [] }
        state = .idle
        dismiss()
        for waiter in waiters { waiter.cancel() }
        if !waiters.isEmpty {
            Log.session.info("Conversation.interaction canceled count=\(waiters.count)")
        }
    }

    func cancelServiceInteractions(domains: Set<String>) {
        guard !domains.isEmpty, case .presenting(let active, let queued) = state else { return }
        let matches = { (waiter: Waiter) in waiter.serviceDomain.map(domains.contains) == true }
        let removedActive = matches(active)
        let cancelled = (removedActive ? [active] : []) + queued.filter(matches)
        guard !cancelled.isEmpty else { return }
        let remaining = queued.filter { !matches($0) }
        state = removedActive ? .idle : .presenting(active, queued: remaining)
        for waiter in cancelled { waiter.cancel() }
        Log.session.info("Conversation.serviceInteractions canceled domains=\(domains.sorted().joined(separator: ",")) count=\(cancelled.count)")
        if removedActive { advance(remaining) }
    }

    @discardableResult
    func awaitPrompt(
        prompt: String,
        options: [String],
        kind: ConversationPromptKind = .choice,
        allowsCustomAnswer: Bool = false,
        presentation: ConversationPromptPresentation = .conversation,
        autoApproval: PendingPrompt.AutoApproval? = nil,
        secretEntry: SecretEntryRequest? = nil,
        permission: PermissionPresentation? = nil
    ) async -> String {
        defer { secretEntry?.cancel() }
        let pending = PendingPrompt(
            id: UUID(),
            kind: kind,
            prompt: prompt,
            options: options,
            presentation: presentation,
            allowsCustomAnswer: allowsCustomAnswer,
            autoApproval: autoApproval,
            secretEntry: secretEntry,
            permission: permission
        )
        Log.session.info("Conversation.awaitPrompt id=\(conversation.id) kind=\(kind.rawValue) presentation=\(String(describing: presentation)) options=\(options.count)")
        let result = await waitForPrompt(pending)
        answered()
        switch result {
        case .answered(let answer): return answer
        case .cancelled: return Conversation.abortedAnswer
        }
    }

    func resolvePrompt(blockId: UUID, answer: String) {
        guard case .presenting(.prompt(let prompt, let continuation), let queued) = state,
              prompt.id == blockId else { return }
        if let approval = prompt.autoApproval,
           answer == approval.alwaysApprove {
            serviceManager.setActionPolicy(.allow, for: approval.action)
        }
        prompt.secretEntry?.cancel()
        advance(queued)
        continuation.resume(returning: .answered(answer))
    }

    private func waitForPrompt(_ prompt: PendingPrompt) async -> PromptResult {
        await withCheckedContinuation { continuation in
            if !conversation.isBusy {
                Log.session.error("Conversation prompt outside run id=\(conversation.id) block=\(prompt.id)")
                continuation.resume(returning: .cancelled)
            } else {
                enqueue(.prompt(prompt, continuation))
            }
        }
    }

    func gateServiceAttach(_ service: Service) async throws {
        let title = "\(service.title) - \(L10n.string( "Attach"))"
        let message = if service.isIOSService {
            L10n.string("Its actions and permitted device data become available to this conversation.")
        } else if service.isMCPService {
            L10n.string("Its remote Actions can receive arguments from this conversation and return data to Ox.")
        } else {
            L10n.string("Its actions and your signed-in data become available to this conversation.")
        }
        switch await requestApproval(
            action: Conversation.attachApproveKey(service.domain),
            defaultPolicy: Actions.defaultPolicy(for: Actions.serviceAttach),
            prompt: "\(title)\n\(message)"
        ) {
        case .approved: return
        case .denied: throw OxFunctionError(code: "permission_denied", message: "ox.service.attach: the user declined to attach \(service.title).", recovery: "Stop. Do not request this attachment again unless the user asks.")
        case .blocked: throw OxFunctionError(code: "permission_denied", message: "ox.service.attach: the user blocked this Action in Settings.", recovery: "Do not bypass the policy. Ask the user to change it in Settings only if they want to allow this action.")
        case .stopped: throw OxFunctionError(code: "cancelled", message: "ox.service.attach: the user stopped before attaching \(service.title).", recovery: "Stop. Do not reopen the attachment request unless the user asks.")
        }
    }

    func requireApproval(
        action: String,
        defaultPolicy: ActionPolicy,
        args: Any?,
        purpose: String?,
        prompt: String?
    ) async throws {
        switch await requestApproval(
            action: action,
            defaultPolicy: defaultPolicy,
            args: args,
            purpose: purpose,
            prompt: prompt
        ) {
        case .approved: return
        case .denied: throw OxFunctionError(code: "permission_denied", message: "\(action): the user declined.", recovery: "Stop. Do not repeat the action unless the user asks.")
        case .blocked: throw OxFunctionError(code: "permission_denied", message: "\(action): the user blocked this Action in Settings.", recovery: "Do not bypass the policy. Ask the user to change it in Settings only if they want to allow this action.")
        case .stopped: throw OxFunctionError(code: "cancelled", message: "\(action): the user stopped before answering.", recovery: "Stop. Do not reopen the request unless the user asks.")
        }
    }

    func confirmScheduledSkillChange(action: String, prompt: String) async throws {
        permissionNeeded()
        let cancel = L10n.string("Cancel")
        let permission = PermissionPresentation(title: "Ox - \(action)", purpose: prompt)
        let answer = await awaitPrompt(
            prompt: permission.prompt,
            options: [action, cancel],
            kind: .permission,
            presentation: .application,
            autoApproval: nil,
            permission: permission
        )
        guard answer == action else {
            throw RuntimeError.bridge("The scheduled skill change was cancelled.")
        }
    }

    private func requestApproval(
        action: String,
        defaultPolicy: ActionPolicy,
        args: Any? = nil,
        purpose: String? = nil,
        prompt: String? = nil
    ) async -> ActionApproval.Outcome {
        await ActionApproval(serviceManager: serviceManager, ownerID: conversation.id, resolveService: { self.conversation.attachedService(domain: $0) }).request(
            action: action,
            defaultPolicy: defaultPolicy,
            args: args,
            purpose: purpose,
            prompt: prompt
        ) { request in
            permissionNeeded()
            let answer = await awaitPrompt(
                prompt: request.prompt,
                options: request.options,
                kind: .permission,
                presentation: .application,
                autoApproval: PendingPrompt.AutoApproval(
                    action: request.action,
                    defaultPolicy: defaultPolicy,
                    approve: request.approve,
                    alwaysApprove: request.alwaysApprove,
                    deny: request.deny
                ),
                permission: request.presentation
            )
            return answer == Conversation.abortedAnswer ? nil : answer
        }
    }

    private func deliverAttentionNotification(interactionID: UUID, phase: ConversationBackgroundPhase) {
        let identifier = "conversation.attention.\(conversation.id.uuidString).\(interactionID.uuidString)"
        attentionNotificationID = identifier
        let notificationTitle = conversation.title
        Task {
            do {
                let delivered = try await feedback.notifyAttention(
                    identifier: identifier,
                    title: notificationTitle,
                    body: phase.subtitle,
                    isCurrent: { [weak self] in
                        self?.activeID == interactionID
                            && self?.feedback.isBackground == true
                    }
                )
                Log.session.info("Conversation.attentionNotify id=\(interactionID) phase=\(phase.rawValue) delivered=\(delivered)")
            } catch {
                Log.session.error("Conversation.attentionNotify failed id=\(interactionID) error=\(error.localizedDescription)")
            }
        }
    }

    func clearAttentionNotification() {
        guard let identifier = attentionNotificationID else { return }
        attentionNotificationID = nil
        feedback.dismissAttention(identifier: identifier)
        Log.session.info("Conversation.attentionNotify cleared id=\(identifier)")
    }
}
