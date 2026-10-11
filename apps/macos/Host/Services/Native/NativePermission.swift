import Foundation

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
        return .denied
    }

    func request() async -> NativePermissionState {
        return await state()
    }

}
