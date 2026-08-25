import AppIntents
import Foundation

struct ContinueOxChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Ox Chat"
    static let description = IntentDescription("Continue an Ox chat and return its response, continuing in the app if it needs more time.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Chat", requestValueDialog: "Which Ox chat would you like to continue?")
    var chat: OxChatEntity

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask next?")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Continue \(\.$chat) with \(\.$prompt)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let budget = OxIntentBudget()
        let client = try await OxIntentSupport.readyClient()
        let question = try OxIntentSupport.prompt(prompt)
        Log.app.info("ContinueOxChatIntent start chat=\(chat.id) chars=\(question.count)")
        let completion = await OxIntentSupport.waitForCompletion(
            budget: budget,
            chat: {
                guard client.chats.currentId == chat.id else { return nil }
                return client.chats.current
            },
            interaction: { try await requestOxInput($0) }
        ) {
            await client.chats.continueAndWait(
                chat.id,
                prompt: question,
                replyStyle: .spokenBrief
            )
        }
        let result = try await OxIntentSupport.response(from: completion)
        Log.app.info("ContinueOxChatIntent completed chat=\(chat.id) mode=\(completion.logLabel) chars=\(result.value.count)")
        return .result(value: result.value, dialog: "\(result.spoken)")
    }
}
