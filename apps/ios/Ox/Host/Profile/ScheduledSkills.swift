import Foundation
import Observation

nonisolated enum ScheduledSkillRecurrence: Codable, Equatable, Sendable {
    case once(Date)
    case daily(hour: Int, minute: Int, timeZone: String)
    case weekly(weekday: Int, hour: Int, minute: Int, timeZone: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case fireAt
        case hour
        case minute
        case weekday
        case timeZone
    }

    private enum Kind: String, Codable {
        case once
        case daily
        case weekly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
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
        case .once:
            return
        case let .daily(hour, minute, timeZone):
            guard (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZone) != nil else {
                throw ScheduledSkillError.invalidRecurrence
            }
        case let .weekly(weekday, hour, minute, timeZone):
            guard (1...7).contains(weekday), (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZone) != nil else {
                throw ScheduledSkillError.invalidRecurrence
            }
        }
    }

    func next(after date: Date) -> Date? {
        switch self {
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
        case .once: TimeZone.autoupdatingCurrent.identifier
        case .daily(_, _, let timeZone), .weekly(_, _, _, let timeZone): timeZone
        }
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .autoupdatingCurrent
        return calendar
    }
}

nonisolated enum ScheduledSkillRunOutcome: Codable, Equatable, Sendable {
    case succeeded
    case failed(String)
    case cancelled
}

nonisolated struct ScheduledSkill: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let profileID: UUID
    var skill: Skill
    var argument: String
    var recurrence: ScheduledSkillRecurrence
    var nextFireAt: Date?
    var isEnabled: Bool
    let createdAt: Date
    var lastRunAt: Date?
    var lastOutcome: ScheduledSkillRunOutcome?
    var lastChatID: UUID?

    var expandedIntent: String {
        UserSkillInvocation(skill: skill, argument: argument).expandedIntent
    }
}

nonisolated struct ScheduledSkillsDocument: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var schedules: [ScheduledSkill]

    init(schedules: [ScheduledSkill]) {
        version = Self.currentVersion
        self.schedules = schedules
    }

    func validated() throws -> Self {
        guard version == Self.currentVersion else { throw ScheduledSkillError.unsupportedVersion(version) }
        guard schedules.count <= ScheduledSkills.maximumCount else { throw ScheduledSkillError.tooMany }
        guard Set(schedules.map(\.id)).count == schedules.count else { throw ScheduledSkillError.duplicateID }
        for schedule in schedules {
            guard SkillFiles.isUserName(schedule.skill.name), schedule.profileID != UUID.zero else {
                throw ScheduledSkillError.invalidSchedule
            }
            guard schedule.argument.count <= ScheduledSkills.maximumArgumentCharacters else {
                throw ScheduledSkillError.argumentTooLong
            }
            if case .failed(let message) = schedule.lastOutcome,
               message.count > ScheduledSkills.maximumOutcomeCharacters {
                throw ScheduledSkillError.invalidSchedule
            }
            try schedule.recurrence.validate()
        }
        return self
    }
}

nonisolated enum ScheduledSkillError: LocalizedError, Sendable {
    case duplicateID
    case argumentTooLong
    case invalidRecurrence
    case invalidSchedule
    case missing(UUID)
    case noActiveProfile
    case noFutureOccurrence
    case tooMany
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .argumentTooLong: "Scheduled skill instructions are too long."
        case .duplicateID: "Scheduled skills contain duplicate identifiers."
        case .invalidRecurrence: "Choose a valid schedule time and time zone."
        case .invalidSchedule: "The scheduled skill is invalid."
        case .missing: "That scheduled skill no longer exists."
        case .noActiveProfile: "Open a Profile before scheduling a skill."
        case .noFutureOccurrence: "Choose a time in the future."
        case .tooMany: "Ox supports up to \(ScheduledSkills.maximumCount) scheduled skills on this device."
        case .unsupportedVersion(let version): "Scheduled skills use unsupported storage version \(version)."
        }
    }
}

nonisolated private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

@MainActor
@Observable
final class ScheduledSkills {
    static let shared = ScheduledSkills()
    nonisolated static let maximumCount = 100
    nonisolated static let maximumArgumentCharacters = 10_000
    nonisolated static let maximumOutcomeCharacters = 500

    private(set) var all: [ScheduledSkill] = []
    private(set) var isLoaded = false
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let url: URL

    private init(url: URL = AppStoragePaths.scheduledSkills) {
        self.url = url
    }

    func load() throws {
        guard !isLoaded else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            all = try decoder.decode(ScheduledSkillsDocument.self, from: Data(contentsOf: url)).validated().schedules
        }
        isLoaded = true
        Log.app.info("ScheduledSkills.load count=\(all.count)")
    }

    @discardableResult
    func create(
        skill: Skill,
        argument: String,
        recurrence: ScheduledSkillRecurrence,
        profileID: UUID?,
        now: Date = Date()
    ) throws -> ScheduledSkill {
        try requireLoaded()
        guard all.count < Self.maximumCount else { throw ScheduledSkillError.tooMany }
        guard let profileID else { throw ScheduledSkillError.noActiveProfile }
        guard SkillFiles.isUserName(skill.name) else { throw ScheduledSkillError.invalidSchedule }
        try recurrence.validate()
        guard let nextFireAt = recurrence.next(after: now) else { throw ScheduledSkillError.noFutureOccurrence }
        let argument = try normalizedArgument(argument)
        let schedule = ScheduledSkill(
            id: UUID(),
            profileID: profileID,
            skill: skill,
            argument: argument,
            recurrence: recurrence,
            nextFireAt: nextFireAt,
            isEnabled: true,
            createdAt: now
        )
        var updated = all
        updated.append(schedule)
        try save(updated, reason: "create", scheduleID: schedule.id)
        return schedule
    }

    @discardableResult
    func update(
        id: UUID,
        skill: Skill,
        argument: String,
        recurrence: ScheduledSkillRecurrence,
        now: Date = Date()
    ) throws -> ScheduledSkill {
        try requireLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduledSkillError.missing(id) }
        try recurrence.validate()
        guard let nextFireAt = recurrence.next(after: now) else { throw ScheduledSkillError.noFutureOccurrence }
        let argument = try normalizedArgument(argument)
        var updated = all
        updated[index].skill = skill
        updated[index].argument = argument
        updated[index].recurrence = recurrence
        updated[index].nextFireAt = nextFireAt
        updated[index].isEnabled = true
        try save(updated, reason: "update", scheduleID: id)
        return updated[index]
    }

    func delete(id: UUID) throws {
        try requireLoaded()
        guard all.contains(where: { $0.id == id }) else { throw ScheduledSkillError.missing(id) }
        let updated = all.filter { $0.id != id }
        try save(updated, reason: "delete", scheduleID: id)
    }

    func setEnabled(_ enabled: Bool, id: UUID, now: Date = Date()) throws {
        try requireLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduledSkillError.missing(id) }
        var updated = all
        updated[index].isEnabled = enabled
        if enabled, updated[index].nextFireAt == nil {
            guard let next = updated[index].recurrence.next(after: now) else { throw ScheduledSkillError.noFutureOccurrence }
            updated[index].nextFireAt = next
        }
        try save(updated, reason: enabled ? "enable" : "disable", scheduleID: id)
    }

    func schedules(profileID: UUID?) -> [ScheduledSkill] {
        guard let profileID else { return [] }
        return all.filter { $0.profileID == profileID }.sorted {
            ($0.nextFireAt ?? .distantFuture) < ($1.nextFireAt ?? .distantFuture)
        }
    }

    func schedule(id: UUID) -> ScheduledSkill? {
        all.first { $0.id == id }
    }

    func due(at date: Date) -> [ScheduledSkill] {
        all.filter { schedule in
            schedule.isEnabled && schedule.nextFireAt.map { $0 <= date } == true
        }.sorted { ($0.nextFireAt ?? .distantPast) < ($1.nextFireAt ?? .distantPast) }
    }

    func nextEnabledDate() -> Date? {
        all.compactMap { $0.isEnabled ? $0.nextFireAt : nil }.min()
    }

    func record(
        id: UUID,
        outcome: ScheduledSkillRunOutcome,
        chatID: UUID?,
        at date: Date = Date()
    ) throws {
        try requireLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduledSkillError.missing(id) }
        var updated = all
        updated[index].lastRunAt = date
        updated[index].lastOutcome = bounded(outcome)
        updated[index].lastChatID = chatID
        updated[index].nextFireAt = updated[index].recurrence.next(after: date)
        if updated[index].nextFireAt == nil { updated[index].isEnabled = false }
        try save(updated, reason: "run", scheduleID: id)
    }

    func fireNow(id: UUID, now: Date = Date()) throws {
        try requireLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw ScheduledSkillError.missing(id) }
        var updated = all
        updated[index].nextFireAt = now
        updated[index].isEnabled = true
        try save(updated, reason: "runNow", scheduleID: id)
    }

    private func requireLoaded() throws {
        if !isLoaded { try load() }
    }

    private func normalizedArgument(_ argument: String) throws -> String {
        let normalized = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= Self.maximumArgumentCharacters else { throw ScheduledSkillError.argumentTooLong }
        return normalized
    }

    private func bounded(_ outcome: ScheduledSkillRunOutcome) -> ScheduledSkillRunOutcome {
        switch outcome {
        case .succeeded: .succeeded
        case .cancelled: .cancelled
        case .failed(let message): .failed(String(message.prefix(Self.maximumOutcomeCharacters)))
        }
    }

    private func save(_ schedules: [ScheduledSkill], reason: String, scheduleID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(ScheduledSkillsDocument(schedules: schedules).validated())
        data.append(0x0A)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        all = schedules
        Log.app.info("ScheduledSkills.save reason=\(reason) id=\(scheduleID) count=\(schedules.count)")
        onChange?()
    }
}
