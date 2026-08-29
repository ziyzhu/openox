import Foundation

nonisolated enum OpenAIClient {
    static func make(models: [ProviderModel]) -> OpenAIResponsesClient {
        let baseURL = URL(string: "https://api.openai.com/v1")!
        return OpenAIResponsesClient(
            id: "openai",
            displayName: "OpenAI",
            models: models,
            website: URL(string: "https://platform.openai.com/api-keys"),
            auth: OpenAIResponsesAPIKeyAuth(clientID: "openai", baseURL: baseURL)
        )
    }
}
