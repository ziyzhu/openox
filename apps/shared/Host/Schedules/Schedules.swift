import Foundation
import Observation

nonisolated enum ScheduleRecurrence: Codable, Equatable, Sendable {
    case interval(seconds: Int)
    case once(Date)
    case daily(hour: Int, minute: Int, timeZone: String)
    case weekly(weekday: Int, hour: Int, minute: Int, timeZone: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case seconds
        case fireAt
        case hour
        case minute
        case weekday
        case timeZone
    }

    private enum Kind: String, Codable {
        case interval
        case once
        case daily
        case weekly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .interval:
            self = .interval(seconds: try values.decode(Int.self, forKey: .seconds))
        case .once:
            self = .once(try values.decode(Date.self, forKey: .fireAt))
        case .daily:
            self = .daily(
                hour: try values.decode(Int.self, forKey: .hour),
                minute: try values.decode(Int.self, forKey: .minute),
                timeZone: try values.decode(String.self, forKey: .timeZone)
            )
        case .weekly:
            self = .weekly(
                weekday: try values.decode(Int.self, forKey: .weekday),
                hour: try values.decode(Int.self, forKey: .hour),
                minute: try values.decode(Int.self, forKey: .minute),
                timeZone: try values.decode(String.self, forKey: .timeZone)
            )
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try values.encode(Kind.interval, forKey: .type)
            try values.encode(seconds, forKey: .seconds)
        case .once(let fireAt):
            try values.encode(Kind.once, forKey: .type)
            try values.encode(fireAt, forKey: .fireAt)
        case let .daily(hour, minute, timeZone):
            try values.encode(Kind.daily, forKey: .type)
            try values.encode(hour, forKey: .hour)
            try values.encode(minute, forKey: .minute)
            try values.encode(timeZone, forKey: .timeZone)
        case let .weekly(weekday, hour, minute, timeZone):
            try values.encode(Kind.weekly, forKey: .type)
            try values.encode(weekday, forKey: .weekday)
            try values.encode(hour, forKey: .hour)
            try values.encode(minute, forKey: .minute)
            try values.encode(timeZone, forKey: .timeZone)
        }
    }

    func validate() throws {
        switch self {
        case .interval(let seconds):
            guard (30...31_536_000).contains(seconds) else { throw ScheduleError.invalidRecurrence }
        case .once:
            return
        case let .daily(hour, minute, timeZone):
            guard (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZone) != nil else {
                throw ScheduleError.invalidRecurrence
            }
        case let .weekly(weekday, hour, minute, timeZone):
            guard (1...7).contains(weekday), (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZone) != nil else {
                throw ScheduleError.invalidRecurrence
            }
        }
    }

    func next(after date: Date) -> Date? {
        switch self {
        case .interval(let seconds):
            return date.addingTimeInterval(TimeInterval(seconds))
        case .once(let fireAt):
            return fireAt > date ? fireAt : nil
        case let .daily(hour, minute, timeZone):
            return calendar(timeZone).nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        case let .weekly(weekday, hour, minute, timeZone):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            components.weekday = weekday
            return calendar(timeZone).nextDate(
                after: date,
                matching: components,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }
    }

    var timeZoneIdentifier: String {
        switch self {
        case .once, .interval: TimeZone.autoupdatingCurrent.identifier
        case .daily(_, _, let timeZone), .weekly(_, _, _, let timeZone): timeZone
        }
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .autoupdatingCurrent
        return calendar
    }
}

nonisolated enum ScheduleRunOutcome: Codable, Equatable, Sendable {
    case succeeded
    case failed(String)
    case cancelled
}

nonisolated enum ScheduleState: Codable, Equatable, Sendable {
    case active
    case running(UUID)
    case paused
    case completed
    case expired
}

nonisolated struct Schedule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    var name: String
    var prompt: String
    var services: [String]
    var legacyInvocation: UserSkillInvocation? = nil
    var condition: String?
    var deadline: Date?
    var conversationID: UUID?
    var recurrence: ScheduleRecurrence
    var nextFireAt: Date?
    var state: ScheduleState
    let createdAt: Date
    var lastRunAt: Date?
    var lastOutcome: ScheduleRunOutcome?
    var lastConversationID: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, profileID, name, prompt, services, legacyInvocation, condition, deadline, conversationID
        case recurrence, nextFireAt, state, createdAt, lastRunAt, lastOutcome
        case lastConversationID = "lastChatID"
    }

    var isEnabled: Bool {
        switch state {
        case .active, .running: true
        case .paused, .completed, .expired: false
        }
    }

    var status: String {
        switch state {
        case .active: "active"
        case .running: "running"
        case .paused: "paused"
        case .completed: "completed"
        case .expired: "expired"
        }
    }

    var expandedIntent: String {
        guard let condition else { return prompt }
        return """
        \(prompt)

        This is a scheduled condition check. Stop condition: \(condition)
        Check the condition now. If it is true, perform the requested final action and call ox.schedule.complete({ purpose: "Condition met" }).
        If it is false, finish this check without completing the schedule; Ox will check again later. Do not sleep or poll inside this run.
        """
    }
}

nonisolated extension Schedule {
    static func validated(_ schedules: [Schedule]) throws -> [Schedule] {
        guard schedules.count <= Schedules.maximumCount else { throw ScheduleError.tooMany }
        guard Set(schedules.map(\.id)).count == schedules.count else { throw ScheduleError.duplicateID }
        for schedule in schedules {
            guard schedule.profileID != UUID.zero,
                  !schedule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  schedule.name.count <= 500,
                  !schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (schedule.legacyInvocation != nil || schedule.prompt.count <= Schedules.maximumArgumentCharacters),
                  schedule.services.count <= 100,
                  schedule.services.allSatisfy({ !$0.isEmpty && $0.count <= 500 }),
                  schedule.condition.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 10_000 }) ?? true else {
                throw ScheduleError.invalidSchedule
            }
            switch schedule.state {
            case .active, .running:
                guard schedule.nextFireAt != nil else { throw ScheduleError.invalidSchedule }
            case .completed, .expired:
                guard schedule.nextFireAt == nil else { throw ScheduleError.invalidSchedule }
            case .paused: break
            }
            if schedule.condition != nil {
                guard schedule.recurrence.isRecurring, let deadline = schedule.deadline,
                      deadline > schedule.createdAt else { throw ScheduleError.invalidSchedule }
            }
            if case .failed(let message) = schedule.lastOutcome,
               message.count > Schedules.maximumOutcomeCharacters { throw ScheduleError.invalidSchedule }
            if let invocation = schedule.legacyInvocation { try SkillFiles.validate(invocation.skill) }
            try schedule.recurrence.validate()
        }
        return schedules
    }
}

nonisolated extension ScheduleRecurrence {
    var isRecurring: Bool {
        if case .once = self { return false }
        return true
    }
}

nonisolated enum ScheduleError: LocalizedError, Sendable {
    case duplicateID
    case argumentTooLong
    case invalidRecurrence
    case invalidSchedule
    case running
    case missing(UUID)
    case noActiveProfile
    case noFutureOccurrence
    case tooMany
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .argumentTooLong: "Schedule prompts are too long."
        case .duplicateID: "Schedules contain duplicate identifiers."
        case .invalidRecurrence: "Choose a valid schedule time and time zone."
        case .running: "Pause this schedule before editing or running it again."
        case .invalidSchedule: "The schedule is invalid."
        case .missing: "That schedule no longer exists."
        case .noActiveProfile: "Open a Profile before creating a schedule."
        case .noFutureOccurrence: "Choose a time in the future."
        case .tooMany: "Ox supports up to \(Schedules.maximumCount) schedules on this device."
        case .unsupportedVersion(let version): "Schedules use unsupported storage version \(version)."
        }
    }
}

nonisolated private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

@MainActor
@Observable
final class Schedules {
    static let shared = Schedules()
    nonisolated static let maximumCount = 100
    nonisolated static let maximumArgumentCharacters = 10_000
    nonisolated static let maximumOutcomeCharacters = 500

    private(set) var all: [Schedule] = []
    private(set) var preparation: StoragePreparation?
    var isLoaded: Bool { preparation == .ready }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var activeRuns: [UUID: (id: UUID, token: UUID)] = [:]
    @ObservationIgnored private var loadedScope: ProfileScope?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pendingMutation: Task<Void, Never>?
    @ObservationIgnored private var loading: (scope: ProfileScope, task: Task<JSONValue, Error>)?

    private init() {}

    func unload() {
        loading?.task.cancel()
        loading = nil
        loadedScope = nil
        all = []
        activeRuns = [:]
        preparation = nil
    }

    func load(retry: Bool = false) async throws {
        let scope = StorageRoot.shared.scope
        guard loadedScope != scope || !isLoaded else { return }
        if !retry, loadedScope == scope, let message = preparation?.failureMessage {
            throw StorageMigrationError.recoveryRequired(message)
        }
        guard scope.profileID != nil else {
            all = []
            loadedScope = scope
            preparation = .ready
            return
        }
        let task: Task<JSONValue, Error>
        if let pending = loading, pending.scope == scope { task = pending.task }
        else {
            if loadedScope != scope { all = []; preparation = nil }
            task = Task { @MainActor in try await ProfileMigrator.prepareSchedules(in: scope) }
            loading = (scope, task)
        }
        do {
            let result = try await task.value
            guard StorageRoot.shared.scope == scope else { throw CancellationError() }
            try publish(result, in: scope)
            var recovered = all
            let newHost = result.objectValue?["host"]?.stringValue != Device.hostID
            for index in recovered.indices {
                if case .running = recovered[index].state {
                    recovered[index].state = .paused
                    recovered[index].lastOutcome = .failed("The previous check was interrupted. Review its conversation before resuming.")
                } else if newHost, recovered[index].state == .active { recovered[index].state = .paused }
            }
            if recovered != all || newHost { try await save(recovered, reason: "recover", scheduleID: UUID.zero) }
            loading = nil
            Log.app.info("Schedules.load profile=\(scope.profileID?.uuidString ?? "none") count=\(all.count)")
        } catch {
            if StorageRoot.shared.scope == scope {
                loadedScope = scope
                preparation = .needsRecovery(error.localizedDescription)
                all = []
                loading = nil
            }
            Log.app.error("Schedules.load needsRecovery=true sourcePreserved=true error=\(error.localizedDescription)")
            throw error
        }
    }

    private func publish(_ value: JSONValue, in scope: ProfileScope) throws {
        guard let fields = value.objectValue, let revision = fields["revision"]?.intValue,
              let records = fields["records"]?.objectValue else { throw ScheduleError.invalidSchedule }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let schedules = try records.map { key, value in
            let schedule = try decoder.decode(Schedule.self, from: Data(value.jsonString().utf8))
            guard schedule.id.uuidString == key.uppercased(), schedule.profileID == scope.profileID else {
                throw ScheduleError.invalidSchedule
            }
            return schedule
        }
        all = try Schedule.validated(schedules)
        self.revision = revision
        loadedScope = scope
        preparation = .ready
    }

    @discardableResult
    func create(
        name: String,
        prompt: String,
        services: [String] = [],
        condition: String? = nil,
        deadline: Date? = nil,
        conversationID: UUID? = nil,
        recurrence: ScheduleRecurrence,
        profileID: UUID?,
        now: Date = Date()
    ) async throws -> Schedule {
        return try await mutate { [self] in
            try await requireLoaded()
            guard all.count < Self.maximumCount else { throw ScheduleError.tooMany }
            guard let profileID else { throw ScheduleError.noActiveProfile }
            try recurrence.validate()
            guard let next = recurrence.next(after: now), deadline.map({ $0 > next }) ?? true else {
                throw ScheduleError.noFutureOccurrence
            }
            let schedule = Schedule(
                id: UUID(), profileID: profileID,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                services: services, condition: condition, deadline: deadline, conversationID: conversationID,
                recurrence: recurrence, nextFireAt: next, state: .active, createdAt: now
            )
            try await save(all + [schedule], reason: "create", scheduleID: schedule.id)
            return schedule
        }
    }

    @discardableResult
    func update(
        id: UUID,
        name: String,
        prompt: String,
        condition: String?,
        deadline: Date?,
        recurrence: ScheduleRecurrence,
        now: Date = Date()
    ) async throws -> Schedule {
        return try await mutate { [self] in
            try await requireLoaded()
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduleError.missing(id) }
            guard case .running = all[index].state else {
                try recurrence.validate()
                guard let next = recurrence.next(after: now), deadline.map({ $0 > next }) ?? true else {
                    throw ScheduleError.noFutureOccurrence
                }
                var updated = all
                updated[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                updated[index].prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if updated[index].prompt != all[index].prompt { updated[index].legacyInvocation = nil }
                updated[index].condition = condition
                updated[index].deadline = deadline
                updated[index].recurrence = recurrence
                updated[index].nextFireAt = next
                updated[index].state = all[index].state == .paused ? .paused : .active
                try await save(updated, reason: "update", scheduleID: id)
                return updated[index]
            }
            throw ScheduleError.running
        }
    }

    func delete(id: UUID) async throws {
        return try await mutate { [self] in
            try await requireLoaded()
            guard all.contains(where: { $0.id == id }) else { throw ScheduleError.missing(id) }
            let updated = all.filter { $0.id != id }
            try await save(updated, reason: "delete", scheduleID: id)
        }
    }

    func setEnabled(_ enabled: Bool, id: UUID, now: Date = Date()) async throws {
        return try await mutate { [self] in
            try await requireLoaded()
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduleError.missing(id) }
            if enabled, case .running = all[index].state { return }
            var updated = all
            if enabled {
                guard updated[index].deadline.map({ $0 > now }) ?? true else { throw ScheduleError.noFutureOccurrence }
                guard let next = updated[index].recurrence.next(after: now) else { throw ScheduleError.noFutureOccurrence }
                updated[index].nextFireAt = next
            }
            updated[index].state = enabled ? .active : .paused
            try await save(updated, reason: enabled ? "enable" : "disable", scheduleID: id)
        }
    }

    func schedules(profileID: UUID?) -> [Schedule] {
        guard let profileID else { return [] }
        return all.filter { $0.profileID == profileID }.sorted {
            ($0.nextFireAt ?? .distantFuture) < ($1.nextFireAt ?? .distantFuture)
        }
    }

    func schedule(id: UUID) -> Schedule? {
        all.first { $0.id == id }
    }

    func due(at date: Date) -> [Schedule] {
        guard isLoaded else { return [] }
        return all.filter { schedule in
            schedule.state == .active && schedule.profileID == StorageRoot.shared.activeId
                && schedule.deadline.map { $0 > date } != false
                && schedule.nextFireAt.map { $0 <= date } == true
        }.sorted { ($0.nextFireAt ?? .distantPast) < ($1.nextFireAt ?? .distantPast) }
    }

    func nextEnabledDate() -> Date? {
        guard isLoaded else { return nil }
        return all.filter { $0.profileID == StorageRoot.shared.activeId }.compactMap { schedule -> Date? in
            guard schedule.isEnabled else { return nil }
            if case .running = schedule.state { return schedule.deadline }
            return [schedule.nextFireAt, schedule.deadline].compactMap { $0 }.min()
        }.min()
    }

    func claim(id: UUID, now: Date = Date()) async throws -> UUID {
        return try await mutate { [self] in
            try await requireLoaded()
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].state == .active,
                  all[index].deadline.map({ $0 > now }) ?? true else { throw ScheduleError.missing(id) }
            let token = UUID()
            var updated = all
            updated[index].state = .running(token)
            updated[index].lastConversationID = nil
            try await save(updated, reason: "claim", scheduleID: id)
            return token
        }
    }

    func run(in conversationID: UUID) -> (id: UUID, token: UUID)? { activeRuns[conversationID] }

    func bind(id: UUID, token: UUID, conversationID: UUID) async throws {
        return try await mutate { [self] in
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].state == .running(token),
                  activeRuns[conversationID] == nil else { throw ScheduleError.invalidSchedule }
            var updated = all
            updated[index].lastConversationID = conversationID
            try await save(updated, reason: "conversation", scheduleID: id)
            activeRuns[conversationID] = (id, token)
        }
    }

    func unbind(conversationID: UUID, token: UUID) {
        if activeRuns[conversationID]?.token == token { activeRuns.removeValue(forKey: conversationID) }
    }

    func complete(id: UUID, token: UUID) async throws {
        return try await mutate { [self] in
            try await requireLoaded()
            guard let index = all.firstIndex(where: { $0.id == id }), all[index].state == .running(token),
                  all[index].condition != nil, all[index].deadline.map({ $0 > Date() }) ?? true else {
                throw ScheduleError.invalidSchedule
            }
            var updated = all
            updated[index].state = .completed
            updated[index].nextFireAt = nil
            try await save(updated, reason: "conditionMet", scheduleID: id)
        }
    }

    func record(id: UUID, token: UUID, outcome: ScheduleRunOutcome, conversationID: UUID?, at date: Date = Date()) async throws {
        return try await mutate { [self] in
            try await requireLoaded()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            var updated = all
            updated[index].lastRunAt = date
            updated[index].lastOutcome = bounded(outcome)
            updated[index].lastConversationID = conversationID
            if updated[index].state == .running(token) {
                if case .once = updated[index].recurrence { updated[index].nextFireAt = nil }
                else { updated[index].nextFireAt = updated[index].recurrence.next(after: date) }
                updated[index].state = updated[index].nextFireAt == nil ? .completed : .active
                if case .cancelled = outcome { updated[index].state = .paused }
                if case .failed = outcome { updated[index].state = .paused }
            }
            if updated[index].deadline.map({ $0 <= date }) == true, updated[index].state != .completed {
                updated[index].state = .expired
                updated[index].nextFireAt = nil
            }
            try await save(updated, reason: "run", scheduleID: id)
        }
    }

    func expire(at date: Date = Date()) async throws {
        return try await mutate { [self] in
            try await requireLoaded()
            var updated = all
            for index in updated.indices where updated[index].isEnabled && updated[index].deadline.map({ $0 <= date }) == true {
                updated[index].state = .expired
                updated[index].nextFireAt = nil
            }
            if updated != all { try await save(updated, reason: "deadline", scheduleID: UUID.zero) }
        }
    }

    func fireNow(id: UUID, now: Date = Date()) async throws {
        return try await mutate { [self] in
            try await requireLoaded()
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduleError.missing(id) }
            if case .running = all[index].state { throw ScheduleError.running }
            guard all[index].deadline.map({ $0 > now }) ?? true else { throw ScheduleError.noFutureOccurrence }
            var updated = all
            updated[index].nextFireAt = now
            updated[index].state = .active
            try await save(updated, reason: "runNow", scheduleID: id)
        }
    }

    private func mutate<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = pendingMutation
        let scope = StorageRoot.shared.scope
        let task = Task { @MainActor in
            await previous?.value
            guard StorageRoot.shared.scope == scope else { throw CancellationError() }
            return try await operation()
        }
        pendingMutation = Task { _ = try? await task.value }
        return try await task.value
    }

    private func requireLoaded() async throws {
        if !isLoaded || loadedScope != StorageRoot.shared.scope { try await load() }
    }

    private func bounded(_ outcome: ScheduleRunOutcome) -> ScheduleRunOutcome {
        switch outcome {
        case .succeeded: .succeeded
        case .cancelled: .cancelled
        case .failed(let message): .failed(String(message.prefix(Self.maximumOutcomeCharacters)))
        }
    }

    private func save(_ schedules: [Schedule], reason: String, scheduleID: UUID) async throws {
        _ = try Schedule.validated(schedules)
        guard let scope = loadedScope, scope == StorageRoot.shared.scope, scope.profileID != nil else {
            throw ScheduleError.noActiveProfile
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let records = try schedules.reduce(into: [String: JSONValue]()) { records, schedule in
            guard schedule.profileID == scope.profileID else { throw ScheduleError.invalidSchedule }
            records[schedule.id.uuidString] = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(schedule))
        }
        let result: JSONValue
        do {
            result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
                "action": .string("schedulesReplace"), "revision": .int(revision),
                "records": .object(records), "host": .string(Device.hostID),
            ]))
        } catch {
            if loadedScope == scope { preparation = .needsRecovery(error.localizedDescription) }
            throw error
        }
        guard loadedScope == scope, StorageRoot.shared.scope == scope else { throw CancellationError() }
        try publish(result, in: scope)
        Log.app.info("Schedules.save reason=\(reason) profile=\(scope.profileID?.uuidString ?? "none") id=\(scheduleID) count=\(schedules.count) revision=\(revision)")
        onChange?()
    }
}
