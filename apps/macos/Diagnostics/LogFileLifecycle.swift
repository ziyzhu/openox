import AppKit

nonisolated extension LogFile {
    static var flushNotifications: [Notification.Name] {
        [NSApplication.willTerminateNotification]
    }
}
