import Foundation
#if os(iOS)
import Contacts
import CoreLocation
import EventKit
import UserNotifications
#endif

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
        #if os(iOS)
        switch self {
        case .contacts:
            return Self.map(CNContactStore.authorizationStatus(for: .contacts))
        case .location:
            return Self.map(CLLocationManager().authorizationStatus)
        case .calendar:
            return Self.map(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return Self.map(EKEventStore.authorizationStatus(for: .reminder))
        case .notifications:
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        case .bluetooth, .health: return .denied
        }
        #else
        return .denied
        #endif
    }

    func request() async -> NativePermissionState {
        #if os(iOS)
        switch self {
        case .location:
            await LocationProvider.shared.requestAccess()
        case .notifications:
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .calendar:
            await CalendarProvider.shared.requestEventsAccess()
        case .reminders:
            await CalendarProvider.shared.requestRemindersAccess()
        case .contacts:
            _ = await ContactsProvider.shared.authorized()
        case .bluetooth, .health: break
        }
        #endif
        return await state()
    }

    #if os(iOS)
    private static func map(_ status: CLAuthorizationStatus) -> NativePermissionState {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> NativePermissionState {
        switch status {
        case .fullAccess, .writeOnly: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    private static func map(_ status: CNAuthorizationStatus) -> NativePermissionState {
        switch status {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
    #endif
}
