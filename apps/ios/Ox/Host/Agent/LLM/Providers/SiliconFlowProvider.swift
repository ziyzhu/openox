import Foundation

nonisolated enum SiliconFlowProvider {
    static let profile = OpenAICompatibleProvider(
        id: "siliconflow",
        displayName: RegionalValue("SiliconFlow"),
        regions: [.china],
        endpoint: regionalURL("https://api.siliconflow.cn/v1"),
        reasoningReplayModelIDs: ["Qwen/Qwen3.5-4B", "deepseek-ai/DeepSeek-V4-Flash", "deepseek-ai/DeepSeek-V4-Pro", "zai-org/GLM-5.2"],
        website: regionalURL("https://cloud.siliconflow.cn/account/ak"),
        authNotice: "Qwen 3.5 4B is free after identity verification. Other SiliconFlow models may charge your account. Fixed rate limits apply.",
        gettingStartedOffer: ProviderGettingStartedOffer(
            summary: "API key · Free Qwen 3.5 4B",
            priority: 1,
            regions: [.china]
        )
    )
}
