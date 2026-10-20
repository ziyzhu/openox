import Foundation

extension OxHost {
    func setScheduleEnabled(_ enabled: Bool, id: UUID) async throws {
        try await prepare()
        let schedule = try activeSchedule(id)
        if enabled { try services.requireServices(domains: schedule.skill.services) }
        try ScheduledSkills.shared.setEnabled(enabled, id: id)
    }

    func deleteSchedule(_ id: UUID) async throws {
        try await prepare()
        _ = try activeSchedule(id)
        try ScheduledSkills.shared.delete(id: id)
    }

    private func activeSchedule(_ id: UUID) throws -> ScheduledSkill {
        guard let schedule = ScheduledSkills.shared.schedule(id: id),
              schedule.profileID == StorageRoot.shared.activeId else { throw ScheduledSkillError.missing(id) }
        return schedule
    }
}
