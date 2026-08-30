import Foundation

nonisolated enum OpenAIProvider {
    static func client(models: [ProviderModel]) -> OpenAIResponsesTransport {
        let baseURL = URL(string: "https://api.openai.com/v1")!
        return OpenAIResponsesTransport(
            id: "openai",
            displayName: "OpenAI",
            models: models,
            website: URL(string: "https://platform.openai.com/api-keys"),
            auth: OpenAIResponsesAPIKeyAuth(clientID: "openai", baseURL: baseURL)
        )
    }
}
