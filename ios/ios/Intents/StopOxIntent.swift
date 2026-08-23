import AppIntents
import Foundation

struct StopOxIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Ox"
    static let description = IntentDescription("Stop Ox's active responses.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard UserDefaults.standard.bool(forKey: "app.hasCompletedOnboarding") else {
            throw OxIntentError.onboardingRequired
        }
        let count = OxRuntime.shared.chatManager.stopActiveResponses()
        if count == 0 {
            return .result(value: false, dialog: "Ox isn't responding right now.")
        }
        Log.app.info("StopOxIntent stopped count=\(count)")
        return .result(value: true, dialog: "Stopped Ox.")
    }
}
