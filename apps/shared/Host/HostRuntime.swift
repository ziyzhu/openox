import Foundation

@MainActor
final class HostRuntime: OxHost {
    private struct Preparation {
        let id: UUID
        let storage: Task<Void, Error>
        let profile: Task<Void, Error>
    }

    let services: ServiceManager
    let conversations: ConversationManager
    private(set) var state: HostState = .stopped
    var executionAvailable: Bool { executionPolicy() }

    private let executionPolicy: @MainActor () -> Bool
    private let activateSchedules: @MainActor () async throws -> Void
    private let deactivateSchedules: @MainActor () async -> Void
    private var preparation: Preparation?
    private var optionalRecovery: Task<Void, Never>?
    private var profileSummaryLoad: Task<Void, Never>?

    init(
        serviceManager: ServiceManager,
        presentations: AppPresentations,
        conversationExecution: any ConversationExecution,
        conversationFeedback: any ConversationFeedback,
        executionPolicy: @escaping @MainActor () -> Bool,
        activateSchedules: @escaping @MainActor () async throws -> Void,
        deactivateSchedules: @escaping @MainActor () async -> Void = {}
    ) {
        services = serviceManager
        self.executionPolicy = executionPolicy
        self.activateSchedules = activateSchedules
        self.deactivateSchedules = deactivateSchedules
        conversations = ConversationManager(
            repository: .shared,
            storage: .shared,
            providerRegistry: .shared,
            serviceManager: serviceManager,
            presentations: presentations,
            execution: conversationExecution,
            feedback: conversationFeedback
        )
        conversations.profilePreparation = { [weak self] in
            _ = try? await self?.preparation?.profile.value
        }
        StorageRoot.shared.beforeProfileChange = { [weak self] in
            guard let self else { return }
            guard !conversations.activities.values.contains(where: {
                if case .running = $0 { return true }
                return false
            }) else { throw RuntimeError.bridge("Stop running conversations before changing Profiles") }
            guard await conversations.flushAllNow() else { throw RuntimeError.bridge("Profile writes could not be flushed") }
            await deactivateSchedules()
            profileSummaryLoad?.cancel()
            await profileSummaryLoad?.value
            profileSummaryLoad = nil
        }
        StorageRoot.shared.profileDidChange = { [weak self] in
            try await self?.refreshProfile()
        }
    }

    deinit {
        optionalRecovery?.cancel()
        profileSummaryLoad?.cancel()
    }

    private func refreshProfile() async throws {
        let startedAt = Date()
        conversations.reset()
        Soul.shared.reload()
        UserMemory.shared.reload()
        await services.refreshServices(locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region), reuseApplicationRepositories: true)
        Skills.shared.refresh()
        conversations.startNewConversation()
        let scope = StorageRoot.shared.scope
        let conversations = conversations
        profileSummaryLoad = Task { @MainActor in
            guard !Task.isCancelled, StorageRoot.shared.scope == scope else { return }
            let startedAt = Date()
            await conversations.loadSummariesNow()
            Log.app.info("HostRuntime Profile summaries id=\(scope.profileID?.uuidString ?? "none") durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))")
        }
        await profileSummaryLoad?.value
        do { try await activateSchedules() }
        catch { Log.app.warning("HostRuntime schedules unavailable recoveryRequired=true error=\(error.localizedDescription)") }
        resumeOptionalStorageRecovery()
        Log.app.info("HostRuntime Profile changed id=\(StorageRoot.shared.activeId?.uuidString ?? "none") durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))")
    }

    func listConversations() async -> [HostConversationSummary] {
        await conversations.loadAllSummaries()
        return conversations.orderedSummaries.map { summary in
            HostConversationSummary(
                id: summary.id,
                title: summary.displayTitle,
                model: summary.modelID,
                createdAt: summary.createdAt,
                lastActivity: summary.lastActivity,
                active: summary.id == conversations.currentId
            )
        }
    }

    func prepareStorage() async throws {
        try await awaitPreparation(\.storage)
    }

    func prepare() async throws {
        try await awaitPreparation(\.profile)
    }

    func executionAvailabilityChanged() {
        if executionAvailable {
            resumeOptionalStorageRecovery()
        } else {
            optionalRecovery?.cancel()
        }
    }

    private func resumeOptionalStorageRecovery() {
        guard executionAvailable else { return }
        if let current = optionalRecovery {
            if current.isCancelled {
                Task {
                    await current.value
                    resumeOptionalStorageRecovery()
                }
            }
            return
        }
        guard let profile = preparation?.profile,
              services.localRecoveryMessage != nil || Schedules.shared.preparation?.failureMessage != nil else { return }
        optionalRecovery = Task { @MainActor in
            defer { optionalRecovery = nil }
            do {
                try await profile.value
                var delay: Double = 2
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(delay))
                    if await StorageMigrator.recoverOptionalStorage(services: services, activateSchedules: activateSchedules) { return }
                    delay = min(delay * 3, 300)
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("HostRuntime optionalRecovery blocked error=\(error.localizedDescription)")
            }
        }
    }

    private func awaitPreparation(_ stage: KeyPath<Preparation, Task<Void, Error>>) async throws {
        let current = preparation ?? beginPreparation()
        do {
            try await current[keyPath: stage].value
        } catch {
            if preparation?.profile == current.profile {
                preparation = nil
                state = .failed(error.localizedDescription)
                Log.app.error("HostRuntime preparation failed error=\(error.localizedDescription)")
            }
            throw error
        }
    }

    private func beginPreparation() -> Preparation {
        state = .preparing
        Log.app.info("HostRuntime preparing")
        let id = UUID()
        let services = services
        let conversations = conversations
        let storage = Task { @MainActor in
            do {
                try await StorageMigrator.prepare(storage: .shared, services: services)
                #if DEBUG && targetEnvironment(simulator)
                try await DeviceTemplate.applyStorage(services: services)
                #endif
                Log.app.info("HostRuntime storage prepared")
            } catch {
                #if DEBUG && targetEnvironment(simulator)
                DeviceTemplate.reportFailure(error)
                #endif
                throw error
            }
        }
        let profile = Task { @MainActor in
            do {
                try await storage.value
                #if DEBUG && targetEnvironment(simulator)
                if SimEnv.startupDelayMilliseconds > 0 {
                    Log.app.info("HostRuntime profile delayMs=\(SimEnv.startupDelayMilliseconds)")
                    try await Task.sleep(for: .milliseconds(SimEnv.startupDelayMilliseconds))
                }
                #endif
                await conversations.loadSummariesNow()
                _ = Soul.shared
                _ = UserMemory.shared
                try await UserMemory.shared.waitUntilCurrent()
                await services.refreshServices(locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region))
                do { try await activateSchedules() }
                catch { Log.app.warning("HostRuntime schedules unavailable recoveryRequired=true error=\(error.localizedDescription)") }
                #if DEBUG && targetEnvironment(simulator)
                try await DeviceTemplate.finish(conversations: conversations)
                #endif
                guard self.preparation?.id == id else { return }
                state = .running
                Log.app.info("HostRuntime profile prepared")
                Task { await ProviderRegistry.shared.refreshStaleModels() }
                resumeOptionalStorageRecovery()
            } catch {
                if self.preparation?.id == id {
                    state = .failed(error.localizedDescription)
                }
                throw error
            }
        }
        let preparation = Preparation(id: id, storage: storage, profile: profile)
        self.preparation = preparation
        return preparation
    }
}
