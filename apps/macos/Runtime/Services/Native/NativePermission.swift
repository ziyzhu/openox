import Contacts
import CoreLocation
import EventKit
import Foundation
import UserNotifications

enum NativePermissionState: Equatable {
    case granted
    case denied
    case notDetermined
}

enum NativePermission: String, Decodable, Equatable, Sendable {
    case bluetooth
    case location
    case notifications
    case calendar
    case reminders
    case contacts
    case health

    func state() async -> NativePermissionState {
        switch self {
        case .contacts:
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized, .limited: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .calendar, .reminders:
            switch EKEventStore.authorizationStatus(for: self == .calendar ? .event : .reminder) {
            case .fullAccess: return .granted
            case .writeOnly: return self == .calendar ? .granted : .denied
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .bluetooth, .health: return .denied
        }
    }

    func request() async -> NativePermissionState {
        switch self {
        case .contacts: _ = await ContactsProvider.shared.authorized()
        case .calendar: await CalendarProvider.shared.requestEventsAccess()
        case .reminders: await CalendarProvider.shared.requestRemindersAccess()
        case .location: await LocationProvider.shared.requestAccess()
        case .notifications:
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.service.error("NativePermission.request permission=\(rawValue) error=\(error.localizedDescription)")
            }
        case .bluetooth, .health: break
        }
        return await state()
    }
}
