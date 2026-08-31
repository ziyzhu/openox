import Foundation
import WebKit
import UIKit
import Observation

enum ChatRetention: Equatable {
    case persisted
    case temporary
}

struct ChatContinuation {
    let meta: ChatMeta
    let turns: [Turn]
    let intent: String
    let attachments: [Artifact]
    let skillInvocation: UserSkillInvocation?
}

nonisolated enum ChatPromptPresentation: Equatable, Sendable {
    case conversation
    case application
}

nonisolated struct ChatPendingPrompt: Equatable, Sendable {
    let id: UUID
    let prompt: String
    let options: [String]
    let presentation: ChatPromptPresentation
}

nonisolated private struct ChatContextRestoration: Sendable {
    let checkpoint: AgentContextCheckpoint?
    let messages: [Message]
    let sourceTurns: [Turn]
    let boundary: Int?
    let recoveryReason: String?
}

@MainActor
@Observable
final class Chat: Identifiable {
    enum ExecutionLease {
        case userInitiated
        case externallyManaged
    }

    private enum AgentHapticPhase {
        case waitingForDelta
        case deltaReceived
    }

    private struct AgentConfiguration {
        let systemPrompt: String
        let tools: [any AgentTool]
    }

    struct PendingServiceControl: Identifiable, Equatable {
        let id: UUID
        let control: ServiceControl
    }

    struct PendingPrompt: Identifiable, Equatable {
        struct AutoApproval: Equatable {
            let action: String
            let approve: String
            let alwaysApprove: String
        }

        let id: UUID
        let kind: ChatPromptKind
        let prompt: String
        let options: [String]
        let presentation: ChatPromptPresentation
        let allowsCustomAnswer: Bool
        let autoApproval: AutoApproval?
    }

    enum Interaction: Equatable {
        case prompt(PendingPrompt)
        case serviceControl(PendingServiceControl)
    }

    enum Activity: Equatable {
        enum Idle: Equatable {
            case read
            case unread
        }

        enum AwaitingAction: Equatable {
            case approval
            case reply
            case signIn
            case verification
            case payment
        }

        enum Running: Equatable {
            case thinking
            case streaming
            case awaiting(AwaitingAction)
        }

        case idle(Idle)
        case running(Running)

        var isThinking: Bool {
            self == .running(.thinking)
        }

        var isAwaitingUser: Bool {
            if case .running(.awaiting) = self { true } else { false }
        }
    }

    enum Notice: Equatable {
        case none
        case error(String)

        var errorMessage: String? {
            if case .error(let message) = self { message } else { nil }
        }
    }

    struct ThinkingActivity: Equatable {
        let turnID: TurnID
        let startedAt: Date
    }

    private enum InteractionWaiter {
        case prompt(PendingPrompt, CheckedContinuation<PromptResult, Never>)
        case serviceControl(PendingServiceControl, CheckedContinuation<JSONValue?, Never>)

        var interaction: Interaction {
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

        var serviceDomain: String? {
            guard case .serviceControl(let control, _) = self else { return nil }
            return control.control.domain
        }

        func cancel() {
            switch self {
            case .prompt(_, let continuation): continuation.resume(returning: .cancelled)
            case .serviceControl(_, let continuation): continuation.resume(returning: nil)
            }
        }
    }

    let id: UUID
    let createdAt: Date
    let scheduledSkillID: UUID?
    let agent: Agent
    let javaScriptOutputs = JavaScriptOutputStore()
    @ObservationIgnored private(set) var agentSnapshot: AgentSnapshot?
    @ObservationIgnored private var agentControlTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationIntent = false
    @ObservationIgnored private var contextCheckpoint: AgentContextCheckpoint?
    @ObservationIgnored private var pendingCompactionTokens: Int?
    @ObservationIgnored private var pendingContextCompactions: [ContextCompaction] = []

    private(set) var client: any ProviderClient
    private(set) var model: ProviderModel
    private(set) var region: LLMRegion
    let presentations: AppPresentations
    let repository: ProfileRepository
    let scope: ProfileScope
    let serviceManager: ServiceManager
    let fileMutationCoordinator = FileMutationCoordinator.shared
    private(set) var retention: ChatRetention

    var isTemporary: Bool { retention == .temporary }
    var canChangeRetention: Bool { transcript.isEmpty && queuedMessages.isEmpty && !isBusy }

    func toggleRetention() -> Bool {
        guard canChangeRetention else {
            Log.session.info("Chat.retention ignored id=\(id) reason=started")
            return false
        }
        retention = isTemporary ? .persisted : .temporary
        Log.session.info("Chat.retention changed id=\(id) retention=\(String(describing: retention))")
        return true
    }

    func switchModel(to client: any ProviderClient, model: ProviderModel, region: LLMRegion) {
        self.client = client
        self.model = model
        self.region = region
        let configuration = agentConfiguration(client: client, model: model)
        enqueueAgentMutation { agent in
            await agent.configure(
                client: client,
                model: model,
                systemPrompt: configuration.systemPrompt,
                tools: configuration.tools
            )
        }
        scheduleModelPreparation()
        Log.session.info("Chat.switchModel id=\(id) -> client=\(client.id) model=\(model.id) reasoning=\(model.selectedReasoningEffort ?? "unavailable") region=\(region.rawValue)")
        onPersistableChange?()
    }

    func setModelPreparationIntent(_ active: Bool) {
        modelPreparationIntent = active
        scheduleModelPreparation()
    }

    private func scheduleModelPreparation() {
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        guard modelPreparationIntent, isSelected else { return }
        modelPreparationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self, self.modelPreparationIntent else { return }
            let client = self.client
            let model = self.model
            let configuration = self.agentConfiguration(client: client, model: model)
            let fingerprint = promptCacheKey(
                model: model,
                systemPrompt: configuration.systemPrompt,
                tools: configuration.tools
            )
            let started = Date()
            let outcome = await client.prepare(
                model: model,
                systemPrompt: configuration.systemPrompt,
                tools: configuration.tools
            )
            guard !Task.isCancelled else { return }
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            Log.perf.info("LLM.prepare chat=\(self.id) client=\(client.id) model=\(model.id) outcome=\(outcome.rawValue) ms=\(elapsed) fingerprint=\(fingerprint)")
        }
    }

    private(set) var attachedServices: [Service] = []
    @ObservationIgnored private var attachedServiceDomains: [String] = []
    @ObservationIgnored private var interactionWaiter: InteractionWaiter?
    @ObservationIgnored private var interactionQueue: [InteractionWaiter] = []

    var interaction: Interaction? {
        guard case .running(let run) = runState,
              case .awaiting(let interaction) = run.phase else { return nil }
        return interaction
    }

    var pendingServiceControl: PendingServiceControl? {
        guard case .serviceControl(let control) = interaction else { return nil }
        return control
    }

    private(set) var monoRepositoryHash: String?

    private(set) var isSelected = false
    private(set) var isTranscriptVisible = false
    private(set) var hasUnreadResponse = false
    @ObservationIgnored private var servicesAttached = false

    func select() {
        guard !isSelected else { return }
        isSelected = true
        outputDelivery.setVisibility(.visible)
        if outputDelivery.needsFrames { startStreamLink() }
        scheduleModelPreparation()
    }

    func setTranscriptVisible(_ visible: Bool) {
        isTranscriptVisible = visible
        guard visible, hasUnreadResponse else { return }
        hasUnreadResponse = false
        Log.session.info("Chat.read id=\(id)")
        onPersistableChange?()
    }

    func deselect() {
        guard isSelected else { return }
        isSelected = false
        setTranscriptVisible(false)
        serviceManager.browserActionSessions.closeSession(for: id)
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        outputDelivery.setVisibility(.hidden)
        stopStreamLink()
        finalizeBufferedTurnIfInactive()
    }

    func release(cancelling: Bool = true) {
        onPersistableChange = nil
        onPrivateDataTemporaryContinuation = nil
        modelPreparationIntent = false
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        deselect()
        if cancelling { cancelAll() }
        detach()
    }

    var customTitle: String?

    var isFavorite = false

    func setFavorite(_ favorite: Bool) {
        guard isFavorite != favorite else { return }
        isFavorite = favorite
        Log.session.info("Chat.setFavorite id=\(id) favorite=\(favorite)")
        onPersistableChange?()
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        for block in transcript {
            if case let .userText(s, _) = block.kind {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return String(t.prefix(60)) }
            }
            if case let .userSkill(invocation, _) = block.kind {
                return String(invocation.displayTitle.prefix(60))
            }
        }
        return "New chat"
    }

    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        Log.session.info("Chat.rename id=\(id) custom=\(customTitle != nil)")
        onPersistableChange?()
    }

    var latestAgentChatTitle: String? {
        for turn in document.turns.reversed() {
            guard case let .agent(agent, _) = turn else { continue }
            for step in agent.steps.reversed() {
                guard case let .execute(execution) = step.kind else { continue }
                for effect in execution.effects.reversed() {
                    guard case let .invocation(invocation) = effect,
                          invocation.name == InvocationName.appRenameChat.rawValue,
                          case let .succeeded(value) = invocation.outcome,
                          value?.objectValue?["renamed"]?.boolValue == true else { continue }
                    return value?.objectValue?["title"]?.stringValue
                }
            }
        }
        return nil
    }

    private func resolveTarget(_ name: String, label: String) throws -> (service: Service, id: String) {
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, ["web", "ios", "mcp"].contains(parts[0]) {
            let service = attachedServices.first { candidate in
                switch parts[0] {
                case "web": !candidate.isIOSService && !candidate.isMCPService && candidate.domain == parts[1]
                case "ios": candidate.isIOSService && candidate.domain == "ios:\(parts[1])"
                case "mcp": candidate.isMCPService && candidate.domain == parts[1]
                default: false
                }
            }
            guard let service else {
                throw RuntimeError.bridge("\(label): service '\(parts[0]):\(parts[1])' isn't attached to this chat.")
            }
            return (service, parts[2])
        }
        if attachedServices.count == 1, let only = attachedServices.first {
            return (only, name)
        }
        throw RuntimeError.bridge("\(label): use 'web:<domain>:\(name)', 'ios:<app>:\(name)', or 'mcp:<server>:\(name)' — the chat has \(attachedServices.count) services attached.")
    }


    @ObservationIgnored let virtualMachine: VirtualMachine

    func runDebugSnippet(_ source: String) async throws -> VirtualMachineOutput {
        try await virtualMachine.run(source: source, bridge: self)
    }

    private(set) var notice = Notice.none

    var activity: Activity {
        switch runState {
        case .idle:
            return .idle(hasUnreadResponse ? .unread : .read)
        case .running(let run):
            switch run.phase {
            case .thinking:
                return .running(.thinking)
            case .streaming, .finishing:
                return .running(.streaming)
            case .awaiting(let interaction):
                switch interaction {
                case .prompt(let prompt):
                    return .running(.awaiting(prompt.kind == .permission ? .approval : .reply))
                case .serviceControl(let pending):
                    switch pending.control {
                    case .signIn: return .running(.awaiting(.signIn))
                    case .botControl: return .running(.awaiting(.verification))
                    case .payment: return .running(.awaiting(.payment))
                    }
                }
            }
        }
    }

    var hasLiveTrace: Bool {
        guard isBusy else { return false }
        if case let .thinking(trace) = transcript.last?.kind, trace.completedAt == nil { return true }
        return false
    }

    var hasThinkingTail: Bool {
        guard isBusy else { return false }
        if case .thinking = transcript.last?.kind { return true }
        return false
    }

    var thinkingActivity: ThinkingActivity? {
        guard activity.isThinking,
              document.hasOpenAgentTurn,
              let turnID = document.lastAgentTurnID else { return nil }
        return ThinkingActivity(turnID: turnID, startedAt: document.currentAgentTurnAt)
    }

    @ObservationIgnored private var standaloneServiceInvocations: Set<UUID> = []

    var serviceOperations: ServiceOperations {
        ServiceOperations(
            serviceManager: serviceManager,
            resolveService: { [unowned self] domain in
                guard let service = attachedService(domain: domain) else {
                    throw RuntimeError.bridge("Service '\(domain)' isn't attached to this chat.")
                }
                return service
            },
            resolveAction: { [unowned self] name in try resolveTarget(name, label: "ox.service.invoke") },
            attachedDomains: { [unowned self] in Set(attachedServices.map(\.domain)) },
            approve: { [unowned self] action, args, prompt in
                try await requireApproval(action: action, args: args, prompt: prompt)
            },
            presentControl: { [unowned self] control, _ in
                let pending = embedServiceControl(control)
                return await waitForServiceControl(pending)
            },
            receiveArtifacts: { [unowned self] in try await importRemoteMCPArtifacts($0) },
            serviceChanged: { [unowned self] domain in
                let replacement = serviceManager.service(domain: domain)
                setAttachedServices(attachedServices.compactMap { $0.domain == domain ? replacement : $0 })
            },
            begin: { [unowned self] name, args, purpose in
                let standalone = ensureExecutionContext()
                let invocation = appendInvocation(name: name, purpose: purpose, args: args)
                if standalone { standaloneServiceInvocations.insert(invocation) }
                return invocation
            },
            finish: { [unowned self] invocation, result in
                switch result {
                case .success(let value):
                    resolveInvocation(invocationID: invocation, outcome: .succeeded(value))
                    if standaloneServiceInvocations.remove(invocation) != nil { finishStandaloneExecution() }
                case .failure(let error):
                    resolveInvocation(invocationID: invocation, outcome: .failed(error.localizedDescription))
                    if standaloneServiceInvocations.remove(invocation) != nil {
                        finishStandaloneExecution(output: error.localizedDescription, isError: true)
                    }
                }
            },
            native: nativeServiceOperations
        )
    }

    func callService(name: String, args: JSONValue, purpose: String) async -> Result<JSONValue, Error> {
        do { return .success(try await serviceOperations.invokeAction(name: name, args: args, purpose: purpose) ?? .null) }
        catch { return .failure(error) }
    }

    var nativeServiceOperations: NativeServiceOperations {
        NativeServiceOperations(
            id: id,
            serviceManager: serviceManager,
            presentations: presentations,
            requireActive: { [unowned self] in
                guard isSelected else { throw RuntimeError.bridge("Browser requires the active chat.") }
            },
            showBrowser: { [unowned self] service, _ in
                embedServiceInspector(ServiceInspectorLink(domain: service.domain, serviceName: service.title))
            },
            attachTransient: { [unowned self] attachment in
                guard document.hasOpenExecution else {
                    throw RuntimeError.bridge("Browser exports require an active agent execution.")
                }
                try appendTransientAttachment(attachment)
            },
            importArtifact: { [unowned self] attachment, filename in
                try requireProfileMutation(.artifactImport)
                let fileExtension = URL(fileURLWithPath: attachment.displayName).pathExtension
                let suggestedName = URL(fileURLWithPath: filename).pathExtension.isEmpty
                    ? "\(filename).\(fileExtension)"
                    : filename
                let artifact = try await ArtifactImporter.importDataAsync(
                    attachment.data,
                    suggestedName: suggestedName,
                    in: scope
                )
                embedArtifact(artifact)
                Log.session.info("Chat.importBrowserExport filename=\(artifact.fileName) bytes=\(attachment.data.count)")
                return artifact
            },
            choose: { [unowned self] prompt in
                if let purpose = prompt.purpose {
                    return try await chooseUser(body: prompt.body, options: prompt.options, purpose: purpose)?.stringValue
                }
                let answer = await awaitPrompt(
                    prompt: prompt.body, options: prompt.options,
                    presentation: .application, resolution: prompt.resolution
                )
                return answer == Self.abortedAnswer ? nil : answer
            }
        )
    }

    private func invokeIOSService(_ serviceID: String, actionID: String, args: JSONValue, purpose: String?) async throws -> JSONValue? {
        guard let service = attachedService(domain: serviceID) else {
            throw Service.InvokeError.unknown(serviceID)
        }
        return try await nativeServiceOperations.invoke(service: service, actionID: actionID, args: args, purpose: purpose)
    }

#if targetEnvironment(simulator)
    func debugInvokeIOSService(
        _ serviceID: String,
        actionID: String,
        args: JSONValue,
        purpose: String?
    ) async throws -> JSONValue? {
        try await invokeIOSService(serviceID, actionID: actionID, args: args, purpose: purpose)
    }
#endif

    // MARK: - Transcript (folded in from ChatManager)

    private var document = ChatDocument()
    private var currentExecutionArtifacts: [Artifact] = []
    var currentExecutionTransientAttachments: [(sequence: Int, attachment: TransientAttachment)] = []
    private var currentExecutionActivatedSkills: [String: ActivatedSkillContext] = [:]
    var currentExecutionFetchCount = 0
    var currentExecutionFetchBytes = 0
    var transcript: [Block] { document.projection }
    var transcriptBlockCount: Int { document.blockCount }
    var referencedArtifacts: [Artifact] { document.referencedArtifacts }
    var blocksWithTurnID: [(block: Block, turnID: TurnID)] { document.blocksWithTurnID() }

    func blocksWithTurnID(in range: Range<Int>) -> (range: Range<Int>, blocks: [(block: Block, turnID: TurnID)]) {
        document.blocksWithTurnID(in: range)
    }

    func pendingPrompt(excluding handled: Set<UUID> = []) -> ChatPendingPrompt? {
        guard case .prompt(let prompt) = interaction,
              !handled.contains(prompt.id) else { return nil }
        return ChatPendingPrompt(
            id: prompt.id,
            prompt: prompt.prompt,
            options: prompt.options,
            presentation: prompt.presentation
        )
    }

    func resolvePendingPrompt(_ request: ChatPendingPrompt, answer: String) {
        guard case .prompt(let prompt) = interaction,
              prompt.id == request.id,
              prompt.presentation == request.presentation else { return }
        resolvePrompt(blockId: request.id, answer: answer)
    }
    private(set) var lastActivityAt: Date?

    @ObservationIgnored var onPersistableChange: (() -> Void)?
    @ObservationIgnored var onPrivateDataTemporaryContinuation: ((ChatContinuation) -> Void)?

    static let abortedAnswer = "The user stopped before answering."

    private struct Submission {
        enum Kind: Equatable {
            case user
            case system(resume: TurnID?)
        }

        enum State {
            case queued
            case posted
            case consumed
            case cancelled
        }

        let id: SubmissionID
        let kind: Kind
        let text: String
        let attachments: [Artifact]
        let skillInvocation: UserSkillInvocation?
        let replyStyle: ReplyStyle
        let latency: TurnLatencyTrace
        var state: State

        var needsPosting: Bool {
            guard case .user = kind else { return false }
            return state == .queued
        }

        var queuedMessage: QueuedMessage? {
            guard needsPosting else { return nil }
            return QueuedMessage(id: id.rawValue, text: text, attachments: attachments, skillInvocation: skillInvocation)
        }

        mutating func post() {
            guard needsPosting else { return }
            state = .posted
        }

        mutating func consume() {
            state = .consumed
        }
    }
    struct QueuedMessage: Identifiable {
        let id: UUID
        let text: String
        let attachments: [Artifact]
        let skillInvocation: UserSkillInvocation?
    }

    struct SubmissionReceipt: Equatable {
        enum Disposition: String {
            case posted
            case queued
        }

        let id: UUID
        let disposition: Disposition
    }

    enum SubmissionAnchor: Equatable {
        case queued(UUID)
        case turn(blockID: UUID, submissionID: UUID?)

        var id: UUID {
            switch self {
            case .queued(let id): id
            case .turn(let blockID, _): blockID
            }
        }
    }

    var queuedMessages: [QueuedMessage] {
        submissions.compactMap(\.queuedMessage)
    }

    func anchor(forSubmissionID submissionID: UUID) -> SubmissionAnchor? {
        if let entry = document.turns.firstIndex(where: { entry in
            guard case .user(let turn, _) = entry else { return false }
            return turn.submissionID?.rawValue == submissionID
        }), let block = document.blocksWithTurn().first(where: { $0.1 == entry })?.0 {
            return .turn(blockID: block.id, submissionID: submissionID)
        }
        if submissions.contains(where: { $0.id.rawValue == submissionID && $0.needsPosting }) {
            return .queued(submissionID)
        }
        return nil
    }

    private enum RunPhase: Equatable {
        case thinking
        case streaming
        case awaiting(Interaction)
        case finishing

        var logLabel: String {
            switch self {
            case .thinking: "thinking"
            case .streaming: "streaming"
            case .awaiting: "awaiting"
            case .finishing: "finishing"
            }
        }
    }

    private enum AgentEventCycle {
        case completed(cancelled: Bool)
        case running(cancelled: Bool, continuation: CheckedContinuation<Void, Never>?)

        var isCompleted: Bool {
            if case .completed = self { true } else { false }
        }

        var isCancelled: Bool {
            switch self {
            case .completed(let cancelled), .running(let cancelled, _): cancelled
            }
        }

        mutating func begin() {
            self = .running(cancelled: false, continuation: nil)
        }

        mutating func cancel() {
            guard case .running(_, let continuation) = self else { return }
            self = .running(cancelled: true, continuation: continuation)
        }

        mutating func wait(_ continuation: CheckedContinuation<Void, Never>) {
            guard case .running(let cancelled, nil) = self else {
                continuation.resume()
                return
            }
            self = .running(cancelled: cancelled, continuation: continuation)
        }

        mutating func finish() {
            guard case .running(let cancelled, let continuation) = self else { return }
            self = .completed(cancelled: cancelled)
            continuation?.resume()
        }
    }

    private struct Run {
        let id: RunID
        let task: Task<Void, Never>
        var phase: RunPhase
        var activeSubmission: Submission?
        var backgroundExecutionExpired: Bool
        var backgroundExecution: ChatBackgroundExecution?
        var completionNotification: CompletionNotification?
    }

    private struct CompletionNotification {
        let title: String
        let body: String
    }

    private enum PromptResult {
        case answered(String)
        case cancelled
    }

    private enum RunState {
        case idle
        case running(Run)

        var isRunning: Bool {
            if case .idle = self { false } else { true }
        }

        var task: Task<Void, Never>? {
            switch self {
            case .idle: nil
            case .running(let run): run.task
            }
        }

        var id: RunID? {
            switch self {
            case .idle: nil
            case .running(let run): run.id
            }
        }

        var phase: RunPhase? {
            switch self {
            case .idle: nil
            case .running(let run): run.phase
            }
        }

        var backgroundExecution: ChatBackgroundExecution? {
            switch self {
            case .idle: nil
            case .running(let run): run.backgroundExecution
            }
        }

        var completionNotification: CompletionNotification? {
            switch self {
            case .idle: nil
            case .running(let run): run.completionNotification
            }
        }

        var activeSubmission: Submission? {
            switch self {
            case .idle: nil
            case .running(let run): run.activeSubmission
            }
        }

        var backgroundExecutionExpired: Bool {
            switch self {
            case .idle: false
            case .running(let run): run.backgroundExecutionExpired
            }
        }

        mutating func setBackgroundExecution(_ execution: ChatBackgroundExecution?) {
            switch self {
            case .idle:
                break
            case .running(var run):
                run.backgroundExecution = execution
                self = .running(run)
            }
        }

        mutating func setCompletionNotification(_ notification: CompletionNotification) {
            guard case .running(var run) = self else { return }
            run.completionNotification = notification
            self = .running(run)
        }

        mutating func setActiveSubmission(_ submission: Submission?, runID: RunID) {
            guard case .running(var run) = self, run.id == runID else { return }
            run.activeSubmission = submission
            self = .running(run)
        }

        mutating func expireBackgroundExecution() {
            guard case .running(var run) = self else { return }
            run.backgroundExecutionExpired = true
            self = .running(run)
        }
    }
    private var runState: RunState = .idle
    private var submissions: [Submission] = []
    var isBusy: Bool { runState.isRunning }
    var hasPendingInteraction: Bool {
        guard case .running(let run) = runState else { return false }
        if case .awaiting = run.phase { return true }
        return false
    }
    @ObservationIgnored private var eventConsumer: Task<Void, Never>?
    @ObservationIgnored private var streamedText = ""
    @ObservationIgnored private var streamedTextBlockIndex: Int?
    @ObservationIgnored private var agentHapticPhase = AgentHapticPhase.waitingForDelta
    @ObservationIgnored private var activeLatency: TurnLatencyTrace?
    @ObservationIgnored private var agentEventCycle = AgentEventCycle.completed(cancelled: false)
    @ObservationIgnored private var submissionWaiters: [SubmissionID: CheckedContinuation<ChatSubmissionOutcome, Never>] = [:]
    @ObservationIgnored private let executionLease: ExecutionLease

    private let outputDelivery = OutputDelivery()
    @ObservationIgnored private var streamingDeliveryContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var streamingTurnDelivered = true
    @ObservationIgnored private lazy var streamFrameDriver = StreamFrameDriver(handler: { [weak self] timestamp in self?.onStreamFrame(at: timestamp) })

    static func userFacingError(_ raw: String, kind: LLMFailureKind?) -> String {
        if kind == .rateLimited {
            return "Rate limit reached — the model provider's quota is exhausted. Try again later or switch model."
        }
        if kind == .network {
            return "Network error — check your connection and try again."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
    }

    init(id: UUID = UUID(),
         createdAt: Date = Date(),
         client: any ProviderClient,
         model: ProviderModel,
         region: LLMRegion,
         repository: ProfileRepository,
         scope: ProfileScope,
         virtualMachine: VirtualMachine,
         presentations: AppPresentations,
         serviceManager: ServiceManager,
         retention: ChatRetention = .persisted,
         executionLease: ExecutionLease = .userInitiated,
         scheduledSkillID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.scheduledSkillID = scheduledSkillID
        self.client = client
        self.region = region
        self.repository = repository
        self.scope = scope
        self.virtualMachine = virtualMachine
        self.presentations = presentations
        self.serviceManager = serviceManager
        self.retention = retention
        self.executionLease = executionLease
        self.model = model
        self.monoRepositoryHash = serviceManager.monoRepositoryHash
        Log.session.info("Chat created id=\(id) client=\(client.id) model=\(model.id) reasoning=\(model.selectedReasoningEffort ?? "unavailable") region=\(region.rawValue) server=\(serviceManager.serverURL.absoluteString)")
        self.agent = Agent(
            client: client,
            model: model,
            sessionID: id.uuidString,
            transformContext: { request in
                let messages = await ChatURLServiceContext.transform(
                    request.messages,
                    serviceManager: serviceManager,
                    chatID: id
                )
                return await ModelAdapterPipeline.transform(messages: messages, model: request.model)
            }
        )
        let stream = agent.events
        self.eventConsumer = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .agentStart:
                    self.pendingContextCompactions = []
                    self.beginAgentTurn()
                case .turnStart(let model, _):
                    self.setRunPhase(.thinking)
                    self.resetStreamedText()
                    self.document.apply(.beginGeneration(model: model, at: Date()))
                    for compaction in self.pendingContextCompactions {
                        self.document.apply(.appendContextCompaction(compaction))
                    }
                    self.pendingContextCompactions = []
                case .messageStart(.assistant):
                    self.resetStreamedText()
                case .messageUpdate(_, let event):
                    self.applyAssistantEvent(event)
                case .reasoning(let text):
                    self.appendReasoning(text)
                case .messageEnd(.assistant(let assistant)):
                    self.document.apply(.setGenerationAssistant(assistant))
                    self.applyAssistantFinal(assistant)
                    self.endStreamingTurn(assistant)
                case .turnEnd(let assistant, _):
                    await self.waitForStreamingDelivery()
                    self.document.apply(.finishGeneration(Self.outcome(for: assistant, at: Date())))
                    self.requestPersistence(.generationFinished)
                    self.runState.backgroundExecution?.advance()
                case .agentEnd:
                    self.runState.backgroundExecution?.updatePhase(.finishing)
                    await self.agent.waitForIdle()
                    let snapshot = await self.agent.snapshot()
                    self.agentSnapshot = snapshot
                    self.finishAgentTurnFromEvents(error: snapshot.errorMessage)
                    self.requestPersistence(.agentTurnFinished)
                    self.agentEventCycle.finish()
                case .compacted(let before, let after, let chars, let tokensBefore):
                    self.pendingCompactionTokens = tokensBefore
                    let compaction = ContextCompaction(at: Date(), tokensBefore: tokensBefore)
                    if self.document.lastGenerationID == nil {
                        self.pendingContextCompactions.append(compaction)
                    } else {
                        self.document.apply(.appendContextCompaction(compaction))
                    }
                    Log.session.info("Chat compacted id=\(self.id) msgs \(before)->\(after) summaryChars=\(chars) tokensBefore=\(tokensBefore)")
                case .paused:
                    Log.session.info("Chat.agentPaused id=\(self.id)")
                    self.requestPersistence(.paused)
                case .resumed:
                    Log.session.info("Chat.resumed id=\(self.id)")
                case .toolExecutionStart:
                    self.runState.backgroundExecution?.updatePhase(.working)
                case .toolExecutionEnd(let toolCall, let result):
                    self.document.apply(.recordToolExchange(toolCall, result))
                    self.runState.backgroundExecution?.advance()
                    self.runState.backgroundExecution?.updatePhase(.thinking)
                case .messageStart(_),
                     .messageEnd(_):
                    break
                }
            }
        }
        let configuration = agentConfiguration(client: client, model: model)
        enqueueAgentMutation { agent in
            await agent.configure(
                client: client,
                model: model,
                systemPrompt: configuration.systemPrompt,
                tools: configuration.tools
            )
        }
    }

    convenience init(
        meta: ChatMeta,
        turns: [Turn],
        context: AgentContextCheckpoint? = nil,
        client: any ProviderClient,
        model: ProviderModel,
        region: LLMRegion,
        repository: ProfileRepository,
        scope: ProfileScope,
        virtualMachine: VirtualMachine,
        presentations: AppPresentations,
        serviceManager: ServiceManager,
        retention: ChatRetention = .persisted,
        executionLease: ExecutionLease = .userInitiated
    ) {
        self.init(
            id: meta.id,
            createdAt: meta.createdAt,
            client: client,
            model: model,
            region: region,
            repository: repository,
            scope: scope,
            virtualMachine: virtualMachine,
            presentations: presentations,
            serviceManager: serviceManager,
            retention: retention,
            executionLease: executionLease,
            scheduledSkillID: meta.scheduledSkillID
        )
        monoRepositoryHash = meta.monoRepositoryHash
        customTitle = meta.title
        isFavorite = meta.isFavorite
        document = ChatDocument(turns: turns)
        document.apply(.sealAllTurns)
        let recovered = document.turns != turns
        attachedServiceDomains = Self.uniqueServiceDomains(meta.attachedServiceDomains)
        if attachedServiceDomains.count != meta.attachedServiceDomains.count {
            Log.session.warning("Chat.restore deduplicated-services id=\(meta.id) stored=\(meta.attachedServiceDomains.count) unique=\(attachedServiceDomains.count)")
        }
        hasUnreadResponse = meta.hasUnreadResponse
        resolveAttachedServices()
        contextCheckpoint = context
        let restoredTurns = document.turns
        let restorationTask = Task.detached(priority: .userInitiated) {
            Self.resolveContext(context: context, turns: restoredTurns)
        }
        restoreAgent(from: restorationTask)
        lastActivityAt = meta.lastActivity
        Log.session.info("Chat restored id=\(meta.id) turns=\(turns.count) blocks=\(transcript.count) services=\(attachedServices.count) recovered=\(recovered) context=pending")
    }

    var metadata: ChatMeta {
        ChatMeta(
            id: id,
            createdAt: createdAt,
            lastActivity: lastActivityAt,
            title: customTitle,
            isFavorite: isFavorite,
            modelID: model.id,
            clientID: client.id,
            region: region,
            reasoningEffort: model.selectedReasoningEffort,
            monoRepositoryHash: monoRepositoryHash,
            attachedServiceDomains: attachedServiceDomains,
            preview: document.preview,
            hasUnreadResponse: hasUnreadResponse,
            scheduledSkillID: scheduledSkillID
        )
    }

    var state: ChatState {
        ChatState(meta: metadata, turns: document.turns, context: contextCheckpoint)
    }

    func exportTranscript() async throws -> Data {
        try await repository.export(state)
    }

    @discardableResult
    func syncToMonoRepository() async -> [String] {
        resolveAttachedServices()
        let manager = serviceManager
        guard let head = manager.monoRepositoryHash, head != monoRepositoryHash else { return [] }
        defer {
            monoRepositoryHash = head
            onPersistableChange?()
        }
        guard let since = monoRepositoryHash else { return [] }
        let changed = await manager.changedServiceDomains(since: since)
        let affected = attachedServices.filter { changed?.contains($0.domain) ?? true }
        guard !affected.isEmpty else { return [] }
        for svc in affected {
            svc.invalidateResolved()
            _ = await svc.loadManifest()
        }
        Log.session.info("Chat.syncToMonoRepository id=\(id) \(since.prefix(7))->\(head.prefix(7)) reloaded=\(affected.map(\.domain).joined(separator: ","))")
        return affected.map(\.title)
    }

    // MARK: - Transcript mutation (was ChatManager)

    private func markActivity(_ date: Date = Date(), persist: Bool = true) {
        lastActivityAt = date
        if persist { onPersistableChange?() }
    }

    private enum PersistenceCheckpoint: String {
        case generationFinished
        case agentTurnFinished
        case paused
    }

    private func requestPersistence(_ checkpoint: PersistenceCheckpoint) {
        Log.session.debug("Chat.persistence checkpoint id=\(id) checkpoint=\(checkpoint.rawValue) generationOpen=\(document.hasOpenGeneration) turnOpen=\(document.hasOpenAgentTurn)")
        onPersistableChange?()
    }

    private func beginAgentTurn() {
        setRunPhase(.thinking)
        runState.backgroundExecution?.updatePhase(.thinking)
        switch runState.activeSubmission?.kind {
        case let .system(.some(target)):
            document.apply(.resumeAgentTurn(id: target))
        case .user, .system, nil:
            document.apply(.beginAgentTurn(at: Date()))
        }
    }

    private func growAgentText(_ delta: String) {
        setRunPhase(.streaming)
        runState.backgroundExecution?.updatePhase(.responding)
        document.apply(.appendText(delta))
        runState.backgroundExecution?.advance()
    }

    func beginExecution(source: String) {
        flushBufferedAgentText()
        currentExecutionArtifacts = []
        currentExecutionTransientAttachments = []
        currentExecutionActivatedSkills = [:]
        currentExecutionFetchCount = 0
        currentExecutionFetchBytes = 0
        runState.backgroundExecution?.updatePhase(.working)
        document.apply(.beginExecution(source: source))
    }

    private func flushBufferedAgentText() {
        let text = outputDelivery.drainText()
        guard !text.isEmpty else { return }
        if isSelected { activeLatency?.mark(.firstTextVisible) }
        growAgentText(text)
    }

    func executionAttachments() -> (artifacts: [Artifact], transient: [TransientAttachment]) {
        (
            currentExecutionArtifacts,
            currentExecutionTransientAttachments.sorted { $0.sequence < $1.sequence }.map(\.attachment)
        )
    }

    func executionActivatedSkills() -> [ActivatedSkillContext] {
        currentExecutionActivatedSkills.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func activateSkill(name: String, path: String, content: String) {
        currentExecutionActivatedSkills[path] = ActivatedSkillContext(
            name: name,
            path: path,
            content: content
        )
        Log.session.info("Chat.activateSkill name=\(name) chars=\(content.count)")
    }

    func finishExecution(output: String, isError: Bool) {
        document.apply(.finishExecution(output: output, isError: isError))
        currentExecutionTransientAttachments = []
        currentExecutionActivatedSkills = [:]
        currentExecutionFetchBytes = 0
        runState.backgroundExecution?.advance()
        runState.backgroundExecution?.updatePhase(.thinking)
    }

    @discardableResult
    func embedServiceControl(_ control: ServiceControl) -> PendingServiceControl {
        let standalone = ensureExecutionContext()
        let pending = PendingServiceControl(id: UUID(), control: control)
        document.apply(.embedServiceControl(control))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.embedServiceControl id=\(pending.id.uuidString) domain=\(control.domain)")
        return pending
    }

    func resolveServiceControl(id controlID: UUID, result: JSONValue?) {
        guard case .serviceControl(let control, let continuation) = interactionWaiter else {
            Log.session.warning("Chat.resolveServiceControl ignored id=\(controlID) reason=no-active-service-control")
            return
        }
        guard control.id == controlID else {
            Log.session.warning("Chat.resolveServiceControl ignored id=\(controlID) active=\(control.id) reason=id-mismatch")
            return
        }
        interactionWaiter = nil
        advanceInteraction()
        continuation.resume(returning: result)
        Log.session.info("Chat.resolveServiceControl id=\(controlID) succeeded=\(result != nil)")
    }

    func waitForServiceControl(_ control: PendingServiceControl) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            guard isBusy else {
                continuation.resume(returning: nil)
                return
            }
            enqueueInteraction(.serviceControl(control, continuation))
        }
    }

    private func enqueueInteraction(_ waiter: InteractionWaiter) {
        guard interactionWaiter == nil else {
            interactionQueue.append(waiter)
            Log.session.info("Chat.interaction queued id=\(waiter.id) depth=\(interactionQueue.count)")
            return
        }
        activateInteraction(waiter)
    }

    private func activateInteraction(_ waiter: InteractionWaiter) {
        interactionWaiter = waiter
        replaceRunPhase(.awaiting(waiter.interaction))
        runState.backgroundExecution?.finish(success: true)
        runState.setBackgroundExecution(nil)
        Log.session.info("Chat.interaction active id=\(waiter.id) queued=\(interactionQueue.count)")
        observeAutoApproval()
    }

    private func observeAutoApproval() {
        guard case .prompt(let prompt, _) = interactionWaiter,
              let approval = prompt.autoApproval else { return }
        let approved = withObservationTracking {
            serviceManager.shouldAutoApprove(approval.action)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.interactionWaiter?.id == prompt.id else { return }
                self.observeAutoApproval()
            }
        }
        guard approved else { return }
        Log.session.info("Chat.interaction autoApproved id=\(prompt.id) action=\(approval.action) global=\(serviceManager.autoApproveAll)")
        resolvePrompt(blockId: prompt.id, answer: approval.approve)
    }

    private func advanceInteraction() {
        while !interactionQueue.isEmpty {
            let waiter = interactionQueue.removeFirst()
            if case .prompt(let prompt, let continuation) = waiter,
               let approval = prompt.autoApproval,
               serviceManager.shouldAutoApprove(approval.action) {
                Log.session.info("Chat.interaction autoApproved id=\(prompt.id) action=\(approval.action) global=\(serviceManager.autoApproveAll)")
                continuation.resume(returning: .answered(approval.approve))
                continue
            }
            activateInteraction(waiter)
            return
        }
        replaceRunPhase(.thinking)
        startBackgroundExecution()
    }

    private func cancelInteractions() {
        var waiters = interactionQueue
        if let interactionWaiter { waiters.insert(interactionWaiter, at: 0) }
        interactionWaiter = nil
        interactionQueue.removeAll()
        if interaction != nil { replaceRunPhase(.thinking) }
        for waiter in waiters { waiter.cancel() }
        if !waiters.isEmpty {
            Log.session.info("Chat.interaction canceled count=\(waiters.count)")
        }
    }

    private func cancelServiceInteractions(domains: Set<String>) {
        guard !domains.isEmpty else { return }
        var cancelled: [InteractionWaiter] = []
        let removedActive = interactionWaiter?.serviceDomain.map(domains.contains) == true
        if removedActive, let interactionWaiter {
            cancelled.append(interactionWaiter)
            self.interactionWaiter = nil
        }
        interactionQueue.removeAll { waiter in
            guard waiter.serviceDomain.map(domains.contains) == true else { return false }
            cancelled.append(waiter)
            return true
        }
        for waiter in cancelled { waiter.cancel() }
        guard !cancelled.isEmpty else { return }
        Log.session.info("Chat.serviceInteractions canceled domains=\(domains.sorted().joined(separator: ",")) count=\(cancelled.count)")
        if removedActive { advanceInteraction() }
    }

    func embedArtifact(_ artifact: Artifact) {
        let standalone = ensureExecutionContext()
        appendExecutionArtifact(artifact)
        document.apply(.embedArtifact(artifact))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.embedArtifact filename=\(artifact.fileName)")
    }

    func embedShoveler(_ shoveler: Shoveler) {
        let standalone = ensureExecutionContext()
        document.apply(.embedShoveler(shoveler))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.embedShoveler cards=\(shoveler.cards.count)")
    }

    func embedVideo(_ video: VideoWidget) {
        let standalone = ensureExecutionContext()
        document.apply(.embedVideo(video))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.embedVideo source=\(video.source.artifact?.fileName ?? "remote")")
    }

    private func embedServiceInspector(_ link: ServiceInspectorLink) {
        let standalone = ensureExecutionContext()
        document.apply(.embedServiceInspector(link))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.embedServiceInspector domain=\(link.domain)")
    }

    func embedSkill(_ skill: Skill) {
        let standalone = ensureExecutionContext()
        document.apply(.embedSkill(skill))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.embedSkill name=\(skill.name)")
    }

    private func attachMedia(_ artifact: Artifact) {
        let standalone = ensureExecutionContext()
        appendExecutionArtifact(artifact)
        document.apply(.attachMedia(artifact))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Chat.attachMedia filename=\(artifact.fileName)")
    }

    func renameArtifactReferences(from oldName: String, to newName: String, directory: URL) {
        invalidateContextCheckpoint(reason: "artifact-rename")
        document.renameArtifactReferences(from: oldName, to: newName, directory: directory)
    }

    private func appendExecutionArtifact(_ artifact: Artifact) {
        guard !currentExecutionArtifacts.contains(where: {
            $0.fileName.caseInsensitiveCompare(artifact.fileName) == .orderedSame
        }) else { return }
        currentExecutionArtifacts.append(artifact)
    }

    @discardableResult
    func ensureExecutionContext() -> Bool {
        guard !document.hasOpenExecution else { return false }
        Log.session.info("Chat.ensureExecutionContext effect outside execution; opening a standalone turn")
        if !document.hasOpenAgentTurn {
            if case let .agent(_, id) = document.turns.last {
                invalidateContextCheckpoint(reason: "standalone-execution")
                document.apply(.resumeAgentTurn(id: id))
            } else {
                document.apply(.beginAgentTurn(at: Date()))
            }
        }
        if !document.hasOpenGeneration {
            document.apply(.beginGeneration(model: model.id, at: Date()))
        }
        beginExecution(source: "")
        return true
    }

    private func finishStandaloneExecution(output: String = "", isError: Bool = false) {
        document.apply(.finishExecution(output: output, isError: isError))
        guard !isBusy else { return }
        let outcome: TurnOutcome = isError
            ? .failed(at: Date(), message: output)
            : .completed(at: Date())
        if document.hasOpenGeneration { document.apply(.finishGeneration(outcome)) }
        if document.hasOpenAgentTurn { document.apply(.finishAgentTurn(outcome)) }
        let messages = ChatProjection.makeWireMessages(from: document.turns)
        restoreAgent(messages: messages)
        installContextCheckpoint(messages: messages, tokensBefore: nil)
        requestPersistence(.agentTurnFinished)
    }

    func clearNotice() {
        notice = .none
    }

    func appendReportedProgress(_ message: String) throws {
        guard document.hasOpenExecution else {
            throw RuntimeError.bridge("ox.user.reportProgress: no JavaScript execution is active")
        }
        document.apply(.appendProgress(message))
        runState.backgroundExecution?.advance()
    }

    @discardableResult
    func awaitPrompt(
        prompt: String,
        options: [String],
        kind: ChatPromptKind = .choice,
        allowsCustomAnswer: Bool = false,
        presentation: ChatPromptPresentation = .conversation,
        autoApproval: PendingPrompt.AutoApproval? = nil,
        resolution: ((String) -> String?)? = nil
    ) async -> String {
        let stepID = StepID()
        document.apply(.appendPrompt(AgentPrompt(prompt: prompt, options: options, outcome: .pending), choice: kind == .choice, id: stepID))
        markActivity()
        guard let blockId = transcript.last?.id else { return options.first ?? "" }
        let pending = PendingPrompt(
            id: blockId,
            kind: kind,
            prompt: prompt,
            options: options,
            presentation: presentation,
            allowsCustomAnswer: allowsCustomAnswer,
            autoApproval: autoApproval
        )
        Log.session.info("Chat.awaitPrompt id=\(id) kind=\(kind.rawValue) presentation=\(String(describing: presentation)) options=\(options.count)")
        let result = await waitForPrompt(pending)
        let answer: String
        let cancelled: Bool
        switch result {
        case .answered(let value):
            answer = value
            cancelled = false
        case .cancelled:
            answer = Self.abortedAnswer
            cancelled = true
        }
        let resolved = cancelled ? L10n.string( "Stopped") : resolution?(answer)
        document.apply(cancelled
            ? .cancelPrompt(id: stepID, answer: answer, resolution: resolved)
            : .resolvePrompt(id: stepID, answer: answer, resolution: resolved))
        markActivity()
        return answer
    }

    func resolvePrompt(blockId: UUID, answer: String) {
        guard case .prompt(let prompt, let continuation) = interactionWaiter,
              prompt.id == blockId else { return }
        if let approval = prompt.autoApproval,
           answer == approval.alwaysApprove {
            serviceManager.setAutoApprove(approval.action, true)
        }
        interactionWaiter = nil
        advanceInteraction()
        continuation.resume(returning: .answered(answer))
    }

    private func waitForPrompt(_ prompt: PendingPrompt) async -> PromptResult {
        await withCheckedContinuation { continuation in
            if !isBusy {
                Log.session.error("Chat prompt outside run id=\(id) block=\(prompt.id)")
                continuation.resume(returning: .cancelled)
            } else {
                enqueueInteraction(.prompt(prompt, continuation))
            }
        }
    }

    @discardableResult
    func appendInvocation(name: String, purpose: String, args: JSONValue) -> UUID {
        ensureExecutionContext()
        let invocation = Invocation(name: name, purpose: purpose, args: args)
        document.apply(.appendInvocation(invocation))
        Log.session.info("Chat.invocation appended id=\(invocation.id) name=\(name) purpose=\(purpose)")
        return invocation.id
    }

    func appendReasoning(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runState.backgroundExecution?.updatePhase(.thinking)
        document.apply(.appendReasoning(trimmed))
        runState.backgroundExecution?.advance()
    }

    private func resetStreamedText() {
        streamedText = ""
        streamedTextBlockIndex = nil
    }

    private func applyAssistantEvent(_ event: AssistantEvent) {
        switch event {
        case .textDelta(let index, let delta, _):
            guard !delta.isEmpty else { return }
            registerAgentDelta()
            runState.backgroundExecution?.updatePhase(.responding)
            let chunk = streamedTextBlockIndex == nil || streamedTextBlockIndex == index ? delta : "\n" + delta
            streamedTextBlockIndex = index
            streamedText += chunk
            bufferAssistantDelta(chunk)
        case .thinkingDelta(_, let delta, _):
            guard !delta.isEmpty else { return }
            registerAgentDelta()
        case .toolCallDelta:
            registerAgentDelta()
        case .start, .textEnd, .thinkingEnd, .toolCallEnd, .done, .failed:
            break
        }
    }

    private func registerAgentDelta() {
        guard agentHapticPhase == .waitingForDelta else { return }
        agentHapticPhase = .deltaReceived
        if isSelected { Haptics.impact(.agentDeltaReceived) }
    }

    private func applyAssistantFinal(_ assistant: AssistantMessage) {
        let text = assistant.content.compactMap { block -> String? in
            if case .text(let value) = block { return value.text }
            return nil
        }.joined(separator: "\n")
        guard !text.hasPrefix(streamedText) else {
            let delta = String(text.dropFirst(streamedText.count))
            streamedText = text
            bufferAssistantDelta(delta)
            return
        }
        Log.session.warning("Chat.stream reconciliation id=\(id) streamedChars=\(streamedText.count) finalChars=\(text.count)")
        outputDelivery.discardText()
        streamedText = text
        if isSelected { activeLatency?.mark(.firstTextVisible) }
        document.apply(.replaceGenerationText(text))
    }

    private func bufferAssistantDelta(_ delta: String) {
        outputDelivery.append(delta)
        startStreamLink()
    }

    func resolveInvocation(invocationID: UUID, outcome: Invocation.Outcome) {
        document.apply(.resolveInvocation(id: invocationID, outcome: outcome))
    }

    func tracked<T>(_ name: InvocationName, _ args: JSONValue, purpose: String, _ body: () async throws -> T) async throws -> T {
        let standalone = ensureExecutionContext()
        let invocationID = appendInvocation(name: name.rawValue, purpose: purpose, args: args)
        do {
            let value = try await body()
            resolveInvocation(invocationID: invocationID, outcome: .succeeded(Self.outcomeValue(value)))
            if standalone { finishStandaloneExecution() }
            return value
        } catch {
            resolveInvocation(invocationID: invocationID, outcome: .failed(error.localizedDescription))
            if standalone { finishStandaloneExecution(output: error.localizedDescription, isError: true) }
            throw error
        }
    }

    func trackedEffect<T, Effect>(
        _ name: InvocationName,
        _ args: JSONValue,
        purpose: String,
        apply: (Effect) -> Void,
        _ body: () async throws -> (T, Effect)
    ) async throws -> T {
        let standalone = ensureExecutionContext()
        let invocationID = appendInvocation(name: name.rawValue, purpose: purpose, args: args)
        do {
            let (value, effect) = try await body()
            resolveInvocation(invocationID: invocationID, outcome: .succeeded(Self.outcomeValue(value)))
            apply(effect)
            if standalone { finishStandaloneExecution() }
            return value
        } catch {
            resolveInvocation(invocationID: invocationID, outcome: .failed(error.localizedDescription))
            if standalone { finishStandaloneExecution(output: error.localizedDescription, isError: true) }
            throw error
        }
    }

    private static func outcomeValue(_ value: Any?) -> JSONValue? {
        if let value = value as? JSONValue { return value == .null ? nil : value }
        guard let value, !(value is NSNull) else { return nil }
        return .from(value)
    }

    // MARK: - Approval gate

    static func attachApproveKey(_ domain: String) -> String { "ox.service.attach:\(domain)" }
    static func fileApproveKey(_ action: InvocationName) -> String { "ios:files:\(action.rawValue)" }

    func gateServiceAttach(_ service: Service) async throws {
        let title = "\(service.title) - \(L10n.string( "Attach"))"
        let message = if service.isIOSService {
            L10n.string("Its actions and permitted device data become available to this chat.")
        } else if service.isMCPService {
            L10n.string("Its remote tools can receive arguments from this chat and return data to Ox.")
        } else {
            L10n.string("Its actions and your signed-in data become available to this chat.")
        }
        switch await requestApproval(
            action: Self.attachApproveKey(service.domain),
            prompt: "\(title)\n\(message)"
        ) {
        case .approved: return
        case .denied: throw RuntimeError.bridge("ox.service.attach: the user declined to attach \(service.title).")
        case .stopped: throw RuntimeError.bridge("ox.service.attach: the user stopped before attaching \(service.title).")
        }
    }

    private typealias ApprovalOutcome = ServiceApproval.Outcome

    func requireApproval(action: String, args: Any? = nil, prompt: String? = nil) async throws {
        switch await requestApproval(action: action, args: args, prompt: prompt) {
        case .approved: return
        case .denied: throw RuntimeError.bridge("\(action): the user declined.")
        case .stopped: throw RuntimeError.bridge("\(action): the user stopped before answering.")
        }
    }

    func requireProfileMutation(_ action: InvocationName) throws {
        guard retention == .persisted else {
            Log.session.info("Chat.temporary blocked action=\(action.rawValue)")
            throw RuntimeError.bridge("\(action.rawValue): Temporary chats can't save changes. Continue in a Profile stored on this device to keep this result.")
        }
    }

    func confirmScheduledSkillChange(action: String, prompt: String) async throws {
        runState.backgroundExecution?.updatePhase(.permissionNeeded)
        let cancel = L10n.string("Cancel")
        let answer = await awaitPrompt(
            prompt: prompt,
            options: [action, cancel],
            kind: .permission,
            presentation: .application,
            autoApproval: nil
        )
        guard answer == action else {
            throw RuntimeError.bridge("The scheduled skill change was cancelled.")
        }
    }

    private func requestApproval(action: String, args: Any? = nil, prompt: String? = nil) async -> ApprovalOutcome {
        await ServiceApproval(serviceManager: serviceManager, ownerID: id, resolveService: { self.attachedService(domain: $0) }).request(action: action, args: args, prompt: prompt) { request in
            runState.backgroundExecution?.updatePhase(.permissionNeeded)
            let answer = await awaitPrompt(
                prompt: request.prompt,
                options: request.options,
                kind: .permission,
                presentation: .application,
                autoApproval: PendingPrompt.AutoApproval(
                    action: request.action,
                    approve: request.approve,
                    alwaysApprove: request.alwaysApprove
                )
            )
            return answer == Self.abortedAnswer ? nil : answer
        }
    }

    // MARK: - Branch / retry

    private func rerunCut(at blockId: UUID) -> (cutEntry: Int, text: String, attachments: [Artifact], skillInvocation: UserSkillInvocation?)? {
        guard let target = document.blocksWithTurn().first(where: { $0.0.id == blockId })?.1 else { return nil }
        for ei in stride(from: target, through: 0, by: -1) {
            if case let .user(turn, _) = document.turns[ei] {
                return (ei, turn.intent, turn.attachments, turn.skillInvocation)
            }
        }
        return nil
    }

    @discardableResult
    func retry(at blockId: UUID) -> SubmissionReceipt? {
        rerun(at: blockId, replacingText: nil)
    }

    @discardableResult
    func editAndRerun(at blockId: UUID, newText: String) -> SubmissionReceipt? {
        rerun(at: blockId, replacingText: newText)
    }

    private func rerun(at blockId: UUID, replacingText: String?) -> SubmissionReceipt? {
        guard let cut = rerunCut(at: blockId) else {
            Log.session.warning("Chat.rerun no cut for block=\(blockId)")
            return nil
        }
        let text = replacingText ?? cut.text
        Log.session.info("Chat.rerun id=\(id) at=\(blockId) cutEntry=\(cut.cutEntry) edited=\(replacingText != nil)")
        cancelAll()
        invalidateContextCheckpoint(reason: "rerun")
        document.apply(.truncate(beforeTurn: cut.cutEntry))
        restoreAgent(messages: document.toWire())
        markActivity()
        return enqueue(
            text,
            attachments: cut.attachments,
            skillInvocation: replacingText == nil ? cut.skillInvocation : nil
        )
    }

    func branchSnapshot(at blockId: UUID) -> ChatContinuation? {
        guard let cut = rerunCut(at: blockId) else { return nil }
        return continuation(
            before: cut.cutEntry,
            intent: cut.text,
            attachments: cut.attachments,
            skillInvocation: cut.skillInvocation
        )
    }

    func latestContinuation() -> ChatContinuation? {
        if let activeSubmission = runState.activeSubmission, case .user = activeSubmission.kind {
            if let index = document.turns.lastIndex(where: { turn in
                guard case let .user(user, _) = turn else { return false }
                return user.submissionID == activeSubmission.id
            }) {
                return continuation(
                    before: index,
                    intent: activeSubmission.text,
                    attachments: activeSubmission.attachments,
                    skillInvocation: activeSubmission.skillInvocation
                )
            }
            let index = document.turns.lastIndex(where: { turn in
                guard case let .agent(agent, _) = turn else { return false }
                return agent.outcome == .running
            }) ?? document.turns.endIndex
            Log.session.warning("Chat.continuation activeFallback id=\(id) submission=\(activeSubmission.id.rawValue) turns=\(index)")
            return continuation(
                before: index,
                intent: activeSubmission.text,
                attachments: activeSubmission.attachments,
                skillInvocation: activeSubmission.skillInvocation
            )
        }
        for index in document.turns.indices.reversed() {
            guard case let .user(turn, _) = document.turns[index] else { continue }
            return continuation(
                before: index,
                intent: turn.intent,
                attachments: turn.attachments,
                skillInvocation: turn.skillInvocation
            )
        }
        return nil
    }

    private func continuation(
        before index: Int,
        intent: String,
        attachments: [Artifact],
        skillInvocation: UserSkillInvocation?
    ) -> ChatContinuation {
        let branchedMeta = ChatMeta(
            id: UUID(),
            createdAt: Date(),
            lastActivity: Date(),
            title: nil,
            isFavorite: false,
            modelID: model.id,
            clientID: client.id,
            region: region,
            reasoningEffort: model.selectedReasoningEffort,
            monoRepositoryHash: monoRepositoryHash,
            attachedServiceDomains: attachedServiceDomains,
            preview: nil
        )
        return ChatContinuation(
            meta: branchedMeta,
            turns: Array(document.turns[..<index]),
            intent: intent,
            attachments: attachments,
            skillInvocation: skillInvocation
        )
    }

    // MARK: - Intent queue

    @discardableResult
    func enqueue(
        _ intent: String,
        attachments: [Artifact] = [],
        skillInvocation: UserSkillInvocation? = nil
    ) -> SubmissionReceipt {
        enqueue(
            intent,
            attachments: attachments,
            skillInvocation: skillInvocation,
            replyStyle: .standard,
            submissionID: SubmissionID()
        )
    }

    func submitAndWait(
        _ intent: String,
        attachments: [Artifact] = [],
        skillInvocation: UserSkillInvocation? = nil,
        replyStyle: ReplyStyle = .standard
    ) async -> ChatSubmissionOutcome {
        let submissionID = SubmissionID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                submissionWaiters[submissionID] = continuation
                enqueue(
                    intent,
                    attachments: attachments,
                    skillInvocation: skillInvocation,
                    replyStyle: replyStyle,
                    submissionID: submissionID
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAwaitedSubmission(submissionID)
            }
        }
    }

    @discardableResult
    private func enqueue(
        _ intent: String,
        attachments: [Artifact],
        skillInvocation: UserSkillInvocation?,
        replyStyle: ReplyStyle,
        submissionID: SubmissionID
    ) -> SubmissionReceipt {
        let posting = !isBusy
        notice = .none
        let latency = TurnLatencyTrace(submissionID: submissionID.rawValue, kind: "user")
        if posting {
            let at = Date()
            document.apply(.appendUser(
                intent: intent,
                attachments: attachments,
                skillInvocation: skillInvocation,
                at: at,
                submissionID: submissionID
            ))
            markActivity(at)
            latency.mark(.posted)
        }
        submissions.append(Submission(
            id: submissionID,
            kind: .user,
            text: intent,
            attachments: attachments,
            skillInvocation: skillInvocation,
            replyStyle: replyStyle,
            latency: latency,
            state: posting ? .posted : .queued
        ))
        if !isBusy { startWorker() }
        let receipt = SubmissionReceipt(id: submissionID.rawValue, disposition: posting ? .posted : .queued)
        Log.session.info("Chat.enqueue id=\(id) submission=\(submissionID.rawValue) disposition=\(receipt.disposition.rawValue) queueDepth=\(submissions.count) attachments=\(attachments.count) replyStyle=\(replyStyle.rawValue)")
        return receipt
    }

    private func cancelAwaitedSubmission(_ submissionID: SubmissionID) {
        guard let continuation = submissionWaiters.removeValue(forKey: submissionID) else { return }
        continuation.resume(returning: .cancelled)
        Log.session.info("Chat.submitAndWait detached id=\(id) submission=\(submissionID.rawValue) busy=\(isBusy)")
    }

    // A turn the host injects after an out-of-band event (e.g. the user signed in
    // via a sign-in card). It carries no visible user bubble; the agent just sees
    // the note plus a fresh turn-state (with the now-updated auth) and decides.
    private enum SystemEventSource {
        case serviceSignIn(String)
        case botControl(String)

        var logLabel: String {
            switch self {
            case .serviceSignIn(let domain): "serviceSignIn:\(domain)"
            case .botControl(let domain): "botControl:\(domain)"
            }
        }
    }

    private func enqueueSystemEvent(_ note: String, source: SystemEventSource) {
        Log.session.info("Chat.enqueueSystemEvent id=\(id) source=\(source.logLabel) queueDepth=\(submissions.count)")
        notice = .none
        let submissionID = SubmissionID()
        let latency = TurnLatencyTrace(submissionID: submissionID.rawValue, kind: source.logLabel)
        latency.mark(.posted)
        submissions.append(Submission(
            id: submissionID,
            kind: .system(resume: document.lastAgentTurnID),
            text: note,
            attachments: [],
            skillInvocation: nil,
            replyStyle: .standard,
            latency: latency,
            state: .posted
        ))
        if !isBusy { startWorker() }
    }

    func signInService(domain: String, resumeAgent: Bool = true) async -> Bool {
        guard let service = attachedService(domain: domain) else {
            Log.session.error("Chat.signInService no service domain=\(domain)")
            return false
        }
        Log.session.info("Chat.signInService start id=\(id) domain=\(domain) auth=\(service.signInState.rawValue) resumeAgent=\(resumeAgent)")
        await service.signIn(using: presentations.serviceSignIn, source: .chatCard)
        let ok = service.signInState.isAuthenticated
        Log.session.info("Chat.signInService done id=\(id) domain=\(domain) ok=\(ok) auth=\(service.signInState.rawValue)")
        if ok, resumeAgent {
            let outcome = service.isMCPService ? "authorized" : "signed in to"
            enqueueSystemEvent(
                "[system] The user just \(outcome) \(domain). Continue the task that needed it.",
                source: .serviceSignIn(domain)
            )
        }
        return ok
    }

    func completeBotControl(domain: String, args: JSONValue, resumeAgent: Bool = true) async -> Bool {
        guard let service = attachedService(domain: domain) else {
            Log.session.error("Chat.completeBotControl no service domain=\(domain)")
            return false
        }
        let ok = await service.completeBotControl(args: args, using: presentations.serviceHandoff)
        Log.session.info("Chat.completeBotControl domain=\(domain) ok=\(ok)")
        if ok, resumeAgent {
            let data = try? JSONEncoder().encode(args)
            let argsText = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            enqueueSystemEvent(
                "[system] The user just completed bot control for \(domain) with args \(argsText). Continue the task. The verification page may already have completed the operation, so inspect its resulting state before retrying a write.",
                source: .botControl(domain)
            )
        }
        return ok
    }

    func completePayment(domain: String, args: JSONValue) async -> JSONValue? {
        guard let service = attachedService(domain: domain) else {
            Log.session.error("Chat.completePayment no service domain=\(domain)")
            return nil
        }
        let result = await service.completePayment(args: args, using: presentations.serviceHandoff)
        Log.session.info("Chat.completePayment domain=\(domain) completed=\(result != nil)")
        return result
    }

    func cancelQueued(_ blockId: UUID) {
        guard let submission = submissions.first(where: { $0.id.rawValue == blockId && $0.needsPosting }) else { return }
        Log.session.info("Chat.cancelQueued id=\(id) block=\(blockId) queueDepth=\(submissions.count)")
        submissions.removeAll { $0.id.rawValue == blockId && $0.needsPosting }
        submission.latency.finish(outcome: "cancelledQueued", client: client.id, model: model.id)
    }

    func cancelAll() {
        let cancelled = drainSubmissions()
        for submission in cancelled {
            submission.latency.finish(outcome: "cancelledQueued", client: client.id, model: model.id)
        }
        let waiters = submissionWaiters.values
        submissionWaiters.removeAll()
        for continuation in waiters { continuation.resume(returning: .cancelled) }
        notice = .none
        agentEventCycle.cancel()
        enqueueAgentMutation { await $0.abort() }
        cancelInteractions()
        let task = runState.task
        let runID = runState.id
        runState.backgroundExecution?.finish(success: true)
        runState = .idle
        task?.cancel()
        Log.session.info("Chat.cancelAll id=\(id) run=\(runID.map { String($0.rawValue.uuidString.prefix(8)) } ?? "idle")")
        resetOutputDelivery()
        stopStreamLink()
    }

    func stopCurrentTurn() {
        Log.session.info("Chat.stopCurrentTurn id=\(id) queueDepth=\(submissions.count)")
        notice = .none
        agentEventCycle.cancel()
        enqueueAgentMutation { await $0.abort() }
        cancelInteractions()
        resetOutputDelivery()
        stopStreamLink()
        setRunPhase(.thinking)
    }

    private func stageCompletionNotification(assistant: AssistantMessage) {
        let preview = assistant.content.compactMap {
            if case .text(let t) = $0 { return t.text }; return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let body = preview.isEmpty ? L10n.string("Your chat finished while you were away.", comment: "Notification body shown when a chat turn completes while the app is backgrounded and there is no preview text.") : String(preview.prefix(140))
        runState.setCompletionNotification(CompletionNotification(title: title, body: body))
    }

    private func deliverCompletionNotification(_ notification: CompletionNotification) {
        let chatId = id.uuidString
        Task {
            do {
                let delivered = try await NotificationProvider.shared.deliverIfAuthorized(
                    identifier: "chat.\(chatId)",
                    title: notification.title,
                    body: notification.body
                )
                if delivered {
                    Log.session.info("Chat.notify posted id=\(chatId) bodyChars=\(notification.body.count)")
                } else {
                    Log.session.info("Chat.notify skipped id=\(chatId) reason=notAuthorized")
                }
            } catch {
                Log.session.error("Chat.notify add failed id=\(chatId) err=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Streaming

    private func startStreamLink() {
        guard isSelected else { return }
        if streamFrameDriver.start() { Log.session.debug("Chat.streamLink start id=\(id)") }
    }

    private func stopStreamLink() {
        if streamFrameDriver.stop() { Log.session.debug("Chat.streamLink stop id=\(id)") }
    }

    private func onStreamFrame(at timestamp: CFTimeInterval) {
        guard let checkpoint = outputDelivery.nextFrame(at: timestamp) else { return }
        apply(checkpoint)
    }

    private func waitForStreamingDelivery() async {
        guard !streamingTurnDelivered else { return }
        await withCheckedContinuation { streamingDeliveryContinuation = $0 }
    }

    private func resetOutputDelivery() {
        outputDelivery.reset()
        streamingTurnDelivered = true
        streamingDeliveryContinuation?.resume()
        streamingDeliveryContinuation = nil
    }

    private func finishAgentTurnFromEvents(error: String?) {
        let at = Date()
        let outcome: TurnOutcome
        if runState.backgroundExecutionExpired {
            outcome = .failed(at: at, message: "Background execution ended.")
        } else if agentEventCycle.isCancelled || runState.task?.isCancelled == true || error == "aborted" {
            outcome = .cancelled(at: at)
        } else if let error {
            outcome = .failed(at: at, message: error)
        } else {
            outcome = .completed(at: at)
        }
        if document.hasOpenGeneration { document.apply(.finishGeneration(outcome)) }
        if document.hasOpenAgentTurn { document.apply(.finishAgentTurn(outcome)) }
    }

    private func waitForAgentEvents() async {
        guard !agentEventCycle.isCompleted else { return }
        await withCheckedContinuation { agentEventCycle.wait($0) }
    }

    private func endStreamingTurn(_ assistant: AssistantMessage) {
        if !isTemporary, assistant.stopReason != .toolUse {
            stageCompletionNotification(assistant: assistant)
        }
        streamingTurnDelivered = false
        outputDelivery.end(assistant)
        if isSelected { startStreamLink() } else { finalizeBufferedTurnIfInactive() }
    }

    private func finalizeBufferedTurnIfInactive() {
        guard let checkpoint = outputDelivery.hiddenCheckpoint() else { return }
        Log.session.debug("Chat.streamLink checkpoint id=\(id) chars=\(checkpoint.text.count)")
        apply(checkpoint)
    }

    private func apply(_ checkpoint: OutputDelivery.Checkpoint) {
        if !checkpoint.text.isEmpty {
            if isSelected { activeLatency?.mark(.firstTextVisible) }
            growAgentText(checkpoint.text)
        }
        if let completion = checkpoint.completion { finalizeTurnEnd(completion) }
    }

    private func finalizeTurnEnd(_ assistant: AssistantMessage) {
        stopStreamLink()
        setRunPhase(assistant.stopReason == .toolUse ? .thinking : .finishing)
        streamingTurnDelivered = true
        streamingDeliveryContinuation?.resume()
        streamingDeliveryContinuation = nil
    }

    // MARK: - Agent loop

    private func startWorker() {
        guard !isBusy else { return }
        let runID = RunID()
        let queueDepth = submissions.count
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishWorker(runID) }
            await agentControlTask?.value
            await agent.waitForIdle()
            while !submissions.isEmpty {
                if Task.isCancelled { break }
                var submission = submissions.removeFirst()
                if submission.needsPosting {
                    let at = Date()
                    document.apply(.appendUser(
                        intent: submission.text,
                        attachments: submission.attachments,
                        skillInvocation: submission.skillInvocation,
                        at: at,
                        submissionID: submission.id
                    ))
                    submission.post()
                    submission.latency.mark(.posted)
                    Log.session.info("Chat.submission posted id=\(id) submission=\(submission.id.rawValue)")
                    markActivity(at)
                }
                submission.consume()
                submission.latency.mark(.consumed)
                Log.session.info("Chat.worker consume id=\(id) submission=\(submission.id.rawValue)")
                activeLatency = submission.latency
                await runOne(submission, runID: runID)
                activeLatency = nil
                runState.backgroundExecution?.advance()
            }
        }
        runState = .running(Run(
            id: runID,
            task: task,
            phase: .thinking,
            activeSubmission: nil,
            backgroundExecutionExpired: false,
            backgroundExecution: nil,
            completionNotification: nil
        ))
        startBackgroundExecution()
        Log.session.info("Chat.worker start id=\(id) run=\(runID.rawValue.uuidString.prefix(8)) queueDepth=\(queueDepth)")
    }

    private func finishWorker(_ runID: RunID) {
        guard runState.id == runID else { return }
        let backgroundExecutionExpired = runState.backgroundExecutionExpired
        let chatFailed = !backgroundExecutionExpired && notice.errorMessage != nil
        let chatSucceeded = !backgroundExecutionExpired && !agentEventCycle.isCancelled && notice.errorMessage == nil
        let hasUnreadResult = chatSucceeded || chatFailed || backgroundExecutionExpired
        let leaseSucceeded = !backgroundExecutionExpired
        if chatFailed { runState.backgroundExecution?.updatePhase(.failed) }
        let completionNotification = chatSucceeded ? runState.completionNotification : nil
        runState.backgroundExecution?.finish(success: leaseSucceeded)
        runState = .idle
        if hasUnreadResult, !isTranscriptVisible {
            hasUnreadResponse = true
            Log.session.info("Chat.unread id=\(id)")
            onPersistableChange?()
        }
        Log.session.info("Chat.worker finish id=\(id) run=\(runID.rawValue.uuidString.prefix(8)) chatFailed=\(chatFailed) chatSucceeded=\(chatSucceeded) leaseSucceeded=\(leaseSucceeded)")
        guard let completionNotification else { return }
        guard UIApplication.shared.applicationState != .active else {
            Log.session.info("Chat.notify skipped id=\(id) reason=active")
            return
        }
        deliverCompletionNotification(completionNotification)
    }

    private func setRunPhase(_ phase: RunPhase) {
        guard interaction == nil else {
            Log.session.warning("Chat.phase ignored id=\(id) phase=\(phase.logLabel) reason=awaitingInteraction")
            return
        }
        replaceRunPhase(phase)
    }

    private func replaceRunPhase(_ phase: RunPhase) {
        guard runState.phase != phase else { return }
        switch runState {
        case .idle:
            break
        case .running(var run):
            run.phase = phase
            runState = .running(run)
        }
    }

    private func startBackgroundExecution() {
        guard executionLease == .userInitiated,
              let runID = runState.id,
              runState.backgroundExecution == nil else { return }
        let execution = ChatBackgroundExecution(chatID: id, runID: runID) { [weak self] in
            self?.expireBackgroundExecution(runID: runID)
        }
        runState.setBackgroundExecution(execution)
        execution.submit()
    }

    private func expireBackgroundExecution(runID: RunID) {
        guard runState.id == runID else { return }
        runState.expireBackgroundExecution()
        notice = .error("Run interrupted: background execution ended.")
        let cancelled = drainSubmissions()
        for submission in cancelled {
            submission.latency.finish(outcome: "backgroundExpired", client: client.id, model: model.id)
        }
        enqueueAgentMutation { await $0.abort() }
        runState.task?.cancel()
        Log.session.warning("Chat.backgroundExpired id=\(id) run=\(runID.rawValue)")
    }

    private func drainSubmissions() -> [Submission] {
        let drained = submissions
        submissions.removeAll()
        return drained
    }

    private func runOne(_ submission: Submission, runID: RunID) async {
        submission.latency.mark(.runStarted)
        Log.session.info("Chat.runOne start id=\(id) client=\(client.id) model=\(model.id)")
        agentHapticPhase = .waitingForDelta
        runState.setActiveSubmission(submission, runID: runID)
        defer { runState.setActiveSubmission(nil, runID: runID) }
        await Soul.shared.waitUntilCurrent()
        await UserMemory.shared.waitUntilCurrent()
        await Skills.shared.waitUntilCurrent()
        await agentControlTask?.value
        let configuration = agentConfiguration(client: client, model: model)
        await agent.configure(
            client: client,
            model: model,
            systemPrompt: configuration.systemPrompt,
            tools: configuration.tools
        )
        submission.latency.mark(.agentConfigured)
        agentSnapshot = await agent.snapshot()
        submission.latency.mark(.manifestsStarted)
        await withTaskGroup(of: Void.self) { group in
            for svc in attachedServices { group.addTask { _ = await svc.loadManifest() } }
        }
        submission.latency.mark(.manifestsReady)
        let attached = attachedServices.map { $0.snapshot(attached: true) }
        let definitions = Dictionary(uniqueKeysWithValues: attachedServices.map { ($0.domain, $0.definition) })
        let fileMountPaths = attached.contains(where: { $0.domain == "ios:files" })
            ? DeviceFolderStore.shared.grants.map { "files/\($0.id)" }
            : []
        let transientContext = Self.turnContext(
            TurnContext(
                attachedServices: attached,
                definitions: definitions,
                fileMountPaths: fileMountPaths,
                artifactPaths: referencedArtifacts.map { "artifacts/\($0.fileName)" },
                storageMode: retention == .persisted ? .persisted : .temporary,
                languageDirective: AppLocale.shared.responseDirective,
                replyStyle: submission.replyStyle
            ),
            toolsAvailable: client.supportsTools(for: model)
        )
        submission.latency.mark(.promptReady)
        let attachedLog = attached.isEmpty ? "none" : attached.map(\.domain).joined(separator: ",")
        Log.session.info("Chat.runOne prompt id=\(id) attached=\(attachedLog) model=\(model.id) intentChars=\(submission.text.count) transientChars=\(transientContext?.count ?? 0) attachments=\(submission.attachments.count)")
        for definition in allDefinitions() {
            let actions = definition.actions
                .map(\.id)
                .joined(separator: ",")
            Log.session.info("Chat.runOne service=\(definition.domain) actions=[\(actions)]")
        }
        let turnID = transcript.last(where: { $0.isUserInitiated })?.id
        agentEventCycle.begin()
        pendingCompactionTokens = nil
        submission.latency.mark(.agentSubmitted)
        await LogContext.$latency.withValue(submission.latency) {
            await agent.prompt(
                submission.text,
                attachments: submission.attachments,
                transientContext: transientContext,
                turnID: turnID
            )
            await agent.waitForIdle()
        }
        await waitForAgentEvents()
        let sealedAt = Date()
        let snapshot = await agent.snapshot()
        agentSnapshot = snapshot
        installContextCheckpoint(messages: snapshot.messages, tokensBefore: pendingCompactionTokens)
        pendingCompactionTokens = nil
        let err = snapshot.errorMessage
        let failureKind = snapshot.failureKind
        markActivity(sealedAt)
        if let err, err != "aborted" {
            Log.session.error("Chat.runOne agent error: \(err)")
            notice = .error(Self.userFacingError(err, kind: failureKind))
        }
        let outcomeName = if Task.isCancelled {
            "cancelled"
        } else if err == "aborted" {
            "aborted"
        } else if err != nil {
            "error"
        } else {
            "completed"
        }
        submission.latency.finish(outcome: outcomeName, client: client.id, model: model.id)
        resolveAwaitedSubmission(
            submission,
            error: err,
            failureKind: failureKind,
            cancelled: Task.isCancelled || err == "aborted"
        )
        Log.session.info("Chat.runOne end id=\(id) outcome=\(outcomeName)")
    }

    private func resolveAwaitedSubmission(
        _ submission: Submission,
        error: String?,
        failureKind: LLMFailureKind?,
        cancelled: Bool
    ) {
        guard let continuation = submissionWaiters.removeValue(forKey: submission.id) else { return }
        let outcome: ChatSubmissionOutcome
        if cancelled {
            outcome = .cancelled
        } else if let error {
            outcome = .failed(Self.userFacingError(error, kind: failureKind))
        } else {
            let response = responseText(for: submission.id)
            outcome = response.isEmpty
                ? .failed("Ox finished without a text response.")
                : .completed(response)
        }
        continuation.resume(returning: outcome)
        Log.session.info("Chat.submitAndWait resolved id=\(id) submission=\(submission.id.rawValue) outcome=\(outcome.logLabel)")
    }

    private func responseText(for submissionID: SubmissionID) -> String {
        guard let userIndex = document.turns.firstIndex(where: { turn in
            guard case let .user(user, _) = turn else { return false }
            return user.submissionID == submissionID
        }), document.turns.indices.contains(userIndex + 1),
              case let .agent(turn, _) = document.turns[userIndex + 1] else { return "" }
        return turn.steps.compactMap { step in
            if case let .text(text) = step.kind { return text }
            return nil
        }
        .joined(separator: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func outcome(for assistant: AssistantMessage, at: Date) -> TurnOutcome {
        if assistant.stopReason == .aborted { return .cancelled(at: at) }
        if let error = assistant.errorMessage { return .failed(at: at, message: error) }
        return .completed(at: at)
    }

    private func enqueueAgentMutation(_ mutation: @escaping @Sendable (Agent) async -> Void) {
        let previous = agentControlTask
        let agent = agent
        agentControlTask = Task { @MainActor [weak self] in
            await previous?.value
            await mutation(agent)
            self?.agentSnapshot = await agent.snapshot()
        }
    }

    private func restoreAgent(messages: [Message]) {
        enqueueAgentMutation { agent in
            await agent.restore(messages: messages)
        }
    }

    private func restoreAgent(from restorationTask: Task<ChatContextRestoration, Never>) {
        let previous = agentControlTask
        let agent = agent
        agentControlTask = Task { @MainActor [weak self] in
            await previous?.value
            let restoration = await restorationTask.value
            guard let self else { return }
            let transcriptMatches = document.turns == restoration.sourceTurns
            if transcriptMatches {
                contextCheckpoint = restoration.checkpoint
            }
            await agent.restore(messages: restoration.messages)
            agentSnapshot = await agent.snapshot()
            guard transcriptMatches else {
                Log.session.warning("Chat.context discarded id=\(id) reason=transcript-changed-during-restore")
                return
            }
            if let boundary = restoration.boundary {
                Log.session.info("Chat.context restored id=\(id) boundary=\(boundary) checkpointMessages=\(restoration.checkpoint?.messages.count ?? 0) tailTurns=\(restoration.sourceTurns.count - boundary - 1)")
            } else if let checkpoint = restoration.checkpoint {
                Log.session.warning("Chat.context recovered id=\(id) reason=\(restoration.recoveryReason ?? "unknown") through=\(checkpoint.throughTurnID.rawValue) messages=\(checkpoint.messages.count)")
            }
            guard restoration.recoveryReason != nil, restoration.checkpoint != nil else { return }
            onPersistableChange?()
        }
    }

    nonisolated private static func resolveContext(
        context: AgentContextCheckpoint?,
        turns: [Turn]
    ) -> ChatContextRestoration {
        if turns.requiresContextCheckpoint,
           let context,
           let boundary = context.boundary(in: turns) {
            return ChatContextRestoration(
                checkpoint: context,
                messages: context.messages + ChatProjection.makeWireMessages(
                    from: Array(turns.dropFirst(boundary + 1))
                ),
                sourceTurns: turns,
                boundary: boundary,
                recoveryReason: nil
            )
        }
        let messages = ChatProjection.makeWireMessages(from: turns)
        return ChatContextRestoration(
            checkpoint: recoveredContext(turns: turns, messages: messages),
            messages: messages,
            sourceTurns: turns,
            boundary: nil,
            recoveryReason: context == nil ? "missing" : "transcript-mismatch"
        )
    }

    nonisolated private static func recoveredContext(turns: [Turn], messages: [Message]) -> AgentContextCheckpoint? {
        guard let compaction = turns.latestContextCompaction,
              let index = turns.lastIndex(where: { turn in
            if case .agent = turn { return true }
            return false
        }) else { return nil }
        let checkpointMessages: [Message]
        if index == turns.index(before: turns.endIndex) {
            checkpointMessages = messages
        } else {
            checkpointMessages = ChatProjection.makeWireMessages(from: Array(turns[...index]))
        }
        return AgentContextCheckpoint(
            messages: checkpointMessages,
            tokensBefore: compaction.tokensBefore,
            turns: turns,
            through: index
        )
    }

    private func installContextCheckpoint(messages: [Message], tokensBefore: Int?) {
        guard let compaction = document.turns.latestContextCompaction else {
            contextCheckpoint = nil
            return
        }
        guard let index = document.turns.lastIndex(where: { turn in
            if case .agent = turn { return true }
            return false
        }) else {
            Log.session.warning("Chat.context not saved id=\(id) reason=no-agent-turn")
            return
        }
        let compactionTokens = tokensBefore ?? contextCheckpoint?.tokensBefore ?? compaction.tokensBefore
        contextCheckpoint = AgentContextCheckpoint(
            messages: messages,
            tokensBefore: compactionTokens,
            turns: document.turns,
            through: index
        )
        Log.session.info("Chat.context checkpoint id=\(id) through=\(document.turns[index].id.rawValue) messages=\(messages.count) compacted=\(tokensBefore != nil) tokensBefore=\(compactionTokens)")
    }

    private func invalidateContextCheckpoint(reason: String) {
        guard contextCheckpoint != nil else { return }
        contextCheckpoint = nil
        Log.session.info("Chat.context invalidated id=\(id) reason=\(reason)")
    }

    // MARK: - Manifest + actions

    func setAttachedServices(_ services: [Service]) {
        let canonical = services.map { serviceManager.service(domain: $0.domain) ?? $0 }
        let normalized = Self.uniqueServices(canonical)
        if normalized.count != services.count {
            Log.session.warning("Chat.setAttachedServices deduplicated id=\(id) supplied=\(services.count) unique=\(normalized.count)")
        }
        let domains = normalized.map(\.domain)
        guard domains != attachedServiceDomains else {
            replaceAttachedServices(normalized)
            return
        }
        attachedServiceDomains = domains
        replaceAttachedServices(normalized)
        onPersistableChange?()
    }

    func attachedService(domain: String) -> Service? {
        attachedServices.first { $0.domain == domain }
    }

    @discardableResult
    func attachService(_ service: Service) -> Bool {
        guard !attachedServices.contains(where: { $0.domain == service.domain }) else { return false }
        setAttachedServices(attachedServices + [service])
        return true
    }

    @discardableResult
    func attachServiceDomains(_ domains: [String]) -> Bool {
        let monoRepositoryReady = serviceManager.monoRepositoryState == .ready
        var known = Set(attachedServiceDomains)
        var added: [String] = []
        var unavailable: [String] = []
        for domain in domains where known.insert(domain).inserted {
            if serviceManager.service(domain: domain) != nil || !monoRepositoryReady {
                added.append(domain)
            } else {
                unavailable.append(domain)
            }
        }
        if !unavailable.isEmpty {
            Log.session.warning("Chat.attachServiceDomains id=\(id) unavailable=\(unavailable.joined(separator: ","))")
        }
        guard !added.isEmpty else {
            resolveAttachedServices()
            return false
        }
        attachedServiceDomains.append(contentsOf: added)
        resolveAttachedServices()
        let resolved = added.filter { serviceManager.service(domain: $0) != nil }
        let deferred = added.filter { serviceManager.service(domain: $0) == nil }
        Log.session.info("Chat.attachServiceDomains id=\(id) resolved=\(resolved.joined(separator: ",")) deferred=\(deferred.joined(separator: ","))")
        onPersistableChange?()
        return true
    }

    private func resolveAttachedServices() {
        let normalizedDomains = Self.uniqueServiceDomains(attachedServiceDomains)
        if normalizedDomains.count != attachedServiceDomains.count {
            Log.session.warning("Chat.resolveAttachedServices deduplicated id=\(id) stored=\(attachedServiceDomains.count) unique=\(normalizedDomains.count)")
            attachedServiceDomains = normalizedDomains
        }
        replaceAttachedServices(attachedServiceDomains.compactMap { serviceManager.service(domain: $0) })
    }

    private static func uniqueServiceDomains(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        return domains.filter { seen.insert($0).inserted }
    }

    private static func uniqueServices(_ services: [Service]) -> [Service] {
        var normalized: [Service] = []
        var indexByDomain: [String: Int] = [:]
        for service in services {
            if let index = indexByDomain[service.domain] {
                normalized[index] = service
            } else {
                indexByDomain[service.domain] = normalized.count
                normalized.append(service)
            }
        }
        return normalized
    }

    private func replaceAttachedServices(_ services: [Service]) {
        assert(Set(services.map(\.domain)).count == services.count)
        assert(services.allSatisfy { serviceManager.service(domain: $0.domain) === $0 })
        let unchanged = services.count == attachedServices.count
            && zip(services, attachedServices).allSatisfy { pair in pair.0 === pair.1 }
        guard !unchanged else { return }
        let added = services.filter { candidate in
            !attachedServices.contains { $0 === candidate }
        }
        let removed = attachedServices.filter { candidate in
            !services.contains { $0 === candidate }
        }
        if removed.contains(where: { $0.domain == "ios:browser" }) {
            serviceManager.browserActionSessions.closeSession(for: id)
        }
        cancelServiceInteractions(domains: Set(removed.map(\.domain)))
        attachedServices = services
        Log.session.info("Chat.setAttachedServices id=\(id) attached=\(services.map(\.domain).joined(separator: ",")) selected=\(isSelected)")
        if servicesAttached {
            serviceManager.setAttachedServices(services, for: id)
            for service in added {
                Task { await service.resolveSignInState(reason: .attach) }
            }
        }
        for svc in services {
            Task { _ = await svc.loadManifest() }
        }
    }

    var monoRepositoryRevision: UInt64 { serviceManager.monoRepositoryRevision }

    // MARK: - Session lifecycle

    func attach() async {
        guard !servicesAttached else { return }
        servicesAttached = true
        serviceManager.setAttachedServices(attachedServices, for: id)
        await withTaskGroup(of: Void.self) { group in
            for svc in attachedServices {
                group.addTask { _ = await svc.loadManifest() }
            }
        }
    }

    func detach() {
        guard servicesAttached else { return }
        servicesAttached = false
        serviceManager.removeAttachedServices(for: id)
    }

    func allDefinitions() -> [ServiceDefinition] { attachedServices.map(\.definition) }

    // MARK: - Helpers

    typealias TurnContext = ChatPromptComposer.TurnContext
    typealias ReplyStyle = ChatPromptComposer.ReplyStyle
    typealias SystemPromptBreakdown = ChatPromptComposer.SystemPromptBreakdown

    static func composeSystemPrompt(
        memory: String,
        userSkills: [Skill] = [],
        toolsAvailable: Bool = true
    ) -> String {
        ChatPromptComposer.composeSystemPrompt(
            memory: memory,
            userSkills: userSkills,
            toolsAvailable: toolsAvailable
        )
    }

    static func systemPromptBreakdown(
        memory: String,
        userSkills: [Skill] = [],
        toolsAvailable: Bool = true
    ) -> SystemPromptBreakdown {
        ChatPromptComposer.systemPromptBreakdown(
            memory: memory,
            userSkills: userSkills,
            toolsAvailable: toolsAvailable
        )
    }

    static func composeTurnState(_ state: TurnContext, toolsAvailable: Bool = true) -> String {
        ChatPromptComposer.composeTurnState(state, toolsAvailable: toolsAvailable)
    }

    static func turnContext(_ state: TurnContext, toolsAvailable: Bool = true) -> String? {
        ChatPromptComposer.turnContext(state, toolsAvailable: toolsAvailable)
    }

    private func agentConfiguration(client: any ProviderClient, model: ProviderModel) -> AgentConfiguration {
        let supportsJavaScript = client.supportsTools(for: model)
        return AgentConfiguration(
            systemPrompt: Self.composeSystemPrompt(
                memory: UserMemory.shared.text,
                userSkills: Skills.shared.all,
                toolsAvailable: supportsJavaScript
            ),
            tools: supportsJavaScript ? [ChatJavaScriptTool(chat: self)] : []
        )
    }


}

extension Chat: PrivateDataHost {
    var privateDataContext: PrivateDataAccessContext {
        PrivateDataAccessContext(
            chatRetention: retention,
            provider: .init(id: client.id, name: client.displayName, location: client.inferenceLocation)
        )
    }

    func privateDataContinuation() -> ChatContinuation? { latestContinuation() }

    func choosePrivateDataOption(prompt: String, options: [String]) async -> String {
        await awaitPrompt(
            prompt: prompt,
            options: options,
            allowsCustomAnswer: false,
            presentation: .application
        )
    }

    func continuePrivateDataTemporarily(_ continuation: ChatContinuation) {
        onPrivateDataTemporaryContinuation?(continuation)
    }
}
