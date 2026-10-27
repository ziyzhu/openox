import Foundation
import WebKit
import Observation

@MainActor
@Observable
final class Conversation: Identifiable {
    private(set) var id: UUID
    let createdAt: Date
    let scheduleID: UUID?
    let javaScriptOutputs = JavaScriptOutputStore()
    @ObservationIgnored private(set) var durableRoute: DurableConversationRoute?
    @ObservationIgnored var preparedConfiguration: AgentConfiguration?
    @ObservationIgnored var durablePreparation: Task<Void, Error>?
    @ObservationIgnored var durableForkSource: (reference: DurableConversationReference, users: Int)?
    var conversationReference: DurableConversationReference? { durableRoute?.reference }

    func installDurableRoute(_ route: DurableConversationRoute?) throws {
        guard durableRoute == nil || !isBusy else { throw RuntimeError.bridge("Conversation worker is still running") }
        if let reference = route?.reference {
            guard reference.profileID == scope.profileID else { throw RuntimeError.bridge("Conversation belongs to another Profile") }
            id = reference.compatibilityID.rawValue
        }
        durableRoute = route
    }
    @ObservationIgnored private var modelPreparationTask: Task<Void, Never>?
    @ObservationIgnored private var modelPreparationIntent = false
    @ObservationIgnored private var memorySnapshot: String?
    @ObservationIgnored private var pendingContextCompactions: [ContextCompaction] = []

    private(set) var client: any ProviderClient
    private(set) var model: ProviderModel
    private(set) var modelSelection: ModelSelection
    private(set) var modelSelectionChange: ModelSelectionChange?
    private(set) var followIntents: [FollowIntent] = []

    func publishFollowIntents(_ intents: [FollowIntent]) {
        followIntents = intents
    }

    var region: LLMRegion { modelSelection.region }
    let presentations: AppPresentations
    let repository: ProfileRepository
    let scope: ProfileScope
    let skillSession = SkillSession()
    let serviceManager: ServiceManager
    let fileMutationCoordinator = FileMutationCoordinator.shared
    private(set) var retention: ConversationRetention

    var isTemporary: Bool { retention == .temporary }
    var canChangeRetention: Bool { transcript.isEmpty && queuedMessages.isEmpty && !isBusy }

    func toggleRetention() -> Bool {
        guard canChangeRetention else {
            Log.session.info("Conversation.retention ignored id=\(id) reason=started")
            return false
        }
        retention = isTemporary ? .persisted : .temporary
        Log.session.info("Conversation.retention changed id=\(id) retention=\(String(describing: retention))")
        return true
    }

    func switchModel(to client: any ProviderClient, model: ProviderModel, selection: ModelSelection) {
        cancelModelSelectionChange()
        self.client = client
        self.model = model
        publishFollowIntents([])
        modelSelection = ModelSelection(
            region: selection.region,
            providerID: client.id,
            modelID: model.id,
            reasoningEffort: model.selectedReasoningEffort
        )
        preparedConfiguration = nil
        scheduleModelPreparation()
        Log.session.info("Conversation.switchModel id=\(id) -> client=\(client.id) model=\(model.id) reasoning=\(model.selectedReasoningEffort ?? "unavailable") region=\(selection.region.rawValue)")
        onPersistableChange?()
    }

    func requestModelSelection(_ selected: ProviderRegistry.SelectedModel) -> String {
        let selection = selected.selection
        if selection == modelSelection {
            cancelModelSelectionChange()
            modelSelectionChange = .applied(selection)
            return "applied"
        }
        if let run = activeRun {
            modelSelectionChange = .pending(selection, run.id)
            Log.session.info("Conversation.modelChange pending id=\(id) provider=\(selection.providerID) model=\(selection.modelID)")
            return "pending"
        }
        switchModel(to: selected.client, model: selected.model, selection: selection)
        modelSelectionChange = .applied(selection)
        return "applied"
    }

    private func cancelModelSelectionChange() {
        guard let selection = modelSelectionChange?.pendingSelection else { return }
        modelSelectionChange = .cancelled(selection)
        Log.session.info("Conversation.modelChange cancelled id=\(id) provider=\(selection.providerID) model=\(selection.modelID)")
    }

    private func settleModelSelectionChange(runID: RunID, succeeded: Bool) {
        guard case let .pending(selection, owner) = modelSelectionChange, owner == runID else { return }
        guard succeeded else { cancelModelSelectionChange(); return }
        do {
            let selected = try ProviderRegistry.shared.resolveSelection(selection)
            modelSelectionChange = .applied(selected.selection)
            switchModel(to: selected.client, model: selected.model, selection: selected.selection)
            Log.session.info("Conversation.modelChange applied id=\(id) provider=\(selection.providerID) model=\(selection.modelID)")
        } catch {
            modelSelectionChange = .failed(selection, error.localizedDescription)
            notice = .error(error.localizedDescription)
            Log.session.error("Conversation.modelChange failed id=\(id) error=\(error.localizedDescription)")
        }
    }

    func setModelPreparationIntent(_ active: Bool) {
        modelPreparationIntent = active
        scheduleModelPreparation()
    }

    private func scheduleModelPreparation() {
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        guard isSelected else { return }
        modelPreparationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self, self.isSelected else { return }
            let client = self.client
            let model = self.model
            let authenticationStarted = ContinuousClock.now
            let authenticationOutcome = await client.prepareAuthentication()
            guard !Task.isCancelled else { return }
            let authenticationMs = TurnLatencyTrace.milliseconds(authenticationStarted.duration(to: .now))
            Log.perf.info("LLM.auth.prepare conversation=\(self.id) client=\(client.id) model=\(model.id) outcome=\(authenticationOutcome.rawValue) durationMs=\(authenticationMs)")
            guard self.modelPreparationIntent else { return }
            let configuration = self.agentConfiguration(client: client, model: model)
            let prompt: RenderedConversationPrompt
            do {
                prompt = try await self.renderPrompt(configuration: configuration)
                try Task.checkCancellation()
            } catch {
                if !Task.isCancelled { Log.agent.warning("LLM.prepare prompt unavailable conversation=\(self.id) error=\(error.localizedDescription)") }
                return
            }
            let systemPrompt = prompt.rendered
            let fingerprint = promptCacheKey(
                model: model,
                systemPrompt: systemPrompt,
                tools: configuration.tools
            )
            let started = Date()
            let outcome = await client.prepare(
                model: model,
                systemPrompt: systemPrompt,
                tools: configuration.tools
            )
            guard !Task.isCancelled else { return }
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            Log.perf.info("LLM.prepare conversation=\(self.id) client=\(client.id) model=\(model.id) outcome=\(outcome.rawValue) ms=\(elapsed) fingerprint=\(fingerprint)")
        }
    }

    @ObservationIgnored private lazy var serviceAttachments = ConversationServiceAttachments(
        conversation: self,
        botControlSource: botControlSource,
        cancelInteractions: { [unowned self] domains in interactions.cancelServiceInteractions(domains: domains) },
        resumeAgent: { [unowned self] event, source in enqueueSystemEvent(event, source: source) }
    )
    var attachedServices: [Service] { serviceAttachments.services }
    @ObservationIgnored private lazy var interactions = ConversationInteractionGate(
        conversation: self,
        feedback: feedback,
        present: { [unowned self] interaction, phase in
            replaceRunPhase(.awaiting(interaction))
            activeRun?.backgroundExecution?.finish(.awaitingInput(phase))
            activeRun?.backgroundExecution = nil
        },
        settle: { [unowned self] in
            replaceRunPhase(.thinking)
            startBackgroundExecution()
        },
        dismiss: { [unowned self] in
            if interaction != nil { replaceRunPhase(.thinking) }
        },
        permissionNeeded: { [unowned self] in activeRun?.backgroundExecution?.updatePhase(.permissionNeeded) },
        answered: { [unowned self] in markActivity() }
    )

    var interaction: Interaction? {
        guard let run = activeRun,
              case .awaiting(let interaction) = run.phase else { return nil }
        return interaction
    }

    var pendingServiceControl: PendingServiceControl? {
        guard case .serviceControl(let control) = interaction else { return nil }
        return control
    }

    private(set) var monoRepositoryHash: String?
    @ObservationIgnored private var serviceSourceVersions: [String: String]?

    private(set) var isSelected = false
    private(set) var isTranscriptVisible = false
    private(set) var hasUnreadResponse = false
    @ObservationIgnored private var browserURLToRestore: URL?
    @ObservationIgnored private var browserRestoreTask: Task<Void, Never>?

    func select() {
        guard !isSelected else { return }
        isSelected = true
        serviceManager.setAttachedServices(attachedServices, for: id)
        for service in attachedServices {
            Task { _ = await service.loadManifest() }
        }
        Log.session.info("Conversation.selection id=\(id) selected=true busy=\(isBusy)")
        stream.setVisible(true)
        scheduleModelPreparation()
        if let browserURLToRestore,
           !isBusy,
           serviceManager.browserActionSessions.existingSession(for: id)?.webPage == nil {
            browserRestoreTask = Task { [weak self] in
                guard let self, isSelected else { return }
                let session = serviceManager.browserActionSessions.session(
                    for: serviceManager.browserService,
                    ownerID: id
                )
                let restored = try? await session.navigate(browserURLToRestore)
                if restored == nil {
                    Log.webView.warning("Conversation.browser restore failed id=\(id) host=\(browserURLToRestore.host ?? "?")")
                }
            }
        }
    }

    func setTranscriptVisible(_ visible: Bool) {
        isTranscriptVisible = visible
        guard visible, hasUnreadResponse else { return }
        hasUnreadResponse = false
        Log.session.info("Conversation.read id=\(id)")
        onPersistableChange?()
    }

    func deselect() {
        guard isSelected else { return }
        isSelected = false
        serviceManager.removeAttachedServices(for: id)
        Log.session.info("Conversation.selection id=\(id) selected=false busy=\(isBusy)")
        setTranscriptVisible(false)
        browserRestoreTask?.cancel()
        browserRestoreTask = nil
        browserURLToRestore = serviceManager.browserActionSessions.existingSession(for: id)?.webPage?.url
            ?? browserURLToRestore
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        stream.setVisible(false)
    }

    func release(cancelling: Bool = true) {
        onPersistableChange = nil
        onPrivateDataTemporaryContinuation = nil
        modelPreparationIntent = false
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        deselect()
        serviceManager.browserActionSessions.closeSession(for: id)
        if cancelling { durablePreparation?.cancel(); cancelAll() }
        if isTemporary { Task { await OxHostProtocol.releaseDurableTemporaryConversation(self) } }
    }

    var customTitle: String?

    var isFavorite = false

    func setFavorite(_ favorite: Bool) {
        guard isFavorite != favorite else { return }
        isFavorite = favorite
        Log.session.info("Conversation.setFavorite id=\(id) favorite=\(favorite)")
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
        return "New conversation"
    }

    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        Log.session.info("Conversation.rename id=\(id) custom=\(customTitle != nil)")
        onPersistableChange?()
    }

    var latestAgentConversationTitle: String? { document.latestAgentRenamedTitle }

    @ObservationIgnored let virtualMachine: VirtualMachine

    func runDebugSnippet(_ source: String) async throws -> VirtualMachineOutput {
        try await virtualMachine.run(source: source, bridge: self)
    }

    private(set) var notice = Notice.none

    var activity: Activity {
        switch activeRun {
        case nil:
            if showsStoppedTurn { return .idle(.stopped) }
            return .idle(hasUnreadResponse ? .unread : .read)
        case .some(let run):
            switch run.phase {
            case .preparing, .thinking:
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
    @ObservationIgnored private let botControlSource = ServiceBotControlSourceStore()
    @ObservationIgnored private let authenticationRecovery = ServiceAuthenticationRecoveryStore()

    var serviceOperations: ServiceOperations {
        ServiceOperations(
            serviceManager: serviceManager,
            conversationOwner: .conversation(id),
            resolveConversationAttachments: { [unowned self] refs in
                try await websiteConversationAttachments(refs)
            },
            resolveService: { [unowned self] domain in
                guard let service = attachedService(domain: domain) else {
                    throw RuntimeError.bridge("Service '\(domain)' isn't attached to this conversation.")
                }
                return service
            },
            resolveAction: { [unowned self] name in try serviceAttachments.target(name, label: "ox.service.invoke") },
            attachedDomains: { [unowned self] in Set(attachedServices.map(\.domain)) },
            approve: { [unowned self] action, defaultPolicy, args, purpose, prompt in
                try await requireApproval(
                    action: action,
                    defaultPolicy: defaultPolicy,
                    args: args,
                    purpose: purpose,
                    prompt: prompt
                )
            },
            presentControl: { [unowned self] control, _ in
                let pending = embedServiceControl(control)
                return await interactions.waitForServiceControl(pending)
            },
            receiveFiles: { [unowned self] in try await importRemoteMCPFiles($0) },
            serviceChanged: { [unowned self] domain in
                let replacement = serviceManager.service(domain: domain)
                setAttachedServices(attachedServices.compactMap { $0.domain == domain ? replacement : $0 })
            },
            botControlRequired: { [unowned self] service, args, page in
                guard isBusy else { return }
                botControlSource.retain(service: service, args: args, page: page)
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
            native: nativeServiceOperations,
            authenticationRecovery: authenticationRecovery
        )
    }

    var nativeServiceOperations: NativeServiceOperations {
        NativeServiceOperations(
            id: id,
            serviceManager: serviceManager,
            presentations: presentations,
            requireActive: { [unowned self] in
                guard isSelected else { throw RuntimeError.bridge("This device service requires the active conversation.") }
            },
            showBrowser: { [unowned self] service, _ in
                embedServiceInspector(ServiceInspectorLink(
                    domain: BrowserFunctionCatalog.publicNamespace,
                    serviceName: service.title
                ))
            },
            attachTransient: { [unowned self] attachment in
                guard document.hasOpenExecution else {
                    throw RuntimeError.bridge("Browser exports require an active agent execution.")
                }
                try appendTransientAttachment(attachment)
            },
            importFile: { [unowned self] attachment, filename in
                try requireProfileMutation(Actions.fsWrite)
                let fileExtension = URL(fileURLWithPath: attachment.displayName).pathExtension
                let suggestedName = URL(fileURLWithPath: filename).pathExtension.isEmpty
                    ? "\(filename).\(fileExtension)"
                    : filename
                let file = try await importAttachment(data: attachment.data, suggestedName: suggestedName)
                embedFile(file)
                Log.session.info("Conversation.importBrowserExport filename=\(file.fileName) bytes=\(attachment.data.count)")
                return file
            },
            choose: { [unowned self] prompt in
                if let purpose = prompt.purpose {
                    return try await chooseUser(body: prompt.body, options: prompt.options, purpose: purpose)?.stringValue
                }
                let answer = await awaitPrompt(
                    prompt: prompt.body, options: prompt.options,
                    presentation: .application
                )
                return answer == Self.abortedAnswer ? nil : answer
            },
            authorizeBrowserSite: { [unowned self] site, purpose in
                try await requireApproval(action: Actions.browserSite(site), defaultPolicy: .ask, purpose: purpose)
            }
        )
    }

    private func invokeIOSService(_ serviceID: String, actionID: String, args: JSONValue, purpose: String?) async throws -> JSONValue? {
        guard let service = attachedService(domain: serviceID) else {
            throw Service.InvokeError.unknown(serviceID)
        }
        return try await nativeServiceOperations.invoke(service: service, actionID: actionID, args: args, purpose: purpose)
    }

    func debugInvokeIOSService(
        _ serviceID: String,
        actionID: String,
        args: JSONValue,
        purpose: String?
    ) async throws -> JSONValue? {
        try await invokeIOSService(serviceID, actionID: actionID, args: args, purpose: purpose)
    }

    private var document = ConversationDocument() {
        didSet {
            transcriptRevision &+= 1
            let transcriptPreview = document.preview
            if self.transcriptPreview != transcriptPreview { self.transcriptPreview = transcriptPreview }
            let hasTranscript = !document.projection.isEmpty
            if self.hasTranscript != hasTranscript { self.hasTranscript = hasTranscript }
        }
    }
    private(set) var transcriptRevision: UInt64 = 0
    private(set) var transcriptPreview: String?
    private(set) var hasTranscript = false
    private var currentExecutionFiles: [FileItem] = []
    var currentExecutionTransientAttachments: [(sequence: Int, attachment: TransientAttachment)] = []
    private var currentExecutionActivatedSkills: [String: ActivatedSkillContext] = [:]
    var currentExecutionFetchCount = 0
    var currentExecutionFetchBytes = 0

    private struct ReferencedFilesCache {
        struct Key: Equatable {
            let references: UUID
            let files: Int
        }

        let key: Key
        let files: [FileItem]
    }

    private(set) var filesRevision = 0
    @ObservationIgnored private var filesRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var referencedFilesCache: ReferencedFilesCache?
    var transcript: [Block] { document.projection }
    var transcriptBlockCount: Int { document.blockCount }
    var referencedFiles: [FileItem] {
        let key = ReferencedFilesCache.Key(references: document.fileReferencesRevision, files: filesRevision)
        if let cache = referencedFilesCache, cache.key == key { return cache.files }
        let files = document.referencedFiles
        referencedFilesCache = ReferencedFilesCache(key: key, files: files)
        return files
    }
    var blocksWithTurnID: [(block: Block, turnID: TurnID)] { document.blocksWithTurnID() }

    func filesChanged() {
        filesRevision &+= 1
        guard !isTemporary else { return }
        filesRefreshTask?.cancel()
        filesRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let listing = try await repository.fileListing(for: state.turns, in: scope)
                guard !Task.isCancelled, let files = listing.files else { return }
                document.refreshFiles(files)
            } catch {
                Log.session.warning("Conversation.files refresh failed id=\(id) error=\(error.localizedDescription)")
            }
        }
    }

    func blocksWithTurnID(in range: Range<Int>) -> (range: Range<Int>, blocks: [(block: Block, turnID: TurnID)]) {
        document.blocksWithTurnID(in: range)
    }

    func pendingPrompt(excluding handled: Set<UUID> = []) -> ConversationPendingPrompt? {
        guard case .prompt(let prompt) = interaction,
              !handled.contains(prompt.id) else { return nil }
        return ConversationPendingPrompt(
            id: prompt.id,
            prompt: prompt.prompt,
            options: prompt.options,
            presentation: prompt.presentation
        )
    }

    func resolvePendingPrompt(_ request: ConversationPendingPrompt, answer: String) {
        guard case .prompt(let prompt) = interaction,
              prompt.id == request.id,
              prompt.presentation == request.presentation else { return }
        resolvePrompt(blockId: request.id, answer: answer)
    }
    private(set) var lastActivityAt: Date?

    @ObservationIgnored weak var conversationManager: ConversationManager?
    @ObservationIgnored var onPersistableChange: (() -> Void)?
    @ObservationIgnored var onPrivateDataTemporaryContinuation: ((ConversationContinuation) -> Void)?

    static let abortedAnswer = "The user stopped before answering."

    private typealias Submission = ConversationSubmissionQueue.Submission

    var queuedMessages: [QueuedMessage] { submissions.queuedMessages }

    func anchor(forSubmissionID submissionID: UUID) -> SubmissionAnchor? {
        if let blockID = document.firstBlockID(forSubmissionID: submissionID) {
            return .turn(blockID: blockID, submissionID: submissionID)
        }
        if submissions.queued(submissionID) != nil {
            return .queued(submissionID)
        }
        return nil
    }

    private enum RunPhase: Equatable {
        case preparing
        case thinking
        case streaming
        case awaiting(Interaction)
        case finishing

        var logLabel: String {
            switch self {
            case .preparing: "preparing"
            case .thinking: "thinking"
            case .streaming: "streaming"
            case .awaiting: "awaiting"
            case .finishing: "finishing"
            }
        }
    }

    private enum SubmissionPresentation {
        case completed
        case running
        case cancelled

        var isCancelled: Bool { self == .cancelled }
    }

    private struct Run {
        let id: RunID
        let task: Task<Void, Never>
        var phase: RunPhase
        var activeSubmission: Submission?
        var backgroundExecutionExpired: Bool
        var backgroundExecution: (any ConversationBackgroundExecution)?
        var completionNotification: CompletionNotification?
    }

    private struct CompletionNotification {
        let title: String
        let body: String
    }

    private var activeRun: Run?
    @ObservationIgnored private lazy var submissions = ConversationSubmissionQueue(
        conversation: self,
        responseText: { [unowned self] submissionID in document.responseText(forSubmissionID: submissionID) }
    )
    var isBusy: Bool { activeRun != nil }

    func waitForRun() async {
        while let run = activeRun { await run.task.value }
    }

    var showsStoppedTurn: Bool {
        guard !isBusy,
              submissions.isEmpty,
              case let .agent(turn, _) = document.turns.last,
              case .cancelled = turn.outcome else { return false }
        return true
    }
    var hasPendingInteraction: Bool { interaction != nil }
    @ObservationIgnored private var finishingStartedAt: Date?
    @ObservationIgnored private var finishingWatchdog: Task<Void, Never>?
    @ObservationIgnored private var activeLatency: TurnLatencyTrace?
    @ObservationIgnored private var submissionPresentation = SubmissionPresentation.completed
    @ObservationIgnored private let executionLease: ExecutionLease

    private let execution: any ConversationExecution
    private let feedback: any ConversationFeedback
    @ObservationIgnored private lazy var stream = ConversationAssistantStream(
        conversation: self,
        execution: execution,
        feedback: feedback,
        showText: { [unowned self] text in
            if isSelected { activeLatency?.mark(.firstTextVisible) }
            growAgentText(text)
        },
        replaceText: { [unowned self] text in
            if isSelected { activeLatency?.mark(.firstTextVisible) }
            document.apply(.replaceGenerationText(text))
        },
        finishTurn: { [unowned self] assistant in
            setRunPhase(assistant.stopReason == .toolUse ? .thinking : .finishing)
        }
    )

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
         selection: ModelSelection,
         repository: ProfileRepository,
         scope: ProfileScope,
         virtualMachine: VirtualMachine,
         presentations: AppPresentations,
         execution: any ConversationExecution,
         feedback: any ConversationFeedback,
         serviceManager: ServiceManager,
         retention: ConversationRetention = .persisted,
         executionLease: ExecutionLease = .userInitiated,
         scheduleID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.scheduleID = scheduleID
        self.client = client
        self.modelSelection = ModelSelection(
            region: selection.region,
            providerID: client.id,
            modelID: model.id,
            reasoningEffort: model.selectedReasoningEffort
        )
        self.repository = repository
        self.scope = scope
        self.virtualMachine = virtualMachine
        self.presentations = presentations
        self.execution = execution
        self.feedback = feedback
        self.serviceManager = serviceManager
        self.retention = retention
        self.executionLease = executionLease
        self.model = model
        self.monoRepositoryHash = serviceManager.monoRepositoryHash
        Log.session.info("Conversation created id=\(id) client=\(client.id) model=\(model.id) reasoning=\(model.selectedReasoningEffort ?? "unavailable") region=\(selection.region.rawValue) server=\(serviceManager.serverURL.absoluteString)")
    }

    func receiveAgentEvent(_ event: AgentEvent) async {
        switch event {
        case .runStarted:
            pendingContextCompactions = []
            if !document.hasOpenAgentTurn { beginAgentTurn() }
        case .generationStarted(let model, _):
            setRunPhase(.thinking)
            stream.reset()
            document.apply(.beginGeneration(model: model, at: Date()))
            for compaction in pendingContextCompactions { document.apply(.appendContextCompaction(compaction)) }
            pendingContextCompactions = []
        case .messageStart(.assistant(let assistant)):
            stream.reset()
            if !document.hasOpenAgentTurn { document.apply(.beginAgentTurn(at: assistant.timestamp)) }
            if !document.hasOpenGeneration { document.apply(.beginGeneration(model: assistant.model, at: assistant.timestamp)) }
        case .messageUpdate(_, let event):
            applyAssistantEvent(event)
        case .reasoning(let text):
            appendReasoning(text)
        case .messageEnd(.assistant(let assistant)):
            document.apply(.setGenerationAssistant(assistant))
            stream.reconcile(assistant)
            if !isTemporary, assistant.stopReason != .toolUse {
                stageCompletionNotification(assistant: assistant)
            }
            stream.end(assistant)
        case .generationFinished(let assistant, _):
            await stream.waitForDelivery()
            document.apply(.finishGeneration(Self.outcome(for: assistant, at: Date())))
            requestPersistence(.generationFinished)
            activeRun?.backgroundExecution?.advance()
        case .runFinished(let result):
            activeLatency?.mark(.agentCompleted)
            activeRun?.backgroundExecution?.updatePhase(.finishing)
            finishAgentTurnFromEvents(error: result.errorMessage)
            requestPersistence(.agentTurnFinished)
            if !submissionPresentation.isCancelled { submissionPresentation = .completed }
        case .compacted(let before, let after, let chars, let tokensBefore):
            let compaction = ContextCompaction(at: Date(), tokensBefore: tokensBefore)
            if document.lastGenerationID == nil { pendingContextCompactions.append(compaction) }
            else { document.apply(.appendContextCompaction(compaction)) }
            Log.session.info("Conversation compacted id=\(id) msgs \(before)->\(after) summaryChars=\(chars) tokensBefore=\(tokensBefore)")
        case .toolExecutionStart:
            activeRun?.backgroundExecution?.updatePhase(.working)
        case .toolExecutionEnd(let toolCall, let result):
            document.apply(.recordToolExchange(toolCall, result))
            activeRun?.backgroundExecution?.advance()
            activeRun?.backgroundExecution?.updatePhase(.thinking)
        case .messageStart(_), .messageEnd(_):
            break
        }
    }

    convenience init(
        meta: ConversationMeta,
        turns: [Turn],
        context: AgentContextCheckpoint? = nil,
        restoredDocument: ConversationDocument? = nil,
        client: any ProviderClient,
        model: ProviderModel,
        selection: ModelSelection,
        repository: ProfileRepository,
        scope: ProfileScope,
        virtualMachine: VirtualMachine,
        presentations: AppPresentations,
        execution: any ConversationExecution,
        feedback: any ConversationFeedback,
        serviceManager: ServiceManager,
        retention: ConversationRetention = .persisted,
        executionLease: ExecutionLease = .userInitiated
    ) {
        self.init(
            id: meta.id,
            createdAt: meta.createdAt,
            client: client,
            model: model,
            selection: selection,
            repository: repository,
            scope: scope,
            virtualMachine: virtualMachine,
            presentations: presentations,
            execution: execution,
            feedback: feedback,
            serviceManager: serviceManager,
            retention: retention,
            executionLease: executionLease,
            scheduleID: meta.scheduleID
        )
        monoRepositoryHash = meta.monoRepositoryHash
        customTitle = meta.title
        isFavorite = meta.isFavorite
        document = restoredDocument ?? ConversationDocument.restoring(turns)
        let recovered = document.turns != turns
        hasUnreadResponse = meta.hasUnreadResponse
        serviceAttachments.restore(meta.attachedServiceDomains)
        lastActivityAt = meta.lastActivity
        Log.session.info("Conversation restored id=\(meta.id) turns=\(turns.count) blocks=\(transcript.count) services=\(attachedServices.count) recovered=\(recovered) context=pending")
    }

    var metadata: ConversationMeta {
        ConversationMeta(
            id: id,
            createdAt: createdAt,
            lastActivity: lastActivityAt,
            title: customTitle,
            isFavorite: isFavorite,
            model: modelSelection,
            monoRepositoryHash: monoRepositoryHash,
            attachedServiceDomains: serviceAttachments.domains,
            preview: transcriptPreview,
            hasUnreadResponse: hasUnreadResponse,
            scheduleID: scheduleID,
            lastMessageAt: document.lastMessageAt
        )
    }

    var state: ConversationState {
        ConversationState(meta: metadata, turns: document.turns, context: nil)
    }

    func exportTranscript() async throws -> Data {
        try await repository.export(state)
    }

    @discardableResult
    func syncToMonoRepository() async -> [String] {
        serviceAttachments.resolve()
        let manager = serviceManager
        guard let currentHash = manager.monoRepositoryHash else { return [] }
        let currentVersions = manager.serviceSourceVersions.filter { serviceAttachments.domains.contains($0.key) }
        let previousVersions = serviceSourceVersions
        serviceSourceVersions = currentVersions
        if currentHash != monoRepositoryHash {
            monoRepositoryHash = currentHash
            onPersistableChange?()
        }
        guard let previousVersions else { return [] }
        let updated = attachedServices.filter { service in
            previousVersions[service.domain] != nil && previousVersions[service.domain] != currentVersions[service.domain]
        }
        for service in updated { _ = await service.loadManifest() }
        if !updated.isEmpty {
            Log.session.info("Conversation.syncToMonoRepository id=\(id) updated=\(updated.map(\.domain).joined(separator: ",")) invalidated=false")
        }
        return updated.map(\.title)
    }

    private func markActivity(_ date: Date = Date(), persist: Bool = true) {
        lastActivityAt = date
        if persist { onPersistableChange?() }
    }

    private enum PersistenceCheckpoint: String {
        case generationFinished
        case agentTurnFinished
    }

    private func requestPersistence(_ checkpoint: PersistenceCheckpoint) {
        Log.session.debug("Conversation.persistence checkpoint id=\(id) checkpoint=\(checkpoint.rawValue) generationOpen=\(document.hasOpenGeneration) turnOpen=\(document.hasOpenAgentTurn)")
        onPersistableChange?()
    }

    private func beginAgentTurn() {
        setRunPhase(.thinking)
        activeRun?.backgroundExecution?.updatePhase(.thinking)
        switch activeRun?.activeSubmission?.kind {
        case let .system(.some(target)):
            document.apply(.resumeAgentTurn(id: target))
        case .user, .system, nil:
            document.apply(.beginAgentTurn(at: Date()))
        }
    }

    private func growAgentText(_ delta: String) {
        setRunPhase(.streaming)
        activeRun?.backgroundExecution?.updatePhase(.responding)
        document.apply(.appendText(delta))
        activeRun?.backgroundExecution?.advance()
    }

    func beginExecution(source: String) {
        stream.flush()
        currentExecutionFiles = []
        currentExecutionTransientAttachments = []
        currentExecutionActivatedSkills = [:]
        currentExecutionFetchCount = 0
        currentExecutionFetchBytes = 0
        activeRun?.backgroundExecution?.updatePhase(.working)
        document.apply(.beginExecution(source: source))
    }

    func executionAttachments() -> (files: [FileItem], transient: [TransientAttachment]) {
        (
            currentExecutionFiles,
            currentExecutionTransientAttachments.sorted { $0.sequence < $1.sequence }.map(\.attachment)
        )
    }

    func executionInvocations() -> [Invocation] {
        document.runningExecution?.effects.compactMap {
            if case let .invocation(invocation) = $0 { return invocation }
            return nil
        } ?? []
    }

    func executionOmittedInvocations() -> Int {
        document.runningExecution?.invocationTrace?.omittedCalls ?? 0
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
        Log.session.info("Conversation.activateSkill name=\(name) chars=\(content.count)")
    }

    func finishExecution(output: String, isError: Bool) {
        document.apply(.finishExecution(output: output, isError: isError))
        currentExecutionTransientAttachments = []
        currentExecutionActivatedSkills = [:]
        currentExecutionFetchBytes = 0
        activeRun?.backgroundExecution?.advance()
        activeRun?.backgroundExecution?.updatePhase(.thinking)
    }

    @discardableResult
    func embedServiceControl(_ control: ServiceControl) -> PendingServiceControl {
        let standalone = ensureExecutionContext()
        document.apply(.embedServiceControl(control))
        let source = document.projection.last.flatMap { block -> PendingServiceControl.Source? in
            guard case .agentContent(let items) = block.kind, let itemIndex = items.indices.last else { return nil }
            return PendingServiceControl.Source(blockID: block.id, itemIndex: itemIndex)
        }
        let pending = PendingServiceControl(
            id: UUID(),
            control: control,
            source: source,
            accessPreflight: attachedService(domain: control.domain)?.access.signInPreflight
        )
        if standalone { finishStandaloneExecution() }
        Log.session.info("Conversation.embedServiceControl id=\(pending.id.uuidString) domain=\(control.domain)")
        return pending
    }

    func resolveServiceControl(id controlID: UUID, result: JSONValue?) {
        interactions.resolveServiceControl(id: controlID, result: result)
    }

    func notifyPendingInteraction() {
        interactions.notifyPending()
    }

    func embedFile(_ file: FileItem) {
        let standalone = ensureExecutionContext()
        appendExecutionFile(file)
        document.apply(.embedFile(file))
        NotificationCenter.default.post(name: .fileChanged, object: file.fileURL)
        if standalone { finishStandaloneExecution() }
        Log.session.info("Conversation.embedFile filename=\(file.fileName)")
    }

    private func embedServiceInspector(_ link: ServiceInspectorLink) {
        let standalone = ensureExecutionContext()
        document.apply(.embedServiceInspector(link))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Conversation.embedServiceInspector domain=\(link.domain)")
    }

    func embedSkill(_ skill: Skill) {
        let standalone = ensureExecutionContext()
        document.apply(.embedSkill(skill))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Conversation.embedSkill name=\(skill.name)")
    }

    private func attachMedia(_ file: FileItem) {
        let standalone = ensureExecutionContext()
        appendExecutionFile(file)
        document.apply(.attachMedia(file))
        if standalone { finishStandaloneExecution() }
        Log.session.info("Conversation.attachMedia filename=\(file.fileName)")
    }

    func renameFileReferences(from oldName: String, to newName: String, directory: URL) {
        document.renameFileReferences(from: oldName, to: newName, directory: directory)
    }

    private func appendExecutionFile(_ file: FileItem) {
        guard !currentExecutionFiles.contains(where: {
            $0.fileName.caseInsensitiveCompare(file.fileName) == .orderedSame
        }) else { return }
        currentExecutionFiles.append(file)
    }

    @discardableResult
    func ensureExecutionContext() -> Bool {
        guard !document.hasOpenExecution else { return false }
        Log.session.info("Conversation.ensureExecutionContext effect outside execution; opening a standalone turn")
        if !document.hasOpenAgentTurn {
            if case let .agent(_, id) = document.turns.last {
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
        botControlSource.release()
        let outcome: TurnOutcome = isError
            ? .failed(at: Date(), message: output)
            : .completed(at: Date())
        if document.hasOpenGeneration { document.apply(.finishGeneration(outcome)) }
        if document.hasOpenAgentTurn { document.apply(.finishAgentTurn(outcome)) }
        requestPersistence(.agentTurnFinished)
    }

    func clearNotice() {
        notice = .none
    }

    func appendReportedProgress(_ message: String) throws {
        guard document.hasOpenExecution else {
            throw RuntimeError.bridge("ox.user.progress: no JavaScript execution is active")
        }
        document.apply(.appendProgress(message))
        activeRun?.backgroundExecution?.advance()
    }

    @discardableResult
    func awaitPrompt(
        prompt: String,
        options: [String],
        kind: ConversationPromptKind = .choice,
        allowsCustomAnswer: Bool = false,
        presentation: ConversationPromptPresentation = .conversation,
        secretEntry: SecretEntryRequest? = nil
    ) async -> String {
        await interactions.awaitPrompt(
            prompt: prompt,
            options: options,
            kind: kind,
            allowsCustomAnswer: allowsCustomAnswer,
            presentation: presentation,
            secretEntry: secretEntry
        )
    }

    func resolvePrompt(blockId: UUID, answer: String) {
        interactions.resolvePrompt(blockId: blockId, answer: answer)
    }

    @discardableResult
    func appendInvocation(name: String, purpose: String, args: JSONValue) -> UUID {
        ensureExecutionContext()
        let invocation = Invocation(name: name, purpose: purpose, args: args)
        document.apply(.recordInvocation(invocation))
        activeRun?.backgroundExecution?.updateStep(InvocationPreview.text(purpose).value)
        activeLatency?.recordCallStarted(id: invocation.id.uuidString, name: name, kind: .function)
        Log.session.info("Conversation.invocation appended id=\(invocation.id) name=\(name)")
        return invocation.id
    }

    func appendReasoning(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeRun?.backgroundExecution?.updatePhase(.thinking)
        document.apply(.appendReasoning(trimmed))
        if let paragraph = Reasoning.paragraphs(trimmed).last {
            activeRun?.backgroundExecution?.updateStep(paragraph)
        }
        activeRun?.backgroundExecution?.advance()
    }

    private func applyAssistantEvent(_ event: AssistantEvent) {
        switch event {
        case .textDelta(let index, let delta, _):
            guard !delta.isEmpty else { return }
            stream.registerDelta()
            activeRun?.backgroundExecution?.advance()
            activeRun?.backgroundExecution?.updatePhase(.responding)
            stream.appendDelta(delta, block: index)
        case .thinkingDelta(_, let delta, _):
            guard !delta.isEmpty else { return }
            stream.registerDelta()
            activeRun?.backgroundExecution?.advance()
        case .toolCallDelta:
            stream.registerDelta()
            activeRun?.backgroundExecution?.advance()
            stream.flush()
            setRunPhase(.thinking)
        case .start(let partial):
            if !partial.content.isEmpty {
                stream.registerDelta()
                activeRun?.backgroundExecution?.advance()
            }
            if partial.content.contains(where: { if case .text(let text) = $0 { return !text.text.isEmpty }; return false }) {
                activeRun?.backgroundExecution?.updatePhase(.responding)
            }
            stream.reconcile(partial)
        case .textEnd, .thinkingEnd, .toolCallEnd, .done, .failed:
            break
        }
    }

    func resolveInvocation(invocationID: UUID, outcome: Invocation.Outcome) {
        let failed: Bool = if case .failed = outcome { true } else { false }
        let resultBytes: Int? = if case .succeeded(let value) = outcome {
            try? JSONEncoder().encode(value ?? .null).count
        } else { nil }
        activeLatency?.recordCallCompleted(id: invocationID.uuidString, failed: failed, resultBytes: resultBytes)
        document.apply(.resolveInvocation(id: invocationID, outcome: outcome))
    }

    func tracked<T>(_ action: String, _ args: JSONValue, purpose: String, _ body: () async throws -> T) async throws -> T {
        let standalone = ensureExecutionContext()
        let invocationID = appendInvocation(name: action, purpose: purpose, args: args)
        do {
            try await requireApproval(
                action: action,
                defaultPolicy: Actions.defaultPolicy(for: action),
                args: args.toAny(),
                purpose: purpose
            )
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

    private static func outcomeValue(_ value: Any?) -> JSONValue? {
        if let value = value as? JSONValue { return value == .null ? nil : value }
        guard let value, !(value is NSNull) else { return nil }
        return .from(value)
    }

    static func attachApproveKey(_ domain: String) -> String { "ox.service.attach:\(domain)" }

    func gateServiceAttach(_ service: Service) async throws {
        try await interactions.gateServiceAttach(service)
    }

    func requireApproval(
        action: String,
        defaultPolicy: ActionPolicy,
        args: Any? = nil,
        purpose: String? = nil,
        prompt: String? = nil
    ) async throws {
        try await requireWritableFileAction(action, args: args)
        try await interactions.requireApproval(action: action, defaultPolicy: defaultPolicy, args: args, purpose: purpose, prompt: prompt)
    }

    func requireProfileMutation(_ action: String) throws {
        guard retention == .persisted else {
            Log.session.info("Conversation.temporary blocked action=\(action)")
            throw OxFunctionError(code: "profile_required", message: "\(action): Temporary conversations can't save changes.", recovery: "Ask the user to continue in a Profile stored on this device to keep this result.")
        }
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
        guard let target = document.turnIndex(containingBlock: blockId),
              let cut = document.lastUserTurn(through: target) else {
            Log.session.warning("Conversation.rerun no cut for block=\(blockId)")
            return nil
        }
        let text = replacingText ?? cut.turn.intent
        Log.session.info("Conversation.rerun id=\(id) at=\(blockId) cutEntry=\(cut.index) edited=\(replacingText != nil)")
        cancelAll()
        let snapshot = continuation(
            before: cut.index,
            intent: cut.turn.intent,
            attachments: cut.turn.attachments,
            skillInvocation: cut.turn.skillInvocation
        )
        guard let replacement = conversationManager?.replaceForRerun(from: self, snapshot: snapshot) else { return nil }
        return replacement.enqueue(
            text,
            attachments: cut.turn.attachments,
            skillInvocation: replacingText == nil ? cut.turn.skillInvocation : nil
        )
    }

    func branchSnapshot(at blockId: UUID) -> ConversationContinuation? {
        guard let target = document.turnIndex(containingBlock: blockId) else { return nil }
        return continuation(
            before: target + 1,
            intent: "",
            attachments: [],
            skillInvocation: nil
        )
    }

    func latestContinuation() -> ConversationContinuation? {
        if let activeSubmission = activeRun?.activeSubmission, case .user = activeSubmission.kind {
            if let index = document.lastUserTurnIndex(forSubmissionID: activeSubmission.id) {
                return continuation(
                    before: index,
                    intent: activeSubmission.text,
                    attachments: activeSubmission.attachments,
                    skillInvocation: activeSubmission.skillInvocation
                )
            }
            let index = document.runningAgentTurnIndex ?? document.turns.endIndex
            Log.session.warning("Conversation.continuation activeFallback id=\(id) submission=\(activeSubmission.id.rawValue) turns=\(index)")
            return continuation(
                before: index,
                intent: activeSubmission.text,
                attachments: activeSubmission.attachments,
                skillInvocation: activeSubmission.skillInvocation
            )
        }
        guard let last = document.lastUserTurn(through: document.turns.count - 1) else { return nil }
        return continuation(
            before: last.index,
            intent: last.turn.intent,
            attachments: last.turn.attachments,
            skillInvocation: last.turn.skillInvocation
        )
    }

    private func continuation(
        before index: Int,
        intent: String,
        attachments: [FileItem],
        skillInvocation: UserSkillInvocation?
    ) -> ConversationContinuation {
        let branchedMeta = ConversationMeta(
            id: UUID(),
            createdAt: Date(),
            lastActivity: Date(),
            title: nil,
            isFavorite: false,
            model: modelSelection,
            monoRepositoryHash: monoRepositoryHash,
            attachedServiceDomains: serviceAttachments.domains,
            preview: nil
        )
        return ConversationContinuation(
            meta: branchedMeta,
            turns: Array(document.turns[..<index]),
            intent: intent,
            attachments: attachments,
            skillInvocation: skillInvocation
        )
    }

    @discardableResult
    func enqueue(
        _ intent: String,
        attachments: [FileItem] = [],
        skillInvocation: UserSkillInvocation? = nil
    ) -> SubmissionReceipt {
        enqueue(
            intent,
            attachments: attachments,
            skillInvocation: skillInvocation,
            submissionID: SubmissionID()
        )
    }

    func submitAndWait(
        _ intent: String,
        attachments: [FileItem] = [],
        skillInvocation: UserSkillInvocation? = nil
    ) async -> ConversationSubmissionOutcome {
        let submissionID = SubmissionID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                submissions.wait(for: submissionID, continuation)
                enqueue(
                    intent,
                    attachments: attachments,
                    skillInvocation: skillInvocation,
                    submissionID: submissionID
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.submissions.detach(submissionID)
            }
        }
    }

    func submitUntilAttention(
        _ intent: String,
        skillInvocation: UserSkillInvocation? = nil
    ) async -> ConversationSubmissionOutcome {
        await withTaskGroup(of: ConversationSubmissionOutcome.self) { group in
            group.addTask { @MainActor in
                await self.submitAndWait(intent, skillInvocation: skillInvocation)
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    if self.hasPendingInteraction { return .needsAttention }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return .cancelled
            }
            let outcome = await group.next() ?? .cancelled
            group.cancelAll()
            if outcome == .needsAttention {
                Log.session.info("Conversation.submitUntilAttention paused id=\(id) reason=pendingInteraction")
            }
            return outcome
        }
    }

    @discardableResult
    private func enqueue(
        _ intent: String,
        attachments: [FileItem],
        skillInvocation: UserSkillInvocation?,
        submissionID: SubmissionID
    ) -> SubmissionReceipt {
        publishFollowIntents([])
        let posting = !isBusy
        notice = .none
        let latency = TurnLatencyTrace(submissionID: submissionID.rawValue, conversationID: id, kind: "user")
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
            latency: latency,
            state: posting ? .posted : .queued
        ))
        if !isBusy { startWorker() }
        let receipt = SubmissionReceipt(id: submissionID.rawValue, disposition: posting ? .posted : .queued)
        Log.session.info("Conversation.enqueue id=\(id) submission=\(submissionID.rawValue) disposition=\(receipt.disposition.rawValue) queueDepth=\(submissions.count) attachments=\(attachments.count)")
        return receipt
    }

    private func enqueueSystemEvent(_ event: JSONValue, source: ConversationServiceAttachments.SystemEvent) {
        let note: String
        do {
            note = try ModelPromptRenderer.shared.render(.runtimeEvent, input: event)
        } catch {
            Log.session.error("Conversation.enqueueSystemEvent rendering failed id=\(id) source=\(source.logLabel) error=\(error.localizedDescription)")
            return
        }
        Log.session.info("Conversation.enqueueSystemEvent id=\(id) source=\(source.logLabel) queueDepth=\(submissions.count)")
        notice = .none
        let submissionID = SubmissionID()
        let latency = TurnLatencyTrace(submissionID: submissionID.rawValue, conversationID: id, kind: source.logLabel)
        latency.mark(.posted)
        submissions.append(Submission(
            id: submissionID,
            kind: .system(resume: document.lastAgentTurnID),
            text: note,
            attachments: [],
            skillInvocation: nil,
            latency: latency,
            state: .posted
        ))
        if !isBusy { startWorker() }
    }

    func signInService(
        domain: String,
        resumeAgent: Bool = true,
        using presenter: (any ServiceAuthPresenting)? = nil
    ) async -> JSONValue? {
        await serviceAttachments.signIn(domain: domain, resumeAgent: resumeAgent, using: presenter)
    }

    func completeBotControl(
        domain: String,
        args: JSONValue,
        resumeAgent: Bool = true,
        using presenter: (any ServiceHandoffPresenting)? = nil
    ) async -> Bool {
        await serviceAttachments.completeBotControl(domain: domain, args: args, resumeAgent: resumeAgent, using: presenter)
    }

    func completePayment(domain: String, args: JSONValue, using presenter: (any ServiceHandoffPresenting)? = nil) async -> JSONValue? {
        await serviceAttachments.completePayment(domain: domain, args: args, using: presenter)
    }

    func cancelQueued(_ blockId: UUID) {
        guard let submission = submissions.queued(blockId) else { return }
        Log.session.info("Conversation.cancelQueued id=\(id) block=\(blockId) queueDepth=\(submissions.count)")
        submissions.remove(submission.id)
        if activeRun?.activeSubmission?.id == submission.id {
            activeRun?.task.cancel()
        }
        submission.latency.finish(outcome: "cancelledQueued", client: client.id, model: model.id)
    }

    func cancelAll() {
        cancelModelSelectionChange()
        botControlSource.release()
        for submission in submissions.drain() {
            submission.latency.finish(outcome: "cancelledQueued", client: client.id, model: model.id)
        }
        submissions.cancelWaiters()
        notice = .none
        submissionPresentation = .cancelled
        interactions.cancelAll()
        let runID = activeRun?.id
        activeRun?.task.cancel()
        Log.session.info("Conversation.cancelAll id=\(id) run=\(runID.map { String($0.rawValue.uuidString.prefix(8)) } ?? "idle")")
        stream.cancel()
    }

    func stopCurrentTurn() {
        authenticationRecovery.clear()
        guard isBusy else {
            Log.session.info("Conversation.stopCurrentTurn ignored id=\(id) reason=idle")
            return
        }
        botControlSource.release()
        Log.session.info("Conversation.stopCurrentTurn id=\(id) queueDepth=\(submissions.count)")
        cancelModelSelectionChange()
        notice = .none
        submissionPresentation = .cancelled
        activeRun?.task.cancel()
        interactions.cancelAll()
        stream.cancel()
        if activeRun?.phase != .preparing { setRunPhase(.thinking) }
    }

    private func stageCompletionNotification(assistant: AssistantMessage) {
        let preview = assistant.content.compactMap {
            if case .text(let t) = $0 { return t.text }; return nil
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let body = preview.isEmpty ? L10n.string("Your conversation finished while you were away.", comment: "Notification body shown when a conversation turn completes while the app is backgrounded and there is no preview text.") : String(preview.prefix(140))
        activeRun?.completionNotification = CompletionNotification(title: title, body: body)
    }

    private func finishAgentTurnFromEvents(error: String?) {
        botControlSource.release()
        let at = Date()
        let outcome: TurnOutcome
        if submissionPresentation.isCancelled || activeRun?.task.isCancelled == true || error == "aborted" {
            outcome = .cancelled(at: at)
        } else if let error {
            outcome = .failed(at: at, message: error)
        } else {
            outcome = .completed(at: at)
        }
        if document.hasOpenGeneration { document.apply(.finishGeneration(outcome)) }
        if document.hasOpenAgentTurn { document.apply(.finishAgentTurn(outcome)) }
    }

    func presentDurableToolAssistant(_ assistant: AssistantMessage) {
        if !document.hasOpenAgentTurn {
            if case .agent(_, let id) = document.turns.last { document.apply(.resumeAgentTurn(id: id)) }
            else { document.apply(.beginAgentTurn(at: assistant.timestamp)) }
        }
        if !document.hasOpenGeneration {
            if case .agent(let turn, _) = document.turns.last, let generation = turn.generations.last,
               generation.assistantMessage == assistant {
                document.apply(.resumeGeneration(id: generation.id))
            } else { document.apply(.beginGeneration(model: assistant.model, at: assistant.timestamp)) }
        }
        document.apply(.setGenerationAssistant(assistant))
        document.apply(.replaceGenerationText(stream.present(assistant)))
    }

    func prepareDurableRecovery() async throws {
        try await durablePreparation?.value
        if activeRun?.phase != .preparing { await waitForRun() }
        try await freezeMemorySnapshot()
        await Skills.shared.waitUntilCurrent()
        _ = try await prepareDurableConversation(configuration: agentConfiguration(client: client, model: model))
    }

    func resumeDurableSubmission(_ submissionID: Int, requestID: String?) {
        guard !isBusy else { return }
        let runID = RunID()
        submissionPresentation = .running
        if case .agent(_, let id) = document.turns.last { document.apply(.resumeAgentTurn(id: id)) }
        else { document.apply(.beginAgentTurn(at: Date())) }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishWorker(runID) }
            do {
                let result = try await resumeSubmission(submissionID, requestID: requestID)
                if let error = result.errorMessage, error != "aborted" { notice = .error(error) }
                document.apply(.sealAllTurns)
                markActivity(Date())
                onPersistableChange?()
            } catch {
                submissionPresentation = .completed
                notice = .error(error.localizedDescription)
                Log.session.error("Conversation.recovery failed conversation=\(id) submission=\(submissionID) error=\(error.localizedDescription)")
            }
        }
        activeRun = Run(id: runID, task: task, phase: .thinking, activeSubmission: nil, backgroundExecutionExpired: false,
            backgroundExecution: nil, completionNotification: nil)
        startBackgroundExecution()
    }

    private func startWorker() {
        guard !isBusy, let submission = submissions.next else { return }
        let runID = RunID()
        let queueDepth = submissions.count
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishWorker(runID) }
            await waitUntilProfilePrepared(runID: runID)
            if Task.isCancelled {
                submissions.remove(submission.id)
                submission.latency.finish(outcome: "cancelled", client: client.id, model: model.id)
                return
            }
            guard var submission = submissions.take(submission.id) else { return }
            setRunPhase(.thinking)
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
                Log.session.info("Conversation.submission posted id=\(id) submission=\(submission.id.rawValue)")
                markActivity(at)
            }
            submission.consume()
            submission.latency.mark(.consumed)
            Log.session.info("Conversation.worker consume id=\(id) submission=\(submission.id.rawValue)")
            activeLatency = submission.latency
            await runOne(submission, runID: runID)
            activeLatency = nil
        }
        activeRun = Run(
            id: runID,
            task: task,
            phase: .preparing,
            activeSubmission: submission,
            backgroundExecutionExpired: false,
            backgroundExecution: nil,
            completionNotification: nil
        )
        startBackgroundExecution()
        Log.session.info("Conversation.worker start id=\(id) run=\(runID.rawValue.uuidString.prefix(8)) queueDepth=\(queueDepth)")
    }

    private func waitUntilProfilePrepared(runID: RunID) async {
        guard let conversationManager else { return }
        let startedAt = Date()
        await conversationManager.profilePreparation()
        let waitedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Log.session.info("Conversation.worker profileReady id=\(id) run=\(runID.rawValue.uuidString.prefix(8)) waitedMs=\(waitedMs)")
    }

    private func finishWorker(_ runID: RunID) {
        guard let run = activeRun, run.id == runID else { return }
        authenticationRecovery.clear()
        defer { if !submissions.isEmpty { startWorker() } }
        let backgroundExecutionExpired = run.backgroundExecutionExpired
        let conversationFailed = notice.errorMessage != nil
        let conversationStopped = submissionPresentation.isCancelled || run.task.isCancelled
        let conversationSucceeded = !conversationStopped && !conversationFailed
        let hasUnreadResult = conversationSucceeded || conversationFailed
        let backgroundOutcome: ConversationBackgroundOutcome = if backgroundExecutionExpired {
            .expired
        } else if conversationStopped {
            .stopped
        } else if conversationFailed {
            .failed
        } else {
            .completed
        }
        settleModelSelectionChange(runID: runID, succeeded: conversationSucceeded && !run.task.isCancelled)
        let completionNotification = conversationSucceeded ? run.completionNotification : nil
        run.backgroundExecution?.finish(backgroundOutcome)
        interactions.clearAttentionNotification()
        finishFinishingDiagnostics(next: "idle")
        activeRun = nil
        if hasUnreadResult, !isTranscriptVisible {
            hasUnreadResponse = true
            Log.session.info("Conversation.unread id=\(id)")
            onPersistableChange?()
        }
        Log.session.info("Conversation.worker finish id=\(id) run=\(runID.rawValue.uuidString.prefix(8)) conversationFailed=\(conversationFailed) conversationSucceeded=\(conversationSucceeded) conversationStopped=\(conversationStopped) backgroundOutcome=\(backgroundOutcome.logLabel)")
        guard let completionNotification else { return }
        feedback.notifyCompletion(id: id, title: completionNotification.title, body: completionNotification.body)
    }

    private func setRunPhase(_ phase: RunPhase) {
        guard interaction == nil else {
            Log.session.warning("Conversation.phase ignored id=\(id) phase=\(phase.logLabel) reason=awaitingInteraction")
            return
        }
        replaceRunPhase(phase)
    }

    private func replaceRunPhase(_ phase: RunPhase) {
        guard activeRun?.phase != phase else { return }
        Log.session.debug("Conversation.phase id=\(id) from=\(activeRun?.phase.logLabel ?? "idle") to=\(phase.logLabel)")
        if activeRun?.phase == .finishing {
            finishFinishingDiagnostics(next: phase.logLabel)
        }
        guard activeRun != nil else { return }
        activeRun?.phase = phase
        if phase == .finishing { beginFinishingDiagnostics() }
    }

    private func beginFinishingDiagnostics() {
        let startedAt = Date()
        finishingStartedAt = startedAt
        finishingWatchdog?.cancel()
        Log.session.debug("Conversation.finishing begin id=\(id)")
        finishingWatchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  self.activeRun?.phase == .finishing,
                  self.finishingStartedAt == startedAt else { return }
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Log.session.warning("Conversation.finishing slow id=\(self.id) durationMs=\(durationMs)")
        }
    }

    private func finishFinishingDiagnostics(next: String) {
        guard let startedAt = finishingStartedAt else { return }
        finishingStartedAt = nil
        finishingWatchdog?.cancel()
        finishingWatchdog = nil
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Log.session.debug("Conversation.finishing end id=\(id) next=\(next) durationMs=\(durationMs)")
    }

    private func startBackgroundExecution() {
        guard executionLease == .userInitiated,
              let runID = activeRun?.id,
              activeRun?.backgroundExecution == nil else { return }
        let execution = self.execution.backgroundExecution(conversationID: id, runID: runID) { [weak self] in
            self?.expireBackgroundExecution(runID: runID)
        }
        activeRun?.backgroundExecution = execution
        activeRun?.backgroundExecutionExpired = false
        execution.submit()
    }

    private func expireBackgroundExecution(runID: RunID) {
        guard activeRun?.id == runID else { return }
        activeRun?.backgroundExecutionExpired = true
        Log.session.warning("Conversation.backgroundLeaseExpired id=\(id) run=\(runID.rawValue)")
    }

    private func runOne(_ submission: Submission, runID: RunID) async {
        submissionPresentation = .running
        submission.latency.mark(.runStarted)
        Log.session.info("Conversation.runOne start id=\(id) client=\(client.id) model=\(model.id)")
        stream.armHaptic()
        if activeRun?.id == runID { activeRun?.activeSubmission = submission }
        var submissionResult: ConversationRunResult?
        defer {
            settleModelSelectionChange(runID: runID,
                succeeded: submissionResult?.outcome == .completed && !Task.isCancelled)
            if activeRun?.id == runID { activeRun?.activeSubmission = nil }
        }
        do {
            try Task.checkCancellation()
            try await freezeMemorySnapshot()
        } catch {
            let cancelled = error is CancellationError || submissionPresentation.isCancelled
            submissionPresentation = cancelled ? .cancelled : .completed
            let message = cancelled ? "aborted" : error.localizedDescription
            Log.session.error("Conversation Profile documents unavailable id=\(id) error=\(message)")
            if !cancelled { notice = .error(message) }
            submission.latency.finish(outcome: cancelled ? "cancelled" : "rejected", client: client.id, model: model.id)
            submissions.resolve(submission, error: message, failureKind: nil, cancelled: cancelled)
            return
        }
        await Skills.shared.waitUntilCurrent()
        skillSession.snapshots = [:]
        if let invocation = submission.skillInvocation { skillSession.snapshots[invocation.skill.name] = invocation.skill }
        let configuration = agentConfiguration(client: client, model: model)
        submission.latency.mark(.agentConfigured)
        submission.latency.mark(.manifestsStarted)
        await withTaskGroup(of: Void.self) { group in
            for svc in attachedServices { group.addTask { _ = await svc.loadManifest() } }
        }
        submission.latency.mark(.manifestsReady)
        let attached = attachedServices.map { $0.snapshot(attached: true) }
        let fileMountPaths = DeviceFolderStore.shared.grants(for: scope.profileID).map { "files/\($0.id)" }
        var turnSkills: [Skill] = []
        var skillConflicts: [String] = []
        do {
            let catalog = try await skillsMount.catalog()
            turnSkills = skillsMount.entries(in: catalog).map(\.skill)
            skillConflicts = catalog.conflicts.filter { $0.selectedSourceID == nil }.map(\.name)
        } catch {
            Log.session.warning("Conversation.runOne skills unavailable id=\(id) fallback=empty error=\(error.localizedDescription)")
        }
        let turnState = ConversationPromptState.turn(
            skills: turnSkills,
            skillConflicts: skillConflicts,
            attachedServices: attached,
            fileMountPaths: fileMountPaths,
            filePaths: referencedFiles.compactMap(\.virtualPath),
            isTemporary: retention == .temporary,
            responseLanguage: AppLocale.shared.responseLanguage,
            hostID: Device.hostID,
            profileID: scope.profileID?.uuidString ?? "temporary:\(scope.generation.uuidString)"
        )
        submission.latency.mark(.promptReady)
        let attachedLog = attached.isEmpty ? "none" : attached.map(\.domain).joined(separator: ",")
        Log.session.info("Conversation.runOne prompt id=\(id) attached=\(attachedLog) model=\(model.id) intentChars=\(submission.text.count) turnStateChars=\(turnState.jsonString().count) attachments=\(submission.attachments.count)")
        for definition in attachedServices.map(\.definition) {
            let actions = definition.actions
                .map(\.id)
                .joined(separator: ",")
            Log.session.info("Conversation.runOne service=\(definition.domain) actions=[\(actions)]")
        }
        let turnID = transcript.last(where: { $0.isUserInitiated })?.id
        submission.latency.bindTurn(turnID)
        submission.latency.mark(.agentSubmitted)
        let result: ConversationRunResult
        do {
            try await durablePreparation?.value
            try Task.checkCancellation()
            if submissionPresentation.isCancelled {
                result = ConversationRunResult(outcome: .aborted)
                await receiveAgentEvent(.runFinished(result))
            } else {
                result = try await LogContext.$turnID.withValue(turnID) {
                    try await LogContext.$latency.withValue(submission.latency) {
                        try await submit(ConversationInput(
                            text: submission.text,
                            attachments: submission.attachments,
                            turnState: turnState,
                            turnID: turnID
                        ), configuration: configuration)
                    }
                }
            }
        } catch {
            let cancelled = error is CancellationError || submissionPresentation.isCancelled
            submissionPresentation = cancelled ? .cancelled : .completed
            let message = cancelled ? "aborted" : error.localizedDescription
            Log.session.error("Conversation.runOne rejected id=\(id) error=\(message)")
            if !cancelled { notice = .error(message) }
            submission.latency.finish(outcome: cancelled ? "cancelled" : "rejected", client: client.id, model: model.id)
            submissions.resolve(submission, error: message, failureKind: nil, cancelled: cancelled)
            return
        }
        submissionResult = result
        let sealedAt = Date()
        let err = result.errorMessage
        let failureKind = result.failureKind
        markActivity(sealedAt)
        if let err, err != "aborted" {
            Log.session.error("Conversation.runOne agent error: \(err)")
            notice = .error(Self.userFacingError(err, kind: failureKind))
        }
        let outcomeName = if err == "aborted" {
            "aborted"
        } else if Task.isCancelled {
            "cancelled"
        } else if err != nil {
            "error"
        } else {
            "completed"
        }
        submission.latency.finish(outcome: outcomeName, client: client.id, model: model.id)
        submissions.resolve(
            submission,
            error: err,
            failureKind: failureKind,
            cancelled: Task.isCancelled || err == "aborted"
        )
        Log.session.info("Conversation.runOne end id=\(id) outcome=\(outcomeName)")
    }

    private static func outcome(for assistant: AssistantMessage, at: Date) -> TurnOutcome {
        if assistant.stopReason == .aborted { return .cancelled(at: at) }
        if let error = assistant.errorMessage { return .failed(at: at, message: error) }
        return .completed(at: at)
    }

    func setAttachedServices(_ services: [Service]) {
        serviceAttachments.set(services)
    }

    func attachedService(domain: String) -> Service? {
        serviceAttachments.service(domain: domain)
    }

    @discardableResult
    func attachService(_ service: Service) -> Bool {
        serviceAttachments.attach(service)
    }

    @discardableResult
    func attachServiceDomains(_ domains: [String]) -> Bool {
        serviceAttachments.attach(domains: domains)
    }

    var monoRepositoryRevision: UInt64 { serviceManager.monoRepositoryRevision }

    var serviceBootstrapRevision: String {
        "\(id.uuidString):\(monoRepositoryRevision):\(attachedServices.map(\.domain).joined(separator: ","))"
    }

    var systemPromptMemory: String {
        memorySnapshot ?? UserMemory.shared.text
    }

    private func freezeMemorySnapshot() async throws {
        guard StorageRoot.currentScope == scope else { throw RuntimeError.bridge("Conversation Profile is no longer active") }
        UserMemory.shared.reload()
        try await UserMemory.shared.waitUntilCurrent()
        guard StorageRoot.currentScope == scope else { throw RuntimeError.bridge("Conversation Profile changed while loading documents") }
        guard memorySnapshot == nil else { return }
        let memory = UserMemory.shared.text
        memorySnapshot = memory
        Log.session.info("Conversation.memorySnapshot id=\(id) chars=\(memory.count)")
    }

    func agentConfiguration(client: any ProviderClient, model: ProviderModel) -> AgentConfiguration {
        let serviceManager = serviceManager
        let conversationID = id
        return AgentConfiguration(
            client: client,
            model: model,
            promptState: ConversationPromptState.system(memory: systemPromptMemory, hostID: Device.hostID, profileID: scope.profileID?.uuidString ?? "temporary:\(scope.generation.uuidString)"),
            tools: [ConversationTool(conversation: self)],
            streamOptions: StreamOptions(sessionID: conversationID.uuidString),
            transformContext: { request in
                let messages = await ConversationURLServiceContext.transform(
                    request.messages,
                    serviceManager: serviceManager,
                    conversationID: conversationID
                )
                return await ModelAdapterPipeline.transform(
                    messages: messages,
                    model: request.model,
                    loadsFilesLazily: client.supportsTools(for: request.model),
                    wireProtocol: client.wireProtocol(for: request.model)
                )
            }
        )
    }
}

extension Conversation: PrivateDataHost {
    var privateDataContext: PrivateDataAccessContext {
        PrivateDataAccessContext(
            conversationRetention: retention,
            provider: .init(id: client.id, name: client.displayName, location: client.inferenceLocation)
        )
    }

    func privateDataContinuation() -> ConversationContinuation? { latestContinuation() }

    func choosePrivateDataOption(prompt: String, options: [String]) async -> String {
        await awaitPrompt(
            prompt: prompt,
            options: options,
            allowsCustomAnswer: false,
            presentation: .application
        )
    }

    func continuePrivateDataTemporarily(_ continuation: ConversationContinuation) {
        onPrivateDataTemporaryContinuation?(continuation)
    }
}
