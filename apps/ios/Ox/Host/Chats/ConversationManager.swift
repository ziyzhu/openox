import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ConversationManager {
    private struct Record {
        enum HydrationState {
            case unloaded(ChatMeta)
            case loading(ChatMeta, HydrationGeneration)
            case loaded(Conversation)

            var meta: ChatMeta {
                switch self {
                case .unloaded(let meta), .loading(let meta, _): meta
                case .loaded(let chat): chat.metadata
                }
            }

            var chat: Conversation? {
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

        init(chat: Conversation, accessOrdinal: UInt64) {
            hydration = .loaded(chat)
            persistence = .clean
            self.accessOrdinal = accessOrdinal
            metadataRevision = 0
        }
    }

    private enum Selection {
        case empty
        case deferred(ChatID, previous: Conversation?)
        case opening(ChatID, HydrationGeneration, previous: Conversation?)
        case active(Conversation)
    }

    private var records: [ChatID: Record] = [:]
    private var selection: Selection = .empty
    @ObservationIgnored private var hydrationOrdinal: UInt64 = 0
    @ObservationIgnored private var hydrationGeneration: UInt64 = 0
    @ObservationIgnored private var recoveryPreparation: (scope: ProfileScope, task: Task<Void, Error>)?
    @ObservationIgnored private var hydrationTasks: [ChatID: (generation: HydrationGeneration, task: Task<Conversation?, Never>)] = [:]
    @ObservationIgnored private let repository: ProfileRepository
    @ObservationIgnored private let storage: StorageRoot
    @ObservationIgnored private let providerRegistry: ProviderRegistry
    @ObservationIgnored private let serviceManager: ServiceManager
    @ObservationIgnored private var repositoryScope: ProfileScope
    @ObservationIgnored private let presentations: AppPresentations
    @ObservationIgnored var profilePreparation: @MainActor () async -> Void = {}
    @ObservationIgnored private let debugRepositorySaveGate: ProfileRepositorySaveGate
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
        self.repository = repository
        self.storage = storage
        self.providerRegistry = providerRegistry
        self.serviceManager = serviceManager
        debugRepositorySaveGate = repository.debugSaveGate
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
            if record.hydration.chat?.hasTranscript == false { return nil }
            return record.hydration.meta
        }
    }

    var orderedSummaries: [ChatMeta] {
        summaries.sorted { $0.activityDate > $1.activityDate }
    }

    var activities: [UUID: Conversation.Activity] {
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

    var current: Conversation? {
        switch selection {
        case .empty: nil
        case .deferred(_, let previous), .opening(_, _, let previous): previous
        case .active(let chat): chat
        }
    }

    private func canonicalID(_ rawID: UUID) -> ChatID {
        (try? DurableProfileStore.shared.reference(for: ChatID(rawID), in: repositoryScope).compatibilityID) ?? ChatID(rawID)
    }

    func contains(_ rawID: UUID) -> Bool {
        guard let record = records[canonicalID(rawID)] else { return false }
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
        do { try await recoverConversations(in: scope) }
        catch { Log.session.error("ChatManager.recovery blocked error=\(error.localizedDescription)") }
        Log.session.info("ChatManager.loadSummaries count=\(summaries.count) preserved=\(preserved) generation=\(scope.generation)")
        if case .deferred(let id, _) = selection { open(id.rawValue) }
    }

    private func recoverConversations(in scope: ProfileScope) async throws {
        if let pending = recoveryPreparation, pending.scope == scope { return try await pending.task.value }
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let plan = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("recoveryPlan")]))
            let pending = (plan.objectValue?["tasks"]?.arrayValue ?? []) + (plan.objectValue?["submissions"]?.arrayValue ?? [])
            var chats: [Int: Conversation] = [:]
            for item in pending {
                guard let value = item.objectValue?["reference"] else { throw RuntimeError.bridge("Missing recovery conversation scope") }
                let reference = try JSONDecoder().decode(DurableConversationReference.self, from: Data(value.jsonString().utf8))
                guard reference.profileID == scope.profileID, repositoryScope == scope else { throw CancellationError() }
                if chats[reference.conversationID] != nil { continue }
                let chat: Conversation
                if let hydrated = await hydrate(reference.compatibilityID) { chat = hydrated }
                else {
                    guard let loaded = await repository.loadChat(reference.compatibilityID, in: scope) else {
                        throw RuntimeError.bridge("Recovered conversation is unavailable; Profile progress remains paused")
                    }
                    chat = restoredChat(from: loaded, in: scope)
                    hydrationOrdinal &+= 1
                    records[reference.compatibilityID] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
                }
                try await chat.prepareDurableRecovery()
                chats[reference.conversationID] = chat
            }
            let admission = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("recoveryPlan")]))
            guard admission.objectValue?["unconfigured"]?.arrayValue?.isEmpty == true else {
                throw RuntimeError.bridge("Recovered native configuration is unavailable; no tasks were resumed")
            }
            var submissions: [Int: (id: Int, requestID: String?)] = [:]
            for item in admission.objectValue?["submissions"]?.arrayValue ?? [] {
                guard let fields = item.objectValue, let id = fields["submissionID"]?.intValue,
                      let conversationID = fields["reference"]?.objectValue?["conversationID"]?.intValue else { continue }
                if id > (submissions[conversationID]?.id ?? -1) { submissions[conversationID] = (id, fields["requestID"]?.stringValue) }
            }
            for (conversationID, submission) in submissions {
                chats[conversationID]?.resumeDurableSubmission(submission.id, requestID: submission.requestID)
            }
            if submissions.isEmpty, let chat = chats.values.first, let reference = chat.conversationReference {
                _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("resume"), "reference": reference.value]))
            }
            Log.session.info("ChatManager.recovery attached=\(chats.count) submissions=\(submissions.count)")
        }
        recoveryPreparation = (scope, task)
        try await task.value
    }

    @discardableResult
    func startNewChat() -> Conversation {
        ensureRepositoryScope()
        if let current, current.transcript.isEmpty, !current.isTemporary { return current }
        let chat = makeChat()
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        setCurrent(chat)
        return chat
    }

    func startConversation(prompt: String, title: String, requestedBy caller: Conversation) throws -> UUID {
        guard caller.scope == repositoryScope, caller.scope == storage.scope,
              contains(caller.id) else {
            throw RuntimeError.bridge("ox.conversation.start: the calling chat must belong to the active Profile.")
        }
        let chat = makeChat()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { chat.rename(to: title) }
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        chat.enqueue(prompt)
        Log.session.info("bridge.chat.start caller=\(caller.id) target=\(chat.id)")
        return chat.id
    }

    func readableChatState(_ id: ChatID, in scope: ProfileScope) -> ChatState? {
        guard scope == repositoryScope, scope == storage.scope, contains(id.rawValue),
              let chat = records[id]?.hydration.chat, !chat.isTemporary else { return nil }
        return chat.state
    }

    func readableChatSummaries(in scope: ProfileScope) -> [ChatMeta] {
        guard scope == repositoryScope, scope == storage.scope else { return [] }
        return summaries.filter { records[ChatID($0.id)]?.hydration.chat != nil }
    }

    func importPackage(_ payload: ChatPackagePayload) async throws -> Conversation {
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

    func runScheduledSkill(
        _ schedule: ScheduledSkill,
        executionLease: Conversation.ExecutionLease
    ) async -> (ChatSubmissionOutcome, UUID?) {
        ensureRepositoryScope()
        guard repositoryScope.profileID == schedule.profileID else {
            return (.failed("The scheduled skill's Profile is not active."), nil)
        }
        let services: [Service]
        do {
            services = try await serviceManager.prepareServices(
                domains: schedule.skill.services,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
        } catch is CancellationError {
            return (.cancelled, nil)
        } catch {
            Log.session.error("ChatManager.scheduled preparation failed schedule=\(schedule.id) error=\(error.localizedDescription)")
            return (.failed(error.localizedDescription), nil)
        }
        ensureRepositoryScope()
        guard repositoryScope.profileID == schedule.profileID else {
            return (.failed("The scheduled skill's Profile is not active."), nil)
        }
        let chat = makeChat(
            executionLease: executionLease,
            scheduledSkillID: schedule.id
        )
        chat.rename(to: "Scheduled /\(schedule.skill.displayName)")
        chat.setAttachedServices(services)
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        let invocation = UserSkillInvocation(skill: schedule.skill, argument: schedule.argument)
        let outcome = await chat.submitUntilAttention(
            invocation.expandedIntent,
            skillInvocation: invocation
        )
        _ = await flushAllNow()
        Log.session.info("ChatManager.scheduled finished schedule=\(schedule.id) chat=\(chat.id) outcome=\(outcome.logLabel)")
        return (outcome, chat.id)
    }

    func toggleTemporaryChat() {
        guard let previous = current, previous.transcript.isEmpty, previous.queuedMessages.isEmpty, !previous.isBusy else { return }
        let chat = makeChat(retention: previous.isTemporary ? .persisted : .temporary)
        hydrationOrdinal &+= 1
        records[ChatID(chat.id)] = Record(chat: chat, accessOrdinal: hydrationOrdinal)
        setCurrent(chat)
        Log.session.info("ChatManager.retention chat=\(chat.id) temporary=\(chat.isTemporary)")
    }

    private func startTemporaryChat(continuing continuation: ChatContinuation) {
        let selection = continuation.meta.model ?? providerRegistry.sessionModel
        let client = providerRegistry.client(for: selection)
        let model = providerRegistry.model(for: selection, client: client)
        let chat = Conversation(
            meta: continuation.meta,
            turns: continuation.turns,
            client: client,
            model: model,
            selection: selection,
            repository: repository,
            scope: repositoryScope,
            virtualMachine: VirtualMachine(),
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
        let id = canonicalID(rawID)
        if let chat = records[id]?.hydration.chat {
            touch(id)
            setCurrent(chat)
            return
        }
        guard records[id] != nil else {
            selection = .deferred(id, previous: current)
            Log.session.info("ChatManager.open deferred id=\(id)")
            return
        }
        hydrationGeneration &+= 1
        let generation = HydrationGeneration(rawValue: hydrationGeneration)
        selection = .opening(id, generation, previous: current)
        Task { [weak self] in
            guard let self else { return }
            let chat = await self.hydrate(id)
            guard case .opening(let openingID, let openingGeneration, _) = self.selection,
                  openingID == id, openingGeneration == generation else { return }
            if let chat { self.setCurrent(chat) }
            else { self.selection = self.current.map(Selection.active) ?? .empty }
        }
    }

    func openForClient(_ rawID: UUID) async throws -> Conversation {
        ensureRepositoryScope()
        let scope = repositoryScope
        let storageScope = storage.scope
        let id = canonicalID(rawID)
        guard contains(rawID), let chat = await hydrate(id),
              scope == repositoryScope, storageScope == storage.scope, contains(rawID) else {
            throw RuntimeError.bridge("chat unavailable: \(rawID)")
        }
        setCurrent(chat)
        return chat
    }

    private func hydrate(_ id: ChatID) async -> Conversation? {
        if let chat = records[id]?.hydration.chat { return chat }
        if let pending = hydrationTasks[id] { return await pending.task.value }
        guard var record = records[id], contains(id.rawValue) else { return nil }
        hydrationGeneration &+= 1
        let generation = HydrationGeneration(rawValue: hydrationGeneration)
        let scope = repositoryScope
        record.hydration = .loading(record.hydration.meta, generation)
        records[id] = record
        Log.session.info("ChatManager.hydrate id=\(id) generation=\(generation.rawValue)")
        let task = Task { [weak self, repository] () -> Conversation? in
            let loaded = await repository.loadChat(id, in: scope)
            guard let self, self.repositoryScope == scope,
                  var record = self.records[id], self.contains(id.rawValue),
                  case .loading(_, let activeGeneration) = record.hydration,
                  activeGeneration == generation else { return nil }
            guard let loaded else {
                record.hydration = .unloaded(record.hydration.meta)
                self.records[id] = record
                Log.session.error("ChatManager.hydrate unavailable id=\(id)")
                return nil
            }
            let restored = record.persistence.isDirty ? loaded.replacingMeta(record.hydration.meta) : loaded
            let chat = self.restoredChat(from: restored, in: scope)
            self.hydrationOrdinal &+= 1
            record.hydration = .loaded(chat)
            record.accessOrdinal = self.hydrationOrdinal
            self.records[id] = record
            if loaded.needsPersistence || chat.state != loaded.state { self.persist(chat) }
            return chat
        }
        hydrationTasks[id] = (generation, task)
        let chat = await task.value
        if hydrationTasks[id]?.generation == generation { hydrationTasks[id] = nil }
        return chat
    }

    @discardableResult
    func branch(from chat: Conversation, atBlock blockID: UUID) -> Conversation? {
        guard let result = chat.branchSnapshot(at: blockID) else {
            Log.session.warning("ChatManager.branch failed block=\(blockID)")
            return nil
        }
        return branch(from: chat, snapshot: result)
    }

    func branch(from chat: Conversation, snapshot result: ChatContinuation) -> Conversation? {
        guard let reference = chat.conversationReference else { Log.session.error("ChatManager.branch requires a qualified persisted conversation"); return nil }
        let selection = result.meta.model ?? providerRegistry.sessionModel
        let client = providerRegistry.client(for: selection)
        let model = providerRegistry.model(for: selection, client: client)
        let branched = Conversation(
            meta: result.meta,
            turns: result.turns,
            client: client,
            model: model,
            selection: selection,
            repository: repository,
            scope: repositoryScope,
            virtualMachine: VirtualMachine(),
            presentations: presentations,
            serviceManager: serviceManager
        )
        branched.durableForkSource = (reference, result.turns.filter { if case .user = $0 { return true }; return false }.count)
        attachPersistence(branched)
        hydrationOrdinal &+= 1
        records[ChatID(branched.id)] = Record(chat: branched, accessOrdinal: hydrationOrdinal)
        if branched.state.turns != result.turns { persist(branched) }
        setCurrent(branched)
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
        artifactFilesChanged()
        Log.session.info("ChatManager.deleteArtifact file=\(artifact.fileName)")
    }

    func artifactFilesChanged() {
        for chat in records.values.compactMap({ $0.hydration.chat }) {
            chat.artifactFilesChanged()
        }
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

    @discardableResult
    func delete(_ rawID: UUID) -> Task<Void, Error>? {
        let id = ChatID(rawID)
        guard var record = records[id] else { return nil }
        let wasCurrent = currentId == rawID
        if record.hydration.chat?.isTemporary == true {
            discardTemporary(id)
            if wasCurrent { startNewChat() }
            return nil
        }
        let inFlight: Task<ChatSaveReceipt, Never>?
        switch record.persistence {
        case .debouncing(_, let task):
            task.cancel()
            inFlight = nil
        case .saving(_, _, let task):
            inFlight = task
        case .clean:
            inFlight = nil
        case .deleting, .deleted:
            return nil
        }
        record.persistence = .deleting
        record.hydration.chat?.release()
        records[id] = record
        let scopedRepository = repository
        let storageScope = repositoryScope
        let deletion = Task { [weak self] in
            _ = await inFlight?.value
            do {
                try await scopedRepository.deleteConversation(id, in: storageScope)
            } catch {
                if let self, self.repositoryScope == storageScope {
                    record.persistence = .clean
                    self.records[id] = record
                    if let chat = record.hydration.chat {
                        self.attachPersistence(chat)
                        self.persist(chat)
                    }
                }
                Log.session.error("ChatManager.delete failed id=\(id) error=\(error.localizedDescription)")
                throw error
            }
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
        return deletion
    }

    func deletionTarget(_ id: UUID, requestedBy chat: Conversation) throws -> ChatMeta {
        guard chat.scope == repositoryScope, chat.scope.profileID == storage.scope.profileID,
              chat.scope.root == storage.scope.root, chat.scope.location == storage.scope.location,
              id != chat.id,
              let meta = summaries.first(where: { $0.id == id }) else {
            throw RuntimeError.bridge("ox.conversation.delete: choose another existing chat in the active Profile.")
        }
        return meta
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
        hydrationTasks.values.forEach { $0.task.cancel() }
        hydrationTasks.removeAll()
        records.removeAll()
        selection = .empty
        ensureRepositoryScope(force: true)
        Log.session.info("ChatManager.reset generation=\(repositoryScope.generation)")
    }

    func debugSession(matching needle: String) -> Conversation? {
        let lower = needle.lowercased()
        return records.values.compactMap { $0.hydration.chat }.first {
            $0.id.uuidString.lowercased().hasPrefix(lower)
        }
    }

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


    private func makeChat(
        retention: ChatRetention = .persisted,
        executionLease: Conversation.ExecutionLease = .userInitiated,
        scheduledSkillID: UUID? = nil
    ) -> Conversation {
        let client = providerRegistry.newSessionClient
        let selection = providerRegistry.sessionModel
        let chat = Conversation(
            client: client,
            model: providerRegistry.model(for: selection, client: client),
            selection: selection,
            repository: repository,
            scope: repositoryScope,
            virtualMachine: VirtualMachine(),
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

    private func restoredChat(from loaded: ChatLoadResult, in scope: ProfileScope) -> Conversation {
        let selection = loaded.state.meta.model ?? providerRegistry.sessionModel
        let client = providerRegistry.client(for: selection)
        let model = providerRegistry.model(for: selection, client: client)
        let chat = Conversation(
            meta: loaded.state.meta,
            turns: loaded.state.turns,
            context: loaded.state.context,
            client: client,
            model: model,
            selection: selection,
            repository: repository,
            scope: scope,
            virtualMachine: VirtualMachine(),
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
        Log.session.info("ChatManager.repository root=\(scope.root.path) generation=\(scope.generation)")
    }

    private func attachPersistence(_ chat: Conversation) {
        chat.conversationManager = self
        chat.durablePreparation = Task { @MainActor [weak self, weak chat] in
            guard let self, let chat else { throw CancellationError() }
            if chat.isTemporary {
                try await OxHostProtocol.prepareDurableTemporaryChat(chat, caseID: OxHostProtocol.durableTemporarySessionID ?? UUID())
            } else {
                let oldID = ChatID(chat.id)
                let reference: DurableConversationReference
                if let existing = try? DurableProfileStore.shared.reference(for: oldID, in: chat.scope) { reference = existing }
                else if let origin = chat.durableForkSource {
                    reference = try await DurableProfileStore.shared.fork(in: chat.scope, from: origin.reference,
                        beforeUser: origin.users, title: chat.metadata.title)
                    chat.durableForkSource = nil
                } else { reference = try await DurableProfileStore.shared.create(in: chat.scope) }
                try Task.checkCancellation()
                let session = try await DurableProfileStore.shared.session(in: chat.scope)
                try chat.installDurableRoute(DurableConversationRoute(session: session,
                    nativeID: reference.compatibilityID.rawValue, profileID: reference.profileID,
                    artifactScope: chat.scope, reference: reference))
                if oldID != reference.compatibilityID, var record = records.removeValue(forKey: oldID) {
                    if case .debouncing(_, let task) = record.persistence { task.cancel() }
                    record.persistence = .clean
                    records[reference.compatibilityID] = record
                }
                persist(chat)
            }
            chat.durablePreparation = nil
        }
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

    private func persist(_ chat: Conversation) {
        guard !chat.isTemporary, chat.conversationReference != nil, !chat.transcript.isEmpty else { return }
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

    private func setCurrent(_ chat: Conversation) {
        let id = ChatID(chat.id)
        touch(id)
        if case .active(let current) = selection, current === chat { return }
        let outgoing = current
        selection = .active(chat)
        chat.select()
        outgoing?.deselect()
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
