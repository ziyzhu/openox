import Foundation

extension OxHost {
    func updateSchedule(id: UUID, name: String, prompt: String, condition: String?, deadline: Date?, recurrence: ScheduleRecurrence) async throws {
        let scope = StorageRoot.shared.scope
        try await prepare()
        guard scope == StorageRoot.shared.scope else { throw CancellationError() }
        _ = try activeSchedule(id)
        try await Schedules.shared.update(id: id, name: name, prompt: prompt, condition: condition, deadline: deadline, recurrence: recurrence)
    }

    func setScheduleEnabled(_ enabled: Bool, id: UUID) async throws {
        let scope = StorageRoot.shared.scope
        try await prepare()
        guard scope == StorageRoot.shared.scope else { throw CancellationError() }
        let schedule = try activeSchedule(id)
        if enabled { try services.requireServices(domains: schedule.services) }
        try await Schedules.shared.setEnabled(enabled, id: id)
    }

    func deleteSchedule(_ id: UUID) async throws {
        let scope = StorageRoot.shared.scope
        try await prepare()
        guard scope == StorageRoot.shared.scope else { throw CancellationError() }
        _ = try activeSchedule(id)
        try await Schedules.shared.delete(id: id)
    }

    private func activeSchedule(_ id: UUID) throws -> Schedule {
        guard let schedule = Schedules.shared.schedule(id: id),
              schedule.profileID == StorageRoot.shared.activeId else { throw ScheduleError.missing(id) }
        return schedule
    }
}
