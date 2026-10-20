import Foundation

extension Conversation {
    func createSchedule(options: JSONValue, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.scheduleCreate, options, purpose: purpose) {
            try requireProfileMutation(Actions.scheduleCreate)
            guard let fields = options.objectValue,
                  let name = fields["name"]?.stringValue,
                  let prompt = fields["prompt"]?.stringValue,
                  let frequency = fields["frequency"]?.stringValue else { throw ScheduleError.invalidSchedule }
            let recurrence = try scheduledRecurrence(
                frequency: frequency, fireAt: fields["fireAt"]?.stringValue,
                hour: fields["hour"]?.intValue, minute: fields["minute"]?.intValue,
                weekday: fields["weekday"]?.stringValue, timeZone: fields["timeZone"]?.stringValue,
                intervalSeconds: fields["intervalSeconds"]?.intValue
            )
            let deadline: Date?
            if let value = fields["deadline"]?.stringValue {
                guard let parsed = ISODate.parse(value) else { throw ScheduleError.invalidSchedule }
                deadline = parsed
            } else { deadline = nil }
            let services = fields["services"]?.arrayValue?.compactMap(\.stringValue) ?? []
            try serviceManager.requireServices(domains: services)
            let schedule = try await Schedules.shared.create(
                name: name, prompt: prompt, services: services,
                condition: fields["condition"]?.stringValue, deadline: deadline,
                conversationID: fields["conversation"]?.stringValue == "current" ? id : nil,
                recurrence: recurrence, profileID: scope.profileID
            )
            Log.session.info("bridge.schedule.create id=\(schedule.id) frequency=\(frequency) conditional=\(schedule.condition != nil)")
            return scheduleResult(schedule)
        }
    }

    func completeSchedule(purpose: String) async throws -> JSONValue? {
        guard let run = Schedules.shared.run(in: id) else { throw RuntimeError.bridge("Only an active scheduled check can complete its own schedule.") }
        return try await tracked(Actions.scheduleComplete, .object(["id": .string(run.id.uuidString)]), purpose: purpose) {
            try requireProfileMutation(Actions.scheduleComplete)
            try await Schedules.shared.complete(id: run.id, token: run.token)
            return .object(["id": .string(run.id.uuidString), "completed": .bool(true)])
        }
    }

    func listSchedules(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.scheduleList, .object([:]), purpose: purpose) {
            .array(Schedules.shared.schedules(profileID: scope.profileID).map(scheduleResult))
        }
    }

    func deleteSchedule(id: String, purpose: String) async throws -> JSONValue? {
        let schedule = try ownedSchedule(id)
        return try await tracked(Actions.scheduleDelete, .object(["id": .string(id)]), purpose: purpose) {
            try requireProfileMutation(Actions.scheduleDelete)
            try await Schedules.shared.delete(id: schedule.id)
            Log.session.info("bridge.schedule.delete id=\(schedule.id) skill=\(schedule.name)")
            return .object(["id": .string(id), "deleted": .bool(true)])
        }
    }

    func enableSchedule(id: String, enabled: Bool, purpose: String) async throws -> JSONValue? {
        let schedule = try ownedSchedule(id)
        return try await tracked(
            Actions.scheduleEnable,
            .object(["id": .string(id), "enabled": .bool(enabled)]),
            purpose: purpose
        ) {
            try requireProfileMutation(Actions.scheduleEnable)
            if enabled { try serviceManager.requireServices(domains: schedule.services) }
            try await Schedules.shared.setEnabled(enabled, id: schedule.id)
            guard let updated = Schedules.shared.schedule(id: schedule.id) else {
                throw ScheduleError.missing(schedule.id)
            }
            return scheduleResult(updated)
        }
    }

    func runSchedule(id: String, purpose: String) async throws -> JSONValue? {
        let schedule = try ownedSchedule(id)
        return try await tracked(Actions.scheduleRun, .object(["id": .string(id)]), purpose: purpose) {
            try requireProfileMutation(Actions.scheduleRun)
            try serviceManager.requireServices(domains: schedule.services)
            try await ScheduleScheduler.shared.runNow(id: schedule.id)
            return .object(["id": .string(id), "started": .bool(true)])
        }
    }

    private func ownedSchedule(_ rawID: String) throws -> Schedule {
        guard let id = UUID(uuidString: rawID),
              let schedule = Schedules.shared.schedule(id: id),
              schedule.profileID == scope.profileID else {
            throw RuntimeError.bridge("No schedule with id '\(rawID)' exists in this Profile.")
        }
        return schedule
    }

    private func scheduledRecurrence(
        frequency: String,
        fireAt: String?,
        hour: Int?,
        minute: Int?,
        weekday: String?,
        timeZone: String?,
        intervalSeconds: Int?
    ) throws -> ScheduleRecurrence {
        switch frequency {
        case "interval":
            guard let intervalSeconds else { throw ScheduleError.invalidRecurrence }
            return .interval(seconds: intervalSeconds)
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
            throw RuntimeError.bridge("ox.schedule.create: frequency must be once, interval, daily, or weekly.")
        }
    }

    private func scheduleResult(_ schedule: Schedule) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(schedule.id.uuidString),
            "name": .string(schedule.name),
            "prompt": .string(schedule.prompt),
            "status": .string(schedule.status),
            "enabled": .bool(schedule.isEnabled),
            "recurrence": .string(schedule.recurrence.summary),
        ]
        if let condition = schedule.condition { result["condition"] = .string(condition) }
        if let deadline = schedule.deadline { result["deadline"] = .string(ISODate.string(from: deadline)) }
        if let conversationID = schedule.conversationID { result["conversationId"] = .string(conversationID.uuidString) }
        if let nextFireAt = schedule.nextFireAt {
            result["nextFireAt"] = .string(ISODate.string(from: nextFireAt))
        }
        if let lastRunAt = schedule.lastRunAt {
            result["lastRunAt"] = .string(ISODate.string(from: lastRunAt))
        }
        if let outcome = schedule.lastOutcome {
            switch outcome {
            case .succeeded: result["lastOutcome"] = .string("succeeded")
            case .cancelled: result["lastOutcome"] = .string("cancelled")
            case .failed(let message):
                result["lastOutcome"] = .string("failed")
                result["lastError"] = .string(message)
            }
        }
        if let lastConversationID = schedule.lastConversationID {
            result["lastConversationId"] = .string(lastConversationID.uuidString)
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

nonisolated extension ScheduleRecurrence {
    var summary: String {
        switch self {
        case .interval(let seconds):
            "every \(seconds) seconds"
        case .once(let date):
            "once at \(ISODate.string(from: date))"
        case let .daily(hour, minute, timeZone):
            "daily at \(String(format: "%02d:%02d", hour, minute)) \(timeZone)"
        case let .weekly(weekday, hour, minute, timeZone):
            "weekly on weekday \(weekday) at \(String(format: "%02d:%02d", hour, minute)) \(timeZone)"
        }
    }
}
