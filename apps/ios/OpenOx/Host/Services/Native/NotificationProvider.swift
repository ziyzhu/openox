import Foundation
import UserNotifications

@MainActor
final class NotificationProvider {
    static let shared = NotificationProvider()

    struct Scheduled: Encodable {
        let id: String
        let fireAt: String
    }

    enum NotifyError: LocalizedError {
        case denied
        case noTime
        case pastTime
        case badFireAt
        var errorDescription: String? {
            switch self {
            case .denied:
                return "Notifications are off for Ox. Ask the user to enable them in Settings › Notifications › Ox, then try again."
            case .noTime:
                return "Provide either 'inSeconds' (a positive number) or 'fireAt' (an ISO-8601 timestamp)."
            case .pastTime:
                return "The fire time is in the past; schedule a future time."
            case .badFireAt:
                return "'fireAt' must be an ISO-8601 timestamp, e.g. 2026-06-25T09:00:00Z."
            }
        }
    }

    private let center = UNUserNotificationCenter.current()
    private init() {}

    func schedule(title: String, body: String?, fireAt: String?, inSeconds: Double?) async throws -> Scheduled {
        let date = try Self.fireDate(fireAt: fireAt, inSeconds: inSeconds)
        try await ensureAuthorized()

        let content = UNMutableNotificationContent()
        content.title = title
        if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            content.body = body
        }
        content.sound = .default

        let id = UUID().uuidString
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        let iso = ISODate.string(from: date)
        Log.agent.info("notify.schedule id=\(id) inSeconds=\(Int(date.timeIntervalSinceNow)) fireAt=\(iso)")
        return Scheduled(id: id, fireAt: iso)
    }

    func deliverIfAuthorized(identifier: String, title: String, body: String) async throws -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return true
    }

    func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        Log.agent.info("notify.cancel id=\(id)")
    }

    private func ensureAuthorized() async throws {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return
        case .denied:
            Log.agent.info("notify.auth denied")
            throw NotifyError.denied
        case .notDetermined:
            Log.agent.info("notify.auth requesting")
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if !granted { throw NotifyError.denied }
        @unknown default:
            throw NotifyError.denied
        }
    }

    private static func fireDate(fireAt: String?, inSeconds: Double?) throws -> Date {
        if let inSeconds {
            guard inSeconds > 0 else { throw NotifyError.pastTime }
            return Date(timeIntervalSinceNow: inSeconds)
        }
        guard let fireAt = fireAt?.trimmingCharacters(in: .whitespacesAndNewlines), !fireAt.isEmpty else {
            throw NotifyError.noTime
        }
        guard let date = ISODate.parse(fireAt) else { throw NotifyError.badFireAt }
        guard date.timeIntervalSinceNow > 0 else { throw NotifyError.pastTime }
        return date
    }
}
