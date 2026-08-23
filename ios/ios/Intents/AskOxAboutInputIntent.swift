import AppIntents
import Foundation
import UniformTypeIdentifiers

struct AskOxAboutInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Ox About Input"
    static let description = IntentDescription("Ask Ox about text, a URL, images, or files from another Shortcut action.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question")
    var prompt: String?

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String?

    @Parameter(title: "URL", inputConnectionBehavior: .connectToPreviousIntentResult)
    var url: URL?

    @Parameter(
        title: "Files",
        supportedContentTypes: [.item],
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var files: [IntentFile]?

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Ox \(\.$prompt)") {
            \.$text
            \.$url
            \.$files
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let budget = OxIntentBudget()
        let files = files ?? []
        let suppliedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedText = if suppliedText?.isEmpty == false || url != nil || !files.isEmpty {
            suppliedText
        } else {
            try await budget.withSuspendedDeadline {
                try await $text.requestValue("What text or URL should Ox use?")
            }
        }
        let suppliedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrompt = if let suppliedPrompt, !suppliedPrompt.isEmpty {
            suppliedPrompt
        } else {
            try await budget.withSuspendedDeadline {
                try await $prompt.requestValue("What would you like to know about this input?")
            }
        }
        let runtime = try await OxIntentSupport.readyRuntime()
        let hasText = resolvedText?.isEmpty == false
        let question = try OxIntentSupport.combinedPrompt(question: resolvedPrompt, text: resolvedText, url: url)
        let artifacts = try await OxIntentSupport.importArtifacts(files, using: runtime.chatManager)
        let chat = runtime.chatManager.startNewChat()
        Log.app.info(
            "AskOxAboutInputIntent start promptChars=\(resolvedPrompt.count) text=\(hasText) url=\(url != nil) files=\(artifacts.count)"
        )
        let completion = await OxIntentSupport.waitForCompletion(
            budget: budget,
            chat: { chat },
            interaction: { try await requestOxInput($0) }
        ) {
            await chat.submitAndWait(
                question,
                attachments: artifacts,
                replyStyle: .spokenBrief
            )
        }
        let result = try await OxIntentSupport.response(from: completion)
        Log.app.info("AskOxAboutInputIntent completed mode=\(completion.logLabel) chars=\(result.value.count)")
        return .result(value: result.value, dialog: "\(result.spoken)")
    }
}
