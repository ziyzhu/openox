import Foundation

nonisolated enum OpenRouterProvider {
    static let profile = OpenAICompatibleProvider(
        id: "openrouter",
        displayName: RegionalValue("OpenRouter"),
        endpoint: regionalURL("https://openrouter.ai/api/v1"),
        auth: .requiredAPIKey(extraHeaders: ["HTTP-Referer": "https://github.com/ziyzhu/openox", "X-OpenRouter-Title": "Ox"]),
        extraBody: ["provider": .object(["sort": .string("latency")])],
        reasoningReplayModelIDs: [
            "stealth/ox-alpha", "anthropic/claude-sonnet-5", "openai/gpt-5.6-terra", "google/gemini-3.7-flash",
            "deepseek/deepseek-v4-flash-0731", "qwen/qwen3.8-max", "moonshotai/kimi-k3", "z-ai/glm-5.2",
        ],
        reasoningControl: .reasoningObject,
        website: regionalURL("https://openrouter.ai/settings/keys")
    )
}
