import UIKit

enum Haptics {
    enum Event: String {
        case attachmentChoice
        case attachmentMenu
        case agentDeltaReceived
        case artifactTabSelected
        case chatOpened
        case copy
        case editStarted
        case permissionPersistenceToggled
        case queuedMessageCancelled
        case selectionConfirmed
        case send
        case speechStarted
        case speechStopped
        case serviceAttached
        case settingsSaved
        case sidebarSettled
        case stop
        case userActionNeeded
    }

    private static let driver = Driver()

    static func prepareImpact() {
        driver.prepareImpact()
    }

    static func impact(_ event: Event) {
        Log.ui.debug("Haptics.impact event=\(event.rawValue)")
        switch event {
        case .agentDeltaReceived, .artifactTabSelected, .chatOpened, .sidebarSettled, .userActionNeeded:
            driver.impact(.medium)
        default:
            driver.impact(.light)
        }
    }

    static func success(_ event: Event) {
        Log.ui.debug("Haptics.success event=\(event.rawValue)")
        driver.success()
    }

    private final class Driver {
        private weak var view: UIView?
        private var lightImpactGenerator: UIImpactFeedbackGenerator?
        private var mediumImpactGenerator: UIImpactFeedbackGenerator?
        private var notificationGenerator: UINotificationFeedbackGenerator?

        func prepareImpact() {
            refresh()
            lightImpactGenerator?.prepare()
        }

        func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
            refresh()
            let generator = style == .medium ? mediumImpactGenerator : lightImpactGenerator
            generator?.impactOccurred()
            generator?.prepare()
        }

        func success() {
            refresh()
            notificationGenerator?.notificationOccurred(.success)
            notificationGenerator?.prepare()
        }

        private func refresh() {
            guard let activeView else {
                view = nil
                lightImpactGenerator = nil
                mediumImpactGenerator = nil
                notificationGenerator = nil
                return
            }
            guard activeView !== view else { return }
            view = activeView
            lightImpactGenerator = UIImpactFeedbackGenerator(style: .light, view: activeView)
            mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium, view: activeView)
            notificationGenerator = UINotificationFeedbackGenerator(view: activeView)
        }

        private var activeView: UIView? {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow?.rootViewController?.view
        }
    }
}
