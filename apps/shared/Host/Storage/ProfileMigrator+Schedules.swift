import Foundation

extension ProfileMigrator {
    @MainActor
    static func prepareSchedules(in scope: ProfileScope) async throws -> JSONValue {
        let current = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("schedulesRead")]))
        if current.objectValue?["legacyImported"]?.boolValue == true {
            _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("schedulesRecover")]))
            return current
        }
        let legacy = try ApplicationStorageMigrator.prepareLegacySchedules(at: AppStoragePaths.legacySchedules)
            .filter { $0.profileID == scope.profileID }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let records = try legacy.reduce(into: [String: JSONValue]()) { records, schedule in
            records[schedule.id.uuidString] = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(schedule))
        }
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("schedulesImport"), "records": .object(records), "host": .string(Device.hostID),
        ]))
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("schedulesRecover")]))
        Log.app.info("StorageMigrator.schedules imported profile=\(scope.profileID?.uuidString ?? "none") count=\(records.count) sourcePreserved=true")
        return result
    }
}
