import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class ConversationManager {
    private struct Record {
        enum HydrationState {
            case unloaded(ConversationMeta)
            case loading(ConversationMeta, HydrationGeneration)
            case loaded(Conversation)

            var meta: ConversationMeta {
                switch self {
                case .unloaded(let meta), .loading(let meta, _): meta
                case .loaded(let conversation): conversation.metadata
                }
            }

            var conversation: Conversation? {
                if case .loaded(let conversation) = self { conversation } else { nil }
            }

            func replacingMeta(_ meta: ConversationMeta) -> Self {
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
            case debouncing(ConversationSaveRequest, Task<Void, Never>)
            case saving(ConversationSaveRequest, ConversationSaveRequest?, Task<ConversationSaveReceipt, Never>)
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

        init(meta: ConversationMeta, accessOrdinal: UInt64 = 0) {
            hydration = .unloaded(meta)
            persistence = .clean
            self.accessOrdinal = accessOrdinal
            metadataRevision = 0
        }

        init(conversation: Conversation, accessOrdinal: UInt64) {
            hydration = .loaded(conversation)
            persistence = .clean
            self.accessOrdinal = accessOrdinal
            metadataRevision = 0
        }
    }

    private enum Selection {
        case empty
        case deferred(ConversationID, previous: Conversation?)
        case opening(ConversationID, HydrationGeneration, previous: Conversation?)
        case active(Conversation)
    }

    private var records: [ConversationID: Record] = [:]
    private var selection: Selection = .empty
    @ObservationIgnored private var hydrationOrdinal: UInt64 = 0
    @ObservationIgnored private var hydrationGeneration: UInt64 = 0
    @ObservationIgnored private var recoveryPreparation: (scope: ProfileScope, task: Task<Void, Error>)?
    @ObservationIgnored private var hydrationTasks: [ConversationID: (generation: HydrationGeneration, task: Task<Conversation?, Never>)] = [:]
    @ObservationIgnored private let repository: ProfileRepository
    @ObservationIgnored private let storage: StorageRoot
    @ObservationIgnored private let providerRegistry: ProviderRegistry
    @ObservationIgnored private let serviceManager: ServiceManager
    @ObservationIgnored private var repositoryScope: ProfileScope
    @ObservationIgnored private let presentations: AppPresentations
    @ObservationIgnored var profilePreparation: @MainActor () async -> Void = {}
    @ObservationIgnored private let debugRepositorySaveGate: ProfileRepositorySaveGate
    private static let saveDebounceNs: UInt64 = 1_000_000_000
    private static let maxHydratedConversations = 5

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

    var summaries: [ConversationMeta] {
        records.values.compactMap { record in
            switch record.persistence {
            case .deleting, .deleted:
                return nil
            case .clean, .debouncing, .saving:
                break
            }
            if record.hydration.conversation?.isTemporary == true { return nil }
            if record.hydration.conversation?.hasTranscript == false { return nil }
            return record.hydration.meta
        }
    }

    var orderedSummaries: [ConversationMeta] {
        summaries.sorted { $0.activityDate > $1.activityDate }
    }

    var activities: [UUID: Conversation.Activity] {
        Dictionary(uniqueKeysWithValues: records.map { id, record in
            let activity = record.hydration.conversation?.activity
                ?? .idle(record.hydration.meta.hasUnreadResponse ? .unread : .read)
            return (id.rawValue, activity)
        })
    }

    var currentId: UUID? {
        switch selection {
        case .empty: nil
        case .deferred(_, let previous), .opening(_, _, let previous): previous?.id
        case .active(let conversation): conversation.id
        }
    }

    var openingId: UUID? {
        if case .opening(let id, _, _) = selection { id.rawValue } else { nil }
    }

    var current: Conversation? {
        switch selection {
        case .empty: nil
        case .deferred(_, let previous), .opening(_, _, let previous): previous
        case .active(let conversation): conversation
        }
    }

    private func canonicalID(_ rawID: UUID) -> ConversationID {
        (try? DurableProfileStore.shared.reference(for: ConversationID(rawID), in: repositoryScope).compatibilityID) ?? ConversationID(rawID)
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
        let summaries = await scopedRepository.conversationSummaries(in: scope)
        guard repositoryScope == scope else { return }
        var loaded = Dictionary(uniqueKeysWithValues: summaries.map { meta in
            (ConversationID(meta.id), Record(meta: meta))
        })
        var preserved = 0
        for (id, record) in records {
            let changedWhileLoading = revisions[id] != record.metadataRevision
            if record.hydration.conversation != nil
                || record.persistence.preservesLocalRecordDuringReload
                || locallyAuthoritative.contains(id)
                || changedWhileLoading {
                loaded[id] = record
                preserved += 1
            }
        }
        records = loaded
        do { try await recoverConversations(in: scope) }
        catch { Log.session.error("ConversationManager.recovery blocked error=\(error.localizedDescription)") }
        Log.session.info("ConversationManager.loadSummaries count=\(summaries.count) preserved=\(preserved) generation=\(scope.generation)")
        if case .deferred(let id, _) = selection { open(id.rawValue) }
    }

    private func recoverConversations(in scope: ProfileScope) async throws {
        if let pending = recoveryPreparation, pending.scope == scope { return try await pending.task.value }
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let plan = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("recoveryPlan")]))
            let pending = (plan.objectValue?["tasks"]?.arrayValue ?? []) + (plan.objectValue?["submissions"]?.arrayValue ?? [])
            var conversations: [Int: Conversation] = [:]
            for item in pending {
                guard let value = item.objectValue?["reference"] else { throw RuntimeError.bridge("Missing recovery conversation scope") }
                let reference = try JSONDecoder().decode(DurableConversationReference.self, from: Data(value.jsonString().utf8))
                guard reference.profileID == scope.profileID, repositoryScope == scope else { throw CancellationError() }
                if conversations[reference.conversationID] != nil { continue }
                let conversation: Conversation
                if let hydrated = await hydrate(reference.compatibilityID) { conversation = hydrated }
                else {
                    guard let loaded = await repository.loadConversation(reference.compatibilityID, in: scope) else {
                        throw RuntimeError.bridge("Recovered conversation is unavailable; Profile progress remains paused")
                    }
                    conversation = restoredConversation(from: loaded, in: scope)
                    hydrationOrdinal &+= 1
                    records[reference.compatibilityID] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
                }
                try await conversation.prepareDurableRecovery()
                conversations[reference.conversationID] = conversation
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
                conversations[conversationID]?.resumeDurableSubmission(submission.id, requestID: submission.requestID)
            }
            if submissions.isEmpty, let conversation = conversations.values.first, let reference = conversation.conversationReference {
                _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("resume"), "reference": reference.value]))
            }
            Log.session.info("ConversationManager.recovery attached=\(conversations.count) submissions=\(submissions.count)")
        }
        recoveryPreparation = (scope, task)
        try await task.value
    }

    @discardableResult
    func startNewConversation() -> Conversation {
        ensureRepositoryScope()
        if let current, current.transcript.isEmpty, !current.isTemporary { return current }
        let conversation = makeConversation()
        hydrationOrdinal &+= 1
        records[ConversationID(conversation.id)] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
        setCurrent(conversation)
        return conversation
    }

    func startConversation(prompt: String, title: String, requestedBy caller: Conversation) throws -> UUID {
        guard caller.scope == repositoryScope, caller.scope == storage.scope,
              contains(caller.id) else {
            throw RuntimeError.bridge("ox.conversation.start: the calling conversation must belong to the active Profile.")
        }
        let conversation = makeConversation()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { conversation.rename(to: title) }
        hydrationOrdinal &+= 1
        records[ConversationID(conversation.id)] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
        conversation.enqueue(prompt)
        Log.session.info("bridge.chat.start caller=\(caller.id) target=\(conversation.id)")
        return conversation.id
    }

    func readableConversationState(_ id: ConversationID, in scope: ProfileScope) -> ConversationState? {
        guard scope == repositoryScope, scope == storage.scope, contains(id.rawValue),
              let conversation = records[id]?.hydration.conversation, !conversation.isTemporary else { return nil }
        return conversation.state
    }

    func readableConversationSummaries(in scope: ProfileScope) -> [ConversationMeta] {
        guard scope == repositoryScope, scope == storage.scope else { return [] }
        return summaries.filter { records[ConversationID($0.id)]?.hydration.conversation != nil }
    }

    func importPackage(_ payload: ConversationPackagePayload) async throws -> Conversation {
        ensureRepositoryScope()
        let scope = repositoryScope
        let state = try await repository.importConversationPackage(payload, in: scope)
        guard repositoryScope == scope else { throw ConversationPackageError.invalidArchive }
        let conversation = restoredConversation(
            from: ConversationLoadResult(state: state, needsPersistence: false),
            in: scope
        )
        hydrationOrdinal &+= 1
        records[state.conversationID] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
        setCurrent(conversation)
        Log.session.info("ConversationManager.import chat=\(conversation.id) turns=\(state.turns.count)")
        return conversation
    }

    func runScheduledSkill(
        _ schedule: ScheduledSkill,
        executionLease: Conversation.ExecutionLease
    ) async -> (ConversationSubmissionOutcome, UUID?) {
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
            Log.session.error("ConversationManager.scheduled preparation failed schedule=\(schedule.id) error=\(error.localizedDescription)")
            return (.failed(error.localizedDescription), nil)
        }
        ensureRepositoryScope()
        guard repositoryScope.profileID == schedule.profileID else {
            return (.failed("The scheduled skill's Profile is not active."), nil)
        }
        let conversation = makeConversation(
            executionLease: executionLease,
            scheduledSkillID: schedule.id
        )
        conversation.rename(to: "Scheduled /\(schedule.skill.displayName)")
        conversation.setAttachedServices(services)
        hydrationOrdinal &+= 1
        records[ConversationID(conversation.id)] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
        let invocation = UserSkillInvocation(skill: schedule.skill, argument: schedule.argument)
        let outcome = await conversation.submitUntilAttention(
            invocation.expandedIntent,
            skillInvocation: invocation
        )
        _ = await flushAllNow()
        Log.session.info("ConversationManager.scheduled finished schedule=\(schedule.id) conversation=\(conversation.id) outcome=\(outcome.logLabel)")
        return (outcome, conversation.id)
    }

    func toggleTemporaryConversation() {
        guard let previous = current, previous.transcript.isEmpty, previous.queuedMessages.isEmpty, !previous.isBusy else { return }
        let conversation = makeConversation(retention: previous.isTemporary ? .persisted : .temporary)
        hydrationOrdinal &+= 1
        records[ConversationID(conversation.id)] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
        setCurrent(conversation)
        Log.session.info("ConversationManager.retention chat=\(conversation.id) temporary=\(conversation.isTemporary)")
    }

    private func startTemporaryConversation(continuing continuation: ConversationContinuation) {
        let selection = continuation.meta.model ?? providerRegistry.sessionModel
        let client = providerRegistry.client(for: selection)
        let model = providerRegistry.model(for: selection, client: client)
        let conversation = Conversation(
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
        attachPersistence(conversation)
        hydrationOrdinal &+= 1
        records[ConversationID(conversation.id)] = Record(conversation: conversation, accessOrdinal: hydrationOrdinal)
        setCurrent(conversation)
        conversation.enqueue(
            continuation.intent,
            attachments: continuation.attachments,
            skillInvocation: continuation.skillInvocation
        )
        Log.session.info("ConversationManager.temporary started chat=\(conversation.id) turns=\(continuation.turns.count)")
    }

    private func discardTemporary(_ id: ConversationID) {
        guard let conversation = records[id]?.hydration.conversation, conversation.isTemporary else { return }
        conversation.release()
        records[id] = nil
        if currentId == id.rawValue { selection = .empty }
        Log.session.info("ConversationManager.temporary discarded chat=\(id)")
    }

    func open(_ rawID: UUID) {
        let id = canonicalID(rawID)
        if let conversation = records[id]?.hydration.conversation {
            touch(id)
            setCurrent(conversation)
            return
        }
        guard records[id] != nil else {
            selection = .deferred(id, previous: current)
            Log.session.info("ConversationManager.open deferred id=\(id)")
            return
        }
        hydrationGeneration &+= 1
        let generation = HydrationGeneration(rawValue: hydrationGeneration)
        selection = .opening(id, generation, previous: current)
        Task { [weak self] in
            guard let self else { return }
            let conversation = await self.hydrate(id)
            guard case .opening(let openingID, let openingGeneration, _) = self.selection,
                  openingID == id, openingGeneration == generation else { return }
            if let conversation { self.setCurrent(conversation) }
            else { self.selection = self.current.map(Selection.active) ?? .empty }
        }
    }

    func openForClient(_ rawID: UUID) async throws -> Conversation {
        ensureRepositoryScope()
        let scope = repositoryScope
        let storageScope = storage.scope
        let id = canonicalID(rawID)
        guard contains(rawID), let conversation = await hydrate(id),
              scope == repositoryScope, storageScope == storage.scope, contains(rawID) else {
            throw RuntimeError.bridge("conversation unavailable: \(rawID)")
        }
        setCurrent(conversation)
        return conversation
    }

    private func hydrate(_ id: ConversationID) async -> Conversation? {
        if let conversation = records[id]?.hydration.conversation { return conversation }
        if let pending = hydrationTasks[id] { return await pending.task.value }
        guard var record = records[id], contains(id.rawValue) else { return nil }
        hydrationGeneration &+= 1
        let generation = HydrationGeneration(rawValue: hydrationGeneration)
        let scope = repositoryScope
        record.hydration = .loading(record.hydration.meta, generation)
        records[id] = record
        Log.session.info("ConversationManager.hydrate id=\(id) generation=\(generation.rawValue)")
        let task = Task { [weak self, repository] () -> Conversation? in
            let loaded = await repository.loadConversation(id, in: scope)
            guard let self, self.repositoryScope == scope,
                  var record = self.records[id], self.contains(id.rawValue),
                  case .loading(_, let activeGeneration) = record.hydration,
                  activeGeneration == generation else { return nil }
            guard let loaded else {
                record.hydration = .unloaded(record.hydration.meta)
                self.records[id] = record
                Log.session.error("ConversationManager.hydrate unavailable id=\(id)")
                return nil
            }
            let restored = record.persistence.isDirty ? loaded.replacingMeta(record.hydration.meta) : loaded
            let conversation = self.restoredConversation(from: restored, in: scope)
            self.hydrationOrdinal &+= 1
            record.hydration = .loaded(conversation)
            record.accessOrdinal = self.hydrationOrdinal
            self.records[id] = record
            if loaded.needsPersistence || conversation.state != loaded.state { self.persist(conversation) }
            return conversation
        }
        hydrationTasks[id] = (generation, task)
        let conversation = await task.value
        if hydrationTasks[id]?.generation == generation { hydrationTasks[id] = nil }
        return conversation
    }

    @discardableResult
    func branch(from conversation: Conversation, atBlock blockID: UUID) -> Conversation? {
        guard let result = conversation.branchSnapshot(at: blockID) else {
            Log.session.warning("ConversationManager.branch failed block=\(blockID)")
            return nil
        }
        return branch(from: conversation, snapshot: result)
    }

    func branch(from conversation: Conversation, snapshot result: ConversationContinuation) -> Conversation? {
        guard let reference = conversation.conversationReference else { Log.session.error("ConversationManager.branch requires a qualified persisted conversation"); return nil }
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
        records[ConversationID(branched.id)] = Record(conversation: branched, accessOrdinal: hydrationOrdinal)
        if branched.state.turns != result.turns { persist(branched) }
        setCurrent(branched)
        return branched
    }

    func rename(_ rawID: UUID, to title: String) {
        let id = ConversationID(rawID)
        guard var record = records[id] else { return }
        if let conversation = record.hydration.conversation {
            record.metadataRevision &+= 1
            records[id] = record
            conversation.rename(to: title)
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

    func renameFile(_ artifact: FileItem, to newFilename: String) async throws -> FileItem {
        ensureRepositoryScope()
        let scope = repositoryScope
        let renamed = try await repository.renameFile(named: artifact.fileName, to: newFilename, in: scope)
        guard repositoryScope == scope else { return renamed }
        let directory = renamed.fileURL.deletingLastPathComponent()
        for conversation in records.values.compactMap({ $0.hydration.conversation }) {
            conversation.renameFileReferences(from: artifact.fileName, to: renamed.fileName, directory: directory)
        }
        Log.session.info("ConversationManager.renameFile from=\(artifact.fileName) to=\(renamed.fileName)")
        return renamed
    }

    func deleteFile(_ artifact: FileItem) async throws {
        ensureRepositoryScope()
        let scope = repositoryScope
        _ = try await repository.deleteFile(named: artifact.fileName, in: scope)
        artifactFilesChanged()
        Log.session.info("ConversationManager.deleteFile file=\(artifact.fileName)")
    }

    func artifactFilesChanged() {
        for conversation in records.values.compactMap({ $0.hydration.conversation }) {
            conversation.artifactFilesChanged()
        }
    }

    func toggleFavorite(_ rawID: UUID) {
        let id = ConversationID(rawID)
        guard var record = records[id] else { return }
        if let conversation = record.hydration.conversation {
            record.metadataRevision &+= 1
            records[id] = record
            conversation.setFavorite(!conversation.isFavorite)
            return
        }
        var meta = record.hydration.meta
        meta.isFavorite.toggle()
        record.hydration = record.hydration.replacingMeta(meta)
        record.metadataRevision &+= 1
        records[id] = record
        persist(meta)
        Log.session.info("ConversationManager.toggleFavorite id=\(id) favorite=\(meta.isFavorite) hydration=summary")
    }

    @discardableResult
    func delete(_ rawID: UUID) -> Task<Void, Error>? {
        let id = ConversationID(rawID)
        guard var record = records[id] else { return nil }
        let wasCurrent = currentId == rawID
        if record.hydration.conversation?.isTemporary == true {
            discardTemporary(id)
            if wasCurrent { startNewConversation() }
            return nil
        }
        let inFlight: Task<ConversationSaveReceipt, Never>?
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
        record.hydration.conversation?.release()
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
                    if let conversation = record.hydration.conversation {
                        self.attachPersistence(conversation)
                        self.persist(conversation)
                    }
                }
                Log.session.error("ConversationManager.delete failed id=\(id) error=\(error.localizedDescription)")
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
            startNewConversation()
        }
        return deletion
    }

    func deletionTarget(_ id: UUID, requestedBy conversation: Conversation) throws -> ConversationMeta {
        guard conversation.scope == repositoryScope, conversation.scope.profileID == storage.scope.profileID,
              conversation.scope.root == storage.scope.root, conversation.scope.location == storage.scope.location,
              id != conversation.id,
              let meta = summaries.first(where: { $0.id == id }) else {
            throw RuntimeError.bridge("ox.conversation.delete: choose another existing conversation in the active Profile.")
        }
        return meta
    }

    func flushAll() {
        #if os(iOS)
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ConversationManager.flushAll", expirationHandler: nil)
        #endif
        Task { [weak self] in
            guard let self else { return }
            _ = await self.flushAllNow()
            #if os(iOS)
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            #endif
            Log.session.info("ConversationManager.flushAll remaining=\(self.records.values.filter { $0.persistence.isDirty }.count)")
        }
    }

    func stopAllAndFlush() async -> Bool {
        let conversations = records.values.compactMap { $0.hydration.conversation }
        for conversation in conversations { conversation.cancelAll() }
        for conversation in conversations { await conversation.waitForRun() }
        return await flushAllNow()
    }

    func flushAllNow() async -> Bool {
        flushDebounced()
        while true {
            let tasks = records.values.compactMap { record -> Task<ConversationSaveReceipt, Never>? in
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
            record.hydration.conversation?.release()
        }
        hydrationTasks.values.forEach { $0.task.cancel() }
        hydrationTasks.removeAll()
        records.removeAll()
        selection = .empty
        ensureRepositoryScope(force: true)
        Log.session.info("ConversationManager.reset generation=\(repositoryScope.generation)")
    }

    func debugSession(matching needle: String) -> Conversation? {
        let lower = needle.lowercased()
        return records.values.compactMap { $0.hydration.conversation }.first {
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


    private func makeConversation(
        retention: ConversationRetention = .persisted,
        executionLease: Conversation.ExecutionLease = .userInitiated,
        scheduledSkillID: UUID? = nil
    ) -> Conversation {
        let client = providerRegistry.newSessionClient
        let selection = providerRegistry.sessionModel
        let conversation = Conversation(
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
        attachPersistence(conversation)
        Log.session.info("ConversationManager created chat=\(conversation.id) retention=\(String(describing: retention))")
        return conversation
    }

    private func restoredConversation(from loaded: ConversationLoadResult, in scope: ProfileScope) -> Conversation {
        let selection = loaded.state.meta.model ?? providerRegistry.sessionModel
        let client = providerRegistry.client(for: selection)
        let model = providerRegistry.model(for: selection, client: client)
        let conversation = Conversation(
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
        attachPersistence(conversation)
        return conversation
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
        Log.session.info("ConversationManager.repository root=\(scope.root.path) generation=\(scope.generation)")
    }

    private func attachPersistence(_ conversation: Conversation) {
        conversation.conversationManager = self
        conversation.durablePreparation = Task { @MainActor [weak self, weak conversation] in
            guard let self, let conversation else { throw CancellationError() }
            if conversation.isTemporary {
                try await OxHostProtocol.prepareDurableTemporaryConversation(conversation, caseID: OxHostProtocol.durableTemporarySessionID ?? UUID())
            } else {
                let oldID = ConversationID(conversation.id)
                let reference: DurableConversationReference
                if let existing = try? DurableProfileStore.shared.reference(for: oldID, in: conversation.scope) { reference = existing }
                else if let origin = conversation.durableForkSource {
                    reference = try await DurableProfileStore.shared.fork(in: conversation.scope, from: origin.reference,
                        beforeUser: origin.users, title: conversation.metadata.title)
                    conversation.durableForkSource = nil
                } else { reference = try await DurableProfileStore.shared.create(in: conversation.scope) }
                try Task.checkCancellation()
                let session = try await DurableProfileStore.shared.session(in: conversation.scope)
                try conversation.installDurableRoute(DurableConversationRoute(session: session,
                    conversationID: reference.conversationID, profileID: reference.profileID,
                    artifactScope: conversation.scope, reference: reference))
                if oldID != reference.compatibilityID, var record = records.removeValue(forKey: oldID) {
                    if case .debouncing(_, let task) = record.persistence { task.cancel() }
                    record.persistence = .clean
                    records[reference.compatibilityID] = record
                }
                persist(conversation)
            }
            conversation.durablePreparation = nil
        }
        if !conversation.isTemporary {
            conversation.onPersistableChange = { [weak self, weak conversation] in
                guard let self, let conversation else { return }
                self.persist(conversation)
            }
        } else {
            conversation.onPersistableChange = nil
        }
        conversation.onPrivateDataTemporaryContinuation = { [weak self, weak conversation] continuation in
            guard let self, let conversation else { return }
            Task { @MainActor [weak self, weak conversation] in
                await Task.yield()
                guard let self, let conversation, self.current === conversation else { return }
                conversation.stopCurrentTurn()
                self.startTemporaryConversation(continuing: continuation)
            }
        }
    }

    private func persist(_ conversation: Conversation) {
        guard !conversation.isTemporary, conversation.conversationReference != nil, !conversation.transcript.isEmpty else { return }
        enqueue(ConversationSaveRequest(payload: .conversation(conversation.state)))
    }

    private func persist(_ meta: ConversationMeta) {
        enqueue(ConversationSaveRequest(payload: .metadata(meta)))
    }

    private func enqueue(_ request: ConversationSaveRequest) {
        let id = request.conversationID
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

    private func debounce(_ id: ConversationID, _ request: ConversationSaveRequest) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNs)
            guard !Task.isCancelled else { return }
            self?.beginSave(id, expected: request.saveID)
        }
    }

    private func beginSave(_ id: ConversationID, expected saveID: SaveID) {
        guard var record = records[id],
              case .debouncing(let request, _) = record.persistence,
              request.saveID == saveID else { return }
        launch(request, in: &record)
        records[id] = record
    }

    private func launch(_ request: ConversationSaveRequest, in record: inout Record) {
        let scopedRepository = repository
        let storageScope = repositoryScope
        let worker = Task { await scopedRepository.saveConversation(request, in: storageScope) }
        record.persistence = .saving(request, nil, worker)
        Task { [weak self] in
            let result = await worker.value
            self?.complete(request.conversationID, result: result, storageScope: storageScope)
        }
    }

    private func complete(_ id: ConversationID, result: ConversationSaveReceipt, storageScope: ProfileScope) {
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
        let pending = records.compactMap { id, record -> (ConversationID, SaveID)? in
            if case .debouncing(let request, let task) = record.persistence {
                task.cancel()
                return (id, request.saveID)
            }
            return nil
        }
        for (id, saveID) in pending { beginSave(id, expected: saveID) }
    }

    private func setCurrent(_ conversation: Conversation) {
        let id = ConversationID(conversation.id)
        touch(id)
        if case .active(let current) = selection, current === conversation { return }
        let outgoing = current
        selection = .active(conversation)
        conversation.select()
        outgoing?.deselect()
        if let outgoing, outgoing.isTemporary {
            discardTemporary(ConversationID(outgoing.id))
        }
        trimHydrated()
    }

    private func touch(_ id: ConversationID) {
        guard var record = records[id] else { return }
        hydrationOrdinal &+= 1
        record.accessOrdinal = hydrationOrdinal
        records[id] = record
    }

    private func trimHydrated() {
        while records.values.compactMap({ $0.hydration.conversation }).count > Self.maxHydratedConversations {
            guard let candidate = records
                .filter({ $0.key.rawValue != currentId && $0.value.hydration.conversation?.isBusy == false })
                .min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal }) else {
                Log.session.warning("ConversationManager.evict deferred loaded=\(records.values.compactMap { $0.hydration.conversation }.count)")
                return
            }
            let id = candidate.key
            var record = candidate.value
            guard !record.persistence.isDirty, let conversation = record.hydration.conversation else {
                if case .debouncing(let request, let task) = record.persistence {
                    task.cancel()
                    beginSave(id, expected: request.saveID)
                }
                return
            }
            let meta = conversation.metadata
            conversation.release(cancelling: false)
            record.hydration = .unloaded(meta)
            records[id] = record
            Log.session.info("ConversationManager.evict id=\(id)")
        }
    }

}
