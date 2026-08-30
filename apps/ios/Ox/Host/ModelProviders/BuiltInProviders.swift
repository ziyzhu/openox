nonisolated enum BuiltInProviders {
    static func clients(
        for region: LLMRegion,
        modelLookup: (String, LLMRegion) -> [ProviderModel]
    ) -> [any ProviderClient] {
        let leading: [any ProviderClient] = [
            ChatGPTProvider(models: modelLookup("chatgpt", .global)),
            GeminiProvider(models: modelLookup("gemini", .global)),
            GitHubCopilotProvider(models: modelLookup("github-copilot", .global)),
        ]
        let middle: [any ProviderClient] = [
            OpenAIProvider.client(models: modelLookup("openai", .global)),
            AnthropicProvider.client(models: modelLookup("anthropic", .global)),
            AmazonBedrockProvider(models: modelLookup("amazon-bedrock", .global)),
            XAIProvider.client(models: modelLookup("xai", .global)),
        ]
        return leading
            + clients(from: leadingProfiles, for: region, modelLookup: modelLookup)
            + middle
            + clients(from: trailingProfiles, for: region, modelLookup: modelLookup)
    }

    private static func clients(
        from profiles: [OpenAICompatibleProvider],
        for region: LLMRegion,
        modelLookup: (String, LLMRegion) -> [ProviderModel]
    ) -> [any ProviderClient] {
        profiles.filter { $0.regions.contains(region) }.map {
            $0.client(for: region, models: $0.models?.value(for: region) ?? modelLookup($0.id, region))
        }
    }

    private static let leadingProfiles = [
        OpenCodeGoProvider.profile,
        QwenProvider.codingPlan,
        MiniMaxProvider.tokenPlan,
        OpenRouterProvider.profile,
        ModelArkProvider.profile,
    ]

    private static let trailingProfiles = [
        ZAIProvider.codingPlan,
        MistralProvider.profile,
        KimiProvider.profile,
        DeepSeekProvider.profile,
        ZAIProvider.api,
        QwenProvider.api,
        MiniMaxProvider.api,
        StepFunProvider.profile,
        SiliconFlowProvider.profile,
    ]
}
