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
    case location
    case notifications
    case calendar
    case reminders
    case contacts
    case health

    func state() async -> NativePermissionState {
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
        case .health:
            switch await HealthProvider.shared.authorizationRequestState() {
            case .unavailable: return .denied
            case .shouldRequest: return .notDetermined
            case .unnecessary: return .granted
            }
        }
    }

    func request() async -> NativePermissionState {
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
        case .health:
            do {
                try await HealthProvider.shared.requestAccess()
            } catch {
                Log.ui.error("IOSService.permission health request failed \(error.localizedDescription)")
            }
        }
        return await state()
    }

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
}
