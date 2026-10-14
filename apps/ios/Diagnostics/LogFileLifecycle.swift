import UIKit

nonisolated extension LogFile {
    static var flushNotifications: [Notification.Name] {
        [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification]
    }
}
