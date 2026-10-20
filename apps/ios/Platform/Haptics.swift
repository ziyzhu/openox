import UIKit

enum Haptics {
    enum Event: String {
        case agentDeltaReceived
        case copy
        case fileSaveFailed
        case fileSaved
        case holdToTalkHint
        case modelSelected
        case requestAnswered
        case serviceAttached
        case sidebarSettled
        case speechActionChanged
        case speechCancelled
        case speechFailed
        case speechStarted
        case speechStopped
        case stop
    }

    private static let driver = Driver()

    static func prepareImpact() {
        driver.prepareImpact()
    }

    static func impact(_ event: Event) {
        Log.ui.debug("Haptics.impact event=\(event.rawValue)")
        switch event {
        case .agentDeltaReceived, .speechStarted, .speechStopped:
            driver.impact(.medium)
        default:
            driver.impact(.light)
        }
    }

    static func selection(_ event: Event) {
        Log.ui.debug("Haptics.selection event=\(event.rawValue)")
        driver.selection()
    }

    static func success(_ event: Event) {
        Log.ui.debug("Haptics.success event=\(event.rawValue)")
        driver.notify(.success)
    }

    static func error(_ event: Event) {
        Log.ui.debug("Haptics.error event=\(event.rawValue)")
        driver.notify(.error)
    }

    private final class Driver {
        private weak var view: UIView?
        private var lightImpactGenerator: UIImpactFeedbackGenerator?
        private var mediumImpactGenerator: UIImpactFeedbackGenerator?
        private var selectionGenerator: UISelectionFeedbackGenerator?
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

        func selection() {
            refresh()
            selectionGenerator?.selectionChanged()
            selectionGenerator?.prepare()
        }

        func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
            refresh()
            notificationGenerator?.notificationOccurred(type)
        }

        private func refresh() {
            guard let activeView else {
                view = nil
                lightImpactGenerator = nil
                mediumImpactGenerator = nil
                selectionGenerator = nil
                notificationGenerator = nil
                return
            }
            guard activeView !== view else { return }
            view = activeView
            lightImpactGenerator = UIImpactFeedbackGenerator(style: .light, view: activeView)
            mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium, view: activeView)
            selectionGenerator = UISelectionFeedbackGenerator(view: activeView)
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
