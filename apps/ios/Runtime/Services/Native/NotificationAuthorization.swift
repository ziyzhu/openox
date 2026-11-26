import UserNotifications

extension UNAuthorizationStatus {
    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied: false
        @unknown default: false
        }
    }
}
