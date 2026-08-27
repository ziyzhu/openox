import Foundation

extension Chat {
    func createScheduledSkill(
        skillName: String,
        argument: String?,
        frequency: String,
        fireAt: String?,
        hour: Int?,
        minute: Int?,
        weekday: String?,
        timeZone: String?,
        purpose: String
    ) async throws -> JSONValue? {
        let args = scheduleArgs(skillName: skillName, frequency: frequency)
        return try await tracked(.scheduleCreate, args, purpose: purpose) {
            try requireProfileMutation(.scheduleCreate)
            let skill = try await repository.skill(named: skillName, in: scope)
            let recurrence = try scheduledRecurrence(
                frequency: frequency,
                fireAt: fireAt,
                hour: hour,
                minute: minute,
                weekday: weekday,
                timeZone: timeZone
            )
            let next = recurrence.next(after: Date()).map(ISODate.string) ?? ""
            try await confirmScheduledSkillChange(
                action: L10n.string("Schedule"),
                prompt: "Schedule /\(skill.displayName) for \(next)? Future service actions will still use their normal approval policy."
            )
            let schedule = try ScheduledSkills.shared.create(
                skill: skill,
                argument: argument ?? "",
                recurrence: recurrence,
                profileID: scope.profileID
            )
            Log.session.info("bridge.schedule.create id=\(schedule.id) skill=\(skill.name)")
            return scheduleResult(schedule)
        }
    }

    func listScheduledSkills(purpose: String) async throws -> JSONValue? {
        try await tracked(.scheduleList, .object([:]), purpose: purpose) {
            .array(ScheduledSkills.shared.schedules(profileID: scope.profileID).map(scheduleResult))
        }
    }

    func deleteScheduledSkill(id: String, purpose: String) async throws -> JSONValue? {
        let schedule = try ownedSchedule(id)
        return try await tracked(.scheduleDelete, .object(["id": .string(id)]), purpose: purpose) {
            try requireProfileMutation(.scheduleDelete)
            try await confirmScheduledSkillChange(
                action: L10n.string("Delete Schedule"),
                prompt: "Delete the schedule for /\(schedule.skill.displayName)?"
            )
            try ScheduledSkills.shared.delete(id: schedule.id)
            Log.session.info("bridge.schedule.delete id=\(schedule.id) skill=\(schedule.skill.name)")
            return .object(["id": .string(id), "deleted": .bool(true)])
        }
    }

    func enableScheduledSkill(id: String, enabled: Bool, purpose: String) async throws -> JSONValue? {
        let schedule = try ownedSchedule(id)
        let verb = enabled ? L10n.string("Resume") : L10n.string("Pause")
        return try await tracked(
            .scheduleEnable,
            .object(["id": .string(id), "enabled": .bool(enabled)]),
            purpose: purpose
        ) {
            try requireProfileMutation(.scheduleEnable)
            try await confirmScheduledSkillChange(
                action: verb,
                prompt: "\(verb) the schedule for /\(schedule.skill.displayName)?"
            )
            try ScheduledSkills.shared.setEnabled(enabled, id: schedule.id)
            guard let updated = ScheduledSkills.shared.schedule(id: schedule.id) else {
                throw ScheduledSkillError.missing(schedule.id)
            }
            return scheduleResult(updated)
        }
    }

    func runScheduledSkill(id: String, purpose: String) async throws -> JSONValue? {
        let schedule = try ownedSchedule(id)
        return try await tracked(.scheduleRun, .object(["id": .string(id)]), purpose: purpose) {
            try requireProfileMutation(.scheduleRun)
            try await confirmScheduledSkillChange(
                action: L10n.string("Run Now"),
                prompt: "Run the scheduled snapshot of /\(schedule.skill.displayName) now?"
            )
            ScheduledSkillScheduler.shared.runNow(id: schedule.id)
            return .object(["id": .string(id), "started": .bool(true)])
        }
    }

    private func ownedSchedule(_ rawID: String) throws -> ScheduledSkill {
        guard let id = UUID(uuidString: rawID),
              let schedule = ScheduledSkills.shared.schedule(id: id),
              schedule.profileID == scope.profileID else {
            throw RuntimeError.bridge("No scheduled skill with id '\(rawID)' exists in this Profile.")
        }
        return schedule
    }

    private func scheduledRecurrence(
        frequency: String,
        fireAt: String?,
        hour: Int?,
        minute: Int?,
        weekday: String?,
        timeZone: String?
    ) throws -> ScheduledSkillRecurrence {
        switch frequency {
        case "once":
            guard let fireAt, let date = ISODate.parse(fireAt), date > Date() else {
                throw RuntimeError.bridge("ox.schedule.create: fireAt must be a future ISO-8601 timestamp for a one-time schedule.")
            }
            return .once(date)
        case "daily":
            guard let hour, let minute else {
                throw RuntimeError.bridge("ox.schedule.create: hour and minute are required for a daily schedule.")
            }
            return .daily(hour: hour, minute: minute, timeZone: timeZone ?? TimeZone.autoupdatingCurrent.identifier)
        case "weekly":
            guard let hour, let minute, let weekday, let weekdayNumber = Self.weekdays[weekday.lowercased()] else {
                throw RuntimeError.bridge("ox.schedule.create: weekday, hour, and minute are required for a weekly schedule.")
            }
            return .weekly(
                weekday: weekdayNumber,
                hour: hour,
                minute: minute,
                timeZone: timeZone ?? TimeZone.autoupdatingCurrent.identifier
            )
        default:
            throw RuntimeError.bridge("ox.schedule.create: frequency must be once, daily, or weekly.")
        }
    }

    private func scheduleArgs(skillName: String, frequency: String) -> JSONValue {
        .object(["skill": .string(skillName), "frequency": .string(frequency)])
    }

    private func scheduleResult(_ schedule: ScheduledSkill) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(schedule.id.uuidString),
            "skill": .string(schedule.skill.name),
            "argument": .string(schedule.argument),
            "enabled": .bool(schedule.isEnabled),
            "recurrence": .string(schedule.recurrence.summary),
        ]
        if let nextFireAt = schedule.nextFireAt {
            result["nextFireAt"] = .string(ISODate.string(from: nextFireAt))
        }
        if let lastRunAt = schedule.lastRunAt {
            result["lastRunAt"] = .string(ISODate.string(from: lastRunAt))
        }
        if let lastChatID = schedule.lastChatID {
            result["lastChatId"] = .string(lastChatID.uuidString)
        }
        return .object(result)
    }

    private static let weekdays = [
        "sunday": 1,
        "monday": 2,
        "tuesday": 3,
        "wednesday": 4,
        "thursday": 5,
        "friday": 6,
        "saturday": 7,
    ]
}

nonisolated extension ScheduledSkillRecurrence {
    var summary: String {
        switch self {
        case .once(let date):
            "once at \(ISODate.string(from: date))"
        case let .daily(hour, minute, timeZone):
            "daily at \(String(format: "%02d:%02d", hour, minute)) \(timeZone)"
        case let .weekly(weekday, hour, minute, timeZone):
            "weekly on weekday \(weekday) at \(String(format: "%02d:%02d", hour, minute)) \(timeZone)"
        }
    }
}
