import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ChatManager {
    private struct Record {
        enum HydrationState {
            case unloaded(ChatMeta)
            case loading(ChatMeta, HydrationGeneration)
            case loaded(Chat)

            var meta: ChatMeta {
                switch self {
                case .unloaded(let meta), .loading(let meta, _): meta
                case .loaded(let chat): chat.metadata
                }
            }

            var chat: Chat? {
                if case .loaded(let chat) = self { chat } else { nil }
            }

            func replacingMeta(_ meta: ChatMeta) -> Self {
                switch self {
                case .unloaded:
                    .unloaded(meta)
                case .loading(_, let generation):
                    .loading(meta, generation)
                case .loaded:
                    self
                }
            }
        }

        enum PersistenceState {
            case clean
            case debouncing(ChatSaveRequest, Task<Void, Never>)
            case saving(ChatSaveRequest, ChatSaveRequest?, Task<ChatSaveReceipt, Never>)
            case deleting
            case deleted

            var isDirty: Bool {
                switch self {
                case .debouncing, .saving: true
                case .clean, .deleting, .deleted: false
                }
            }

            var preservesLocalRecordDuringReload: Bool {
                switch self {
                case .clean: false
                case .debouncing, .saving, .deleting, .deleted: true
                }
            }
        }

        var hydration: HydrationState
        var persistence: PersistenceState
        var accessOrdinal: UInt64
        var metadataRevision: UInt64

        init(meta: ChatMeta, accessOrdinal: UInt64 = 0) {
            hydration = .unloaded(meta)
            persistence = .clean
            self.accessOrdinal = accessOrdinal
            metadataRevision = 0
        }

        init(chat: Chat, accessOrdinal: UInt64) {
            hydration = .loaded(chat)
            persistence = .clean
            self.accessOrdinal = accessOrdinal
            metadataRevision = 0
        }
    }

    private enum Selection {
        case empty
        case deferred(ChatID, previous: Chat?)
        case opening(ChatID, HydrationGeneration, previous: Chat?)
        case active(Chat)
    }

    private var records: [ChatID: Record] = [:]
    private var selection: Selection = .empty
    @ObservationIgnored private var hydrationOrdinal: UInt64 = 0
    @ObservationIgnored private var hydrationGeneration: UInt64 = 0
    @ObservationIgnored private let repository: ProfileRepository
    @ObservationIgnored private let storage: StorageRoot
    @ObservationIgnored private let providerRegistry: ProviderRegistry
    @ObservationIgnored private let serviceManager: ServiceManager
    @ObservationIgnored private var repositoryScope: ProfileScope
    @ObservationIgnored private var virtualMachine: VirtualMachine
    @ObservationIgnored private let presentations: AppPresentations
    #if targetEnvironment(simulator)
    @ObservationIgnored private let debugRepositorySaveGate: ProfileRepositorySaveGate
    #endif
    private static let saveDebounceNs: UInt64 = 1_000_000_000
    private static let maxHydratedChats = 5

    init(
        repository: ProfileRepository,
        storage: StorageRoot,
        providerRegistry: ProviderRegistry,
        serviceManager: ServiceManager,
        presentations: AppPresentations
    ) {
        repositoryScope = storage.scope
        virtualMachine = VirtualMachine()
        self.repository = repository
        self.storage = storage
        self.providerRegistry = providerRegistry
        self.serviceManager = serviceManager
        #if targetEnvironment(simulator)
        debugRepositorySaveGate = repository.debugSaveGate
        #endif
        self.presentations = presentations
    }

    var summaries: [ChatMeta] {
        records.values.compactMap { record in
            switch record.persistence {
            case .deleting, .deleted:
                return nil
            case .clean, .debouncing, .saving:
                break
            }
            if record.hydration.chat?.isTemporary == true { return nil }
            if record.hydration.chat?.transcript.isEmpty == true { return nil }
            return record.hydration.meta
        }
    }

    var orderedSummaries: [ChatMeta] {
        summaries.sorted { $0.activityDate > $1.activityDate }
    }

    var activities: [UUID: Chat.Activity] {
        Dictionary(uniqueKeysWithValues: records.map { id, record in
            let activity = record.hydration.chat?.activity
                ?? .idle(record.hydration.meta.hasUnreadResponse ? .unread : .read)
            return (id.rawValue, activity)
        })
    }

    var currentId: UUID? {
        switch selection {
        case .empty: nil
        case .deferred(_, let previous), .opening(_, _, let previous): previous?.id
        case .active(let chat): chat.id
        }
    }

    var openingId: UUID? {
        if case .opening(let id, _, _) = selection { id.rawValue } else { nil }
    }

    var current: Chat? {
        switch selection {
        case .empty: nil
        case .deferred(_, let previous), .opening(_, _, let previous): previous
        case .active(let chat): chat
        }
    }

    func contains(_ rawID: UUID) -> Bool {
        guard let record = records[ChatID(rawID)] else { return false }
        switch record.persistence {
        case .deleting, .deleted: return false
        case .clean, .debouncing, .saving: return true
        }
    }

    func loadSummaries() {
        Task { [weak self] in await self?.loadSummariesNow() }
    }

    func loadSummariesNow() async {
        ensureRepositoryScope()
        let scope = repositoryScope
        let scopedRepository = repository
        let revisions = records.mapValues(\.metadataRevision)
        let locallyAuthoritative = Set(records.compactMap { id, record in
            record.persistence.preservesLocalRecordDuringReload ? id : nil
        })
        let summaries = await scopedRepository.chatSummaries(in: scope)
        guard repositoryScope == scope else { return }
        var loaded = Dictionary(uniqueKeysWithValues: summaries.map { meta in
            (ChatID(meta.id), Record(meta: meta))
        })
        var preserved = 0
        for (id, record) in records {
            let changedWhileLoading = revisions[id] != record.metadataRevision
            if record.hydration.chat != nil
                || record.persistence.preservesLocalRecordDuringReload
                || locallyAuthoritative.contains(id)
                || changedWhileLoading {
                loaded[id] = record
                preserved += 1
            }
        }
        records = loaded
        Log.session.info("ChatManager.loadSummaries count=\(summaries.count) preserved=\(preserved) generation=\(scope.generation)")
        if case .deferred(let id, _) = selection { open(id.rawValue) }
    }

    @discardableResult
    func startNewChat() -> Chat {
        ensureRepositoryScope()
        if let current, current.transcript.isEmpty, !current.isTemporary { return current }
        let chat = makeChat()
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        setCurrent(chat)
        return chat
    }

    func importPackage(_ payload: ChatPackagePayload) async throws -> Chat {
        ensureRepositoryScope()
        let scope = repositoryScope
        let state = try await repository.importChatPackage(payload, in: scope)
        guard repositoryScope == scope else { throw ChatPackageError.invalidArchive }
        let chat = restoredChat(
            from: ChatLoadResult(state: state, needsPersistence: false),
            in: scope
        )
        hydrationOrdinal &+= 1
        records[state.chatID] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        setCurrent(chat)
        Log.session.info("ChatManager.import chat=\(chat.id) turns=\(state.turns.count)")
        return chat
    }

    func askAndWait(_ prompt: String, attachments: [Artifact] = []) async -> ChatSubmissionOutcome {
        await startNewChat().submitAndWait(prompt, attachments: attachments)
    }

    func runScheduledSkill(
        _ schedule: ScheduledSkill,
        executionLease: Chat.ExecutionLease
    ) async -> (ChatSubmissionOutcome, UUID?) {
        ensureRepositoryScope()
        guard repositoryScope.profileID == schedule.profileID else {
            return (.failed("The scheduled skill's Profile is not active."), nil)
        }
        let chat = makeChat(
            executionLease: executionLease,
            scheduledSkillID: schedule.id
        )
        chat.rename(to: "Scheduled /\(schedule.skill.displayName)")
        chat.attachServiceDomains(schedule.skill.services)
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        let invocation = UserSkillInvocation(skill: schedule.skill, argument: schedule.argument)
        let outcome = await scheduledOutcome(chat: chat, invocation: invocation)
        _ = await flushAllNow()
        Log.session.info("ChatManager.scheduled finished schedule=\(schedule.id) chat=\(chat.id) outcome=\(outcome.logLabel)")
        return (outcome, chat.id)
    }

    func continueAndWait(
        _ rawID: UUID,
        prompt: String,
        replyStyle: Chat.ReplyStyle = .standard
    ) async -> ChatSubmissionOutcome {
        ensureRepositoryScope()
        let id = ChatID(rawID)
        if let chat = records[id]?.hydration.chat {
            touch(id)
            setCurrent(chat)
            return await chat.submitAndWait(prompt, replyStyle: replyStyle)
        }
        guard let record = records[id] else {
            return .failed("That Ox chat is no longer available.")
        }
        switch record.persistence {
        case .deleting, .deleted:
            return .failed("That Ox chat is no longer available.")
        case .clean, .debouncing, .saving:
            break
        }
        let scopedRepository = repository
        let storageScope = repositoryScope
        guard let loaded = await scopedRepository.loadChat(id, in: storageScope),
              repositoryScope == storageScope else {
            return .failed("That Ox chat could not be opened.")
        }
        if let chat = records[id]?.hydration.chat {
            touch(id)
            setCurrent(chat)
            return await chat.submitAndWait(prompt, replyStyle: replyStyle)
        }
        guard var currentRecord = records[id] else {
            return .failed("That Ox chat is no longer available.")
        }
        switch currentRecord.persistence {
        case .deleting, .deleted:
            return .failed("That Ox chat is no longer available.")
        case .clean, .debouncing, .saving:
            break
        }
        let chat = restoredChat(from: loaded, in: storageScope)
        hydrationOrdinal &+= 1
        currentRecord.hydration = .loaded(chat)
        currentRecord.accessOrdinal = hydrationOrdinal
        records[id] = currentRecord
        if loaded.needsPersistence || chat.state != loaded.state { persist(chat) }
        setCurrent(chat)
        return await chat.submitAndWait(prompt, replyStyle: replyStyle)
    }

    func latestCompletedResponse() async -> String? {
        ensureRepositoryScope()
        let scope = repositoryScope
        for meta in orderedSummaries {
            guard repositoryScope == scope else { return nil }
            let id = ChatID(meta.id)
            if let response = records[id]?.hydration.chat?.state.turns.latestCompletedResponse {
                return response
            }
            if let loaded = await repository.loadChat(id, in: scope),
               let response = loaded.state.turns.latestCompletedResponse {
                return response
            }
        }
        return nil
    }

    func stopActiveResponses() -> Int {
        let active = records.values.compactMap(\.hydration.chat).filter(\.isBusy)
        for chat in active { chat.cancelAll() }
        Log.session.info("ChatManager.stopActiveResponses count=\(active.count)")
        return active.count
    }

    func toggleTemporaryChat() {
        guard let chat = current, chat.toggleRetention() else { return }
        attachPersistence(chat)
        Log.session.info("ChatManager.retention chat=\(chat.id) temporary=\(chat.isTemporary)")
    }

    private func startTemporaryChat(continuing continuation: ChatContinuation) {
        let client = providerRegistry.client(forSnapshot: continuation.meta.clientID)
        let model = providerRegistry.model(
            forSnapshot: continuation.meta.modelID,
            reasoningEffort: continuation.meta.reasoningEffort,
            client: client
        )
        let chat = Chat(
            meta: continuation.meta,
            turns: continuation.turns,
            client: client,
            model: model,
            repository: repository,
            scope: repositoryScope,
            virtualMachine: virtualMachine,
            presentations: presentations,
            serviceManager: serviceManager,
            retention: .temporary
        )
        attachPersistence(chat)
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        setCurrent(chat)
        chat.enqueue(
            continuation.intent,
            attachments: continuation.attachments,
            skillInvocation: continuation.skillInvocation
        )
        Log.session.info("ChatManager.temporary started chat=\(chat.id) turns=\(continuation.turns.count)")
    }

    private func discardTemporary(_ id: ChatID) {
        guard let chat = records[id]?.hydration.chat, chat.isTemporary else { return }
        chat.release()
        records[id] = nil
        if currentId == id.rawValue { selection = .empty }
        Log.session.info("ChatManager.temporary discarded chat=\(id)")
    }

    func open(_ rawID: UUID) {
        let id = ChatID(rawID)
        if let chat = records[id]?.hydration.chat {
            touch(id)
            setCurrent(chat)
            return
        }
        guard var record = records[id] else {
            selection = .deferred(id, previous: current)
            Log.session.info("ChatManager.open deferred id=\(id)")
            return
        }
        hydrationGeneration &+= 1
        let generation = HydrationGeneration(rawValue: hydrationGeneration)
        record.hydration = .loading(record.hydration.meta, generation)
        records[id] = record
        selection = .opening(id, generation, previous: current)
        let scopedRepository = repository
        let storageScope = repositoryScope
        Log.session.info("ChatManager.open hydrating id=\(id) generation=\(generation.rawValue)")
        Task { [weak self] in
            let loaded = await scopedRepository.loadChat(id, in: storageScope)
            guard let self,
                  self.repositoryScope == storageScope,
                  var currentRecord = self.records[id],
                  case .loading(_, let currentGeneration) = currentRecord.hydration,
                  currentGeneration == generation,
                  case .opening(let openingID, let openingGeneration, _) = self.selection,
                  openingID == id,
                  openingGeneration == generation else { return }
            guard let loaded else {
                Log.session.error("ChatManager.open not found id=\(id)")
                currentRecord.hydration = .unloaded(currentRecord.hydration.meta)
                self.records[id] = currentRecord
                self.selection = self.current.map(Selection.active) ?? .empty
                return
            }
            let restored = currentRecord.persistence.isDirty
                ? loaded.replacingMeta(currentRecord.hydration.meta)
                : loaded
            let chat = self.restoredChat(from: restored, in: storageScope)
            self.hydrationOrdinal &+= 1
            currentRecord.hydration = .loaded(chat)
            currentRecord.accessOrdinal = self.hydrationOrdinal
            self.records[id] = currentRecord
            if loaded.needsPersistence || chat.state != loaded.state { self.persist(chat) }
            self.setCurrent(chat)
        }
    }

    @discardableResult
    func branch(from chat: Chat, atBlock blockID: UUID) -> Chat? {
        guard let result = chat.branchSnapshot(at: blockID) else {
            Log.session.warning("ChatManager.branch failed block=\(blockID)")
            return nil
        }
        let client = providerRegistry.client(forSnapshot: result.meta.clientID)
        let model = providerRegistry.model(
            forSnapshot: result.meta.modelID,
            reasoningEffort: result.meta.reasoningEffort,
            client: client
        )
        let branched = Chat(
            meta: result.meta,
            turns: result.turns,
            client: client,
            model: model,
            repository: repository,
            scope: repositoryScope,
            virtualMachine: virtualMachine,
            presentations: presentations,
            serviceManager: serviceManager
        )
        attachPersistence(branched)
        hydrationOrdinal &+= 1
        records[ChatID(branched.id)] = Record(chat: branched, accessOrdinal: hydrationOrdinal)
        if branched.state.turns != result.turns { persist(branched) }
        setCurrent(branched)
        branched.enqueue(
            result.intent,
            attachments: result.attachments,
            skillInvocation: result.skillInvocation
        )
        return branched
    }

    func rename(_ rawID: UUID, to title: String) {
        let id = ChatID(rawID)
        guard var record = records[id] else { return }
        if let chat = record.hydration.chat {
            record.metadataRevision &+= 1
            records[id] = record
            chat.rename(to: title)
            return
        }
        var meta = record.hydration.meta
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meta.title = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        record.hydration = record.hydration.replacingMeta(meta)
        record.metadataRevision &+= 1
        records[id] = record
        persist(meta)
    }

    func renameArtifact(_ artifact: Artifact, to newFilename: String) async throws -> Artifact {
        ensureRepositoryScope()
        let scope = repositoryScope
        let renamed = try await repository.renameArtifact(named: artifact.fileName, to: newFilename, in: scope)
        guard repositoryScope == scope else { return renamed }
        let directory = renamed.fileURL.deletingLastPathComponent()
        for chat in records.values.compactMap({ $0.hydration.chat }) {
            chat.renameArtifactReferences(from: artifact.fileName, to: renamed.fileName, directory: directory)
        }
        Log.session.info("ChatManager.renameArtifact from=\(artifact.fileName) to=\(renamed.fileName)")
        return renamed
    }

    func deleteArtifact(_ artifact: Artifact) async throws {
        ensureRepositoryScope()
        let scope = repositoryScope
        _ = try await repository.deleteArtifact(named: artifact.fileName, in: scope)
        Log.session.info("ChatManager.deleteArtifact file=\(artifact.fileName)")
    }

    func toggleFavorite(_ rawID: UUID) {
        let id = ChatID(rawID)
        guard var record = records[id] else { return }
        if let chat = record.hydration.chat {
            record.metadataRevision &+= 1
            records[id] = record
            chat.setFavorite(!chat.isFavorite)
            return
        }
        var meta = record.hydration.meta
        meta.isFavorite.toggle()
        record.hydration = record.hydration.replacingMeta(meta)
        record.metadataRevision &+= 1
        records[id] = record
        persist(meta)
        Log.session.info("ChatManager.toggleFavorite id=\(id) favorite=\(meta.isFavorite) hydration=summary")
    }

    func delete(_ rawID: UUID) {
        let id = ChatID(rawID)
        guard var record = records[id] else { return }
        let wasCurrent = currentId == rawID
        if record.hydration.chat?.isTemporary == true {
            discardTemporary(id)
            if wasCurrent { startNewChat() }
            return
        }
        let inFlight: Task<ChatSaveReceipt, Never>?
        switch record.persistence {
        case .debouncing(_, let task):
            task.cancel()
            inFlight = nil
        case .saving(_, _, let task):
            inFlight = task
        case .clean, .deleting, .deleted:
            inFlight = nil
        }
        record.persistence = .deleting
        record.hydration.chat?.release()
        records[id] = record
        let scopedRepository = repository
        let storageScope = repositoryScope
        Task { [weak self] in
            _ = await inFlight?.value
            await scopedRepository.deleteChat(id, in: storageScope)
            guard let self, self.repositoryScope == storageScope else { return }
            if var deleting = self.records[id] {
                deleting.persistence = .deleted
                self.records[id] = deleting
            }
            self.records[id] = nil
        }
        if wasCurrent {
            selection = .empty
            startNewChat()
        }
    }

    func flushAll() {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ChatManager.flushAll", expirationHandler: nil)
        Task { [weak self] in
            guard let self else { return }
            _ = await self.flushAllNow()
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            Log.session.info("ChatManager.flushAll remaining=\(self.records.values.filter { $0.persistence.isDirty }.count)")
        }
    }

    func flushAllNow() async -> Bool {
        flushDebounced()
        while true {
            let tasks = records.values.compactMap { record -> Task<ChatSaveReceipt, Never>? in
                if case .saving(_, _, let task) = record.persistence { task } else { nil }
            }
            guard !tasks.isEmpty else { break }
            for task in tasks { _ = await task.value }
            await Task.yield()
        }
        return !records.values.contains { $0.persistence.isDirty }
    }

    func reset() {
        for record in records.values {
            switch record.persistence {
            case .debouncing(_, let task): task.cancel()
            case .saving(_, _, let task): task.cancel()
            case .clean, .deleting, .deleted: break
            }
            record.hydration.chat?.release()
        }
        records.removeAll()
        selection = .empty
        ensureRepositoryScope(force: true)
        Log.session.info("ChatManager.reset generation=\(repositoryScope.generation)")
    }

    func debugSession(matching needle: String) -> Chat? {
        let lower = needle.lowercased()
        return records.values.compactMap { $0.hydration.chat }.first {
            $0.id.uuidString.lowercased().hasPrefix(lower)
        }
    }

    #if targetEnvironment(simulator)
    func debugControlRepositorySaveGate(_ action: String) -> Bool? {
        switch action {
        case "hold":
            debugRepositorySaveGate.hold()
            return false
        case "release":
            debugRepositorySaveGate.release()
            return false
        case "status":
            return debugRepositorySaveGate.isEntered
        default:
            return nil
        }
    }

    #endif

    private func makeChat(
        retention: ChatRetention = .persisted,
        executionLease: Chat.ExecutionLease = .userInitiated,
        scheduledSkillID: UUID? = nil
    ) -> Chat {
        let client = providerRegistry.newSessionClient
        let chat = Chat(
            client: client,
            model: providerRegistry.selected(for: client.id),
            repository: repository,
            scope: repositoryScope,
            virtualMachine: virtualMachine,
            presentations: presentations,
            serviceManager: serviceManager,
            retention: retention,
            executionLease: executionLease,
            scheduledSkillID: scheduledSkillID
        )
        attachPersistence(chat)
        Log.session.info("ChatManager created chat=\(chat.id) retention=\(String(describing: retention))")
        return chat
    }

    private func scheduledOutcome(
        chat: Chat,
        invocation: UserSkillInvocation
    ) async -> ChatSubmissionOutcome {
        await withTaskGroup(of: ChatSubmissionOutcome.self) { group in
            group.addTask { @MainActor in
                await chat.submitAndWait(
                    invocation.expandedIntent,
                    skillInvocation: invocation
                )
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    if chat.hasPendingInteraction {
                        return .failed("The scheduled skill needs attention in Ox.")
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return .cancelled
            }
            let outcome = await group.next() ?? .cancelled
            group.cancelAll()
            if case .failed = outcome, chat.hasPendingInteraction {
                chat.cancelAll()
            }
            return outcome
        }
    }

    private func restoredChat(from loaded: ChatLoadResult, in scope: ProfileScope) -> Chat {
        let client = providerRegistry.client(forSnapshot: loaded.state.meta.clientID)
        let model = providerRegistry.model(
            forSnapshot: loaded.state.meta.modelID,
            reasoningEffort: loaded.state.meta.reasoningEffort,
            client: client
        )
        let chat = Chat(
            meta: loaded.state.meta,
            turns: loaded.state.turns,
            context: loaded.state.context,
            client: client,
            model: model,
            repository: repository,
            scope: scope,
            virtualMachine: virtualMachine,
            presentations: presentations,
            serviceManager: serviceManager
        )
        attachPersistence(chat)
        return chat
    }

    private func ensureRepositoryScope(force: Bool = false) {
        let currentScope = storage.scope
        let sameProfile = currentScope.profileID == repositoryScope.profileID
            && currentScope.root.standardizedFileURL == repositoryScope.root.standardizedFileURL
            && currentScope.location == repositoryScope.location
        guard force || !sameProfile else { return }
        let scope = force
            ? ProfileScope(profileID: currentScope.profileID, root: currentScope.root, location: currentScope.location)
            : currentScope
        repositoryScope = scope
        virtualMachine = VirtualMachine()
        Log.session.info("ChatManager.repository root=\(scope.root.path) generation=\(scope.generation)")
    }

    private func attachPersistence(_ chat: Chat) {
        if !chat.isTemporary {
            chat.onPersistableChange = { [weak self, weak chat] in
                guard let self, let chat else { return }
                self.persist(chat)
            }
        } else {
            chat.onPersistableChange = nil
        }
        chat.onPrivateDataTemporaryContinuation = { [weak self, weak chat] continuation in
            guard let self, let chat else { return }
            Task { @MainActor [weak self, weak chat] in
                await Task.yield()
                guard let self, let chat, self.current === chat else { return }
                chat.stopCurrentTurn()
                self.startTemporaryChat(continuing: continuation)
            }
        }
    }

    private func persist(_ chat: Chat) {
        guard !chat.isTemporary, !chat.transcript.isEmpty else { return }
        enqueue(ChatSaveRequest(payload: .chat(chat.state)))
    }

    private func persist(_ meta: ChatMeta) {
        enqueue(ChatSaveRequest(payload: .metadata(meta)))
    }

    private func enqueue(_ request: ChatSaveRequest) {
        let id = request.chatID
        guard var record = records[id] else { return }
        switch record.persistence {
        case .clean:
            let task = debounce(id, request)
            record.persistence = .debouncing(request, task)
        case .debouncing(_, let task):
            task.cancel()
            record.persistence = .debouncing(request, debounce(id, request))
        case .saving(let inFlight, _, let task):
            record.persistence = .saving(inFlight, request, task)
        case .deleting, .deleted:
            return
        }
        records[id] = record
    }

    private func debounce(_ id: ChatID, _ request: ChatSaveRequest) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNs)
            guard !Task.isCancelled else { return }
            self?.beginSave(id, expected: request.saveID)
        }
    }

    private func beginSave(_ id: ChatID, expected saveID: SaveID) {
        guard var record = records[id],
              case .debouncing(let request, _) = record.persistence,
              request.saveID == saveID else { return }
        launch(request, in: &record)
        records[id] = record
    }

    private func launch(_ request: ChatSaveRequest, in record: inout Record) {
        let scopedRepository = repository
        let storageScope = repositoryScope
        let worker = Task { await scopedRepository.saveChat(request, in: storageScope) }
        record.persistence = .saving(request, nil, worker)
        Task { [weak self] in
            let result = await worker.value
            self?.complete(request.chatID, result: result, storageScope: storageScope)
        }
    }

    private func complete(_ id: ChatID, result: ChatSaveReceipt, storageScope: ProfileScope) {
        guard repositoryScope == storageScope,
              var record = records[id],
              case .saving(let inFlight, let pendingLatest, _) = record.persistence,
              inFlight.saveID == result.saveID else { return }
        if let pendingLatest {
            launch(pendingLatest, in: &record)
        } else if result.succeeded {
            record.persistence = .clean
        } else {
            record.persistence = .debouncing(inFlight, debounce(id, inFlight))
        }
        records[id] = record
        trimHydrated()
    }

    private func flushDebounced() {
        let pending = records.compactMap { id, record -> (ChatID, SaveID)? in
            if case .debouncing(let request, let task) = record.persistence {
                task.cancel()
                return (id, request.saveID)
            }
            return nil
        }
        for (id, saveID) in pending { beginSave(id, expected: saveID) }
    }

    private func setCurrent(_ chat: Chat) {
        let id = ChatID(chat.id)
        touch(id)
        if case .active(let current) = selection, current === chat { return }
        let outgoing = current
        selection = .active(chat)
        outgoing?.deselect()
        chat.select()
        Task {
            await chat.attach()
            if let outgoing, self.current !== outgoing { outgoing.detach() }
            if self.current !== chat { chat.detach() }
        }
        if let outgoing, outgoing.isTemporary {
            discardTemporary(ChatID(outgoing.id))
        }
        trimHydrated()
    }

    private func touch(_ id: ChatID) {
        guard var record = records[id] else { return }
        hydrationOrdinal &+= 1
        record.accessOrdinal = hydrationOrdinal
        records[id] = record
    }

    private func trimHydrated() {
        while records.values.compactMap({ $0.hydration.chat }).count > Self.maxHydratedChats {
            guard let candidate = records
                .filter({ $0.key.rawValue != currentId && $0.value.hydration.chat?.isBusy == false })
                .min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal }) else {
                Log.session.warning("ChatManager.evict deferred loaded=\(records.values.compactMap { $0.hydration.chat }.count)")
                return
            }
            let id = candidate.key
            var record = candidate.value
            guard !record.persistence.isDirty, let chat = record.hydration.chat else {
                if case .debouncing(let request, let task) = record.persistence {
                    task.cancel()
                    beginSave(id, expected: request.saveID)
                }
                return
            }
            let meta = chat.metadata
            chat.release(cancelling: false)
            record.hydration = .unloaded(meta)
            records[id] = record
            Log.session.info("ChatManager.evict id=\(id)")
        }
    }

}
