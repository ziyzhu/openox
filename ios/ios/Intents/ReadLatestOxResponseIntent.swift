import AppIntents
import Foundation

struct ReadLatestOxResponseIntent: AppIntent {
    static let title: LocalizedStringResource = "Read Latest Ox Response"
    static let description = IntentDescription("Return Ox's latest completed response.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let runtime = try await OxIntentSupport.readyRuntime()
        guard let response = await runtime.chatManager.latestCompletedResponse() else {
            let message = String(localized: "Ox doesn't have a completed response yet.")
            return .result(value: message, dialog: "\(message)")
        }
        let result = OxIntentSupport.renderedResponse(response)
        Log.app.info("ReadLatestOxResponseIntent completed chars=\(result.value.count) spokenChars=\(result.spoken.count)")
        return .result(value: result.value, dialog: "\(result.spoken)")
    }
}
