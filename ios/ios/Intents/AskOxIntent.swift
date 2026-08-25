import AppIntents
import Foundation

struct AskOxIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Ox"
    static let description = IntentDescription("Start an Ox chat and return its response, continuing in the app if it needs more time.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @Parameter(
        title: "Question",
        requestValueDialog: "What would you like to ask Ox?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Ox \(\.$prompt)")
    }

    init() {}

    init(prompt: String) {
        self.prompt = prompt
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let budget = OxIntentBudget()
        let client = try await OxIntentSupport.readyClient()
        let question = try OxIntentSupport.prompt(prompt)
        let chat = client.chats.startNewChat()
        Log.app.info("AskOxIntent start chars=\(question.count)")
        let completion = await OxIntentSupport.waitForCompletion(
            budget: budget,
            chat: { chat },
            interaction: { try await requestOxInput($0) }
        ) {
            await chat.submitAndWait(question, replyStyle: .spokenBrief)
        }
        let result = try await OxIntentSupport.response(from: completion)
        Log.app.info("AskOxIntent completed mode=\(completion.logLabel) chars=\(result.value.count) spokenChars=\(result.spoken.count)")
        return .result(value: result.value, dialog: "\(result.spoken)")
    }
}

struct OxAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskOxIntent(),
            phrases: [
                "Ask \(.applicationName)",
            ],
            shortTitle: "Ask Ox",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: ContinueOxChatIntent(),
            phrases: [
                "Continue a chat with \(.applicationName)",
            ],
            shortTitle: "Continue Chat",
            systemImageName: "arrowshape.turn.up.left"
        )
        AppShortcut(
            intent: AskOxAboutInputIntent(),
            phrases: [
                "Ask \(.applicationName) about input",
            ],
            shortTitle: "Ask About Input",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: ReadLatestOxResponseIntent(),
            phrases: [
                "Read \(.applicationName)'s latest response",
            ],
            shortTitle: "Read Latest Response",
            systemImageName: "speaker.wave.3"
        )
        AppShortcut(
            intent: StopOxIntent(),
            phrases: [
                "Stop \(.applicationName)'s response",
                "Stop \(.applicationName)",
            ],
            shortTitle: "Stop Ox",
            systemImageName: "stop.circle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
