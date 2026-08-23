import Foundation

extension Chat {
    public func readHealthActivity(start: String?, end: String?, purpose: String?) async throws -> JSONValue? {
        try await readHealth(
            start: start,
            end: end,
            purpose: purpose,
            action: "health.activity",
            actionName: "ios:health:activity"
        ) { startDate, endDate in
            try Self.encodeToJSON(try await HealthProvider.shared.activity(start: startDate, end: endDate))
        }
    }

    public func readHealthSleep(start: String?, end: String?, purpose: String?) async throws -> JSONValue? {
        try await readHealth(
            start: start,
            end: end,
            purpose: purpose,
            action: "health.sleep.summary",
            actionName: "ios:health:sleep.summary"
        ) { startDate, endDate in
            try Self.encodeToJSON(try await HealthProvider.shared.sleep(start: startDate, end: endDate))
        }
    }

    public func readHealthWorkouts(start: String?, end: String?, purpose: String?) async throws -> JSONValue? {
        try await readHealth(
            start: start,
            end: end,
            purpose: purpose,
            action: "health.workouts.list",
            actionName: "ios:health:workouts.list"
        ) { startDate, endDate in
            try Self.encodeToJSON(try await HealthProvider.shared.workouts(start: startDate, end: endDate))
        }
    }

    public func readHealthVitals(start: String?, end: String?, purpose: String?) async throws -> JSONValue? {
        try await readHealth(
            start: start,
            end: end,
            purpose: purpose,
            action: "health.vitals.summary",
            actionName: "ios:health:vitals.summary"
        ) { startDate, endDate in
            try Self.encodeToJSON(try await HealthProvider.shared.vitals(start: startDate, end: endDate))
        }
    }

    public func readHealthBody(start: String?, end: String?, purpose: String?) async throws -> JSONValue? {
        try await readHealth(
            start: start,
            end: end,
            purpose: purpose,
            action: "health.body.summary",
            actionName: "ios:health:body.summary"
        ) { startDate, endDate in
            try Self.encodeToJSON(try await HealthProvider.shared.body(start: startDate, end: endDate))
        }
    }

    private func readHealth(
        start: String?,
        end: String?,
        purpose: String?,
        action: String,
        actionName: String,
        read: @escaping (Date, Date) async throws -> JSONValue
    ) async throws -> JSONValue? {
        try requireIOSService("ios:health")
        let request = try HealthReadRequest(
            start: start,
            end: end,
            purpose: purpose,
            action: action,
            actionName: actionName
        )
        return try await readPrivateData(
            request.privateDataRequest,
            action: request.action,
            args: request.args,
            purpose: purpose
        ) {
            try await read(request.start, request.end)
        }
    }
}
