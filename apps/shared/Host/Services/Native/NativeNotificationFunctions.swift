import Foundation

extension NativeServiceOperations {
    public func scheduleNotification(options: JSONValue?, purpose: String?) async throws -> JSONValue? {
        let opts = options?.objectValue ?? [:]
        guard let title = opts["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            throw RuntimeError.bridge("ios:notifications:schedule: 'title' is required.")
        }
        let scheduled = try await NotificationProvider.shared.schedule(
            title: title,
            body: opts["body"]?.stringValue,
            fireAt: opts["fireAt"]?.stringValue,
            inSeconds: opts["inSeconds"]?.doubleValue
        )
        Log.session.info("bridge.notification.schedule id=\(scheduled.id) fireAt=\(scheduled.fireAt)")
        return try ServiceOperations.encodeToJSON(scheduled)
    }

    public func cancelNotification(id: String?) async throws -> JSONValue? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw RuntimeError.bridge("ios:notifications:cancel: 'id' is required.")
        }
        Log.session.info("bridge.notification.cancel id=\(id)")
        NotificationProvider.shared.cancel(id: id)
        return .null
    }
}
