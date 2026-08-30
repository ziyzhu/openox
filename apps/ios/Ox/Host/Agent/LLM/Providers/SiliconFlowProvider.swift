import Foundation

nonisolated enum SiliconFlowProvider {
    static let profile = OpenAICompatibleProvider(
        id: "siliconflow",
        displayName: RegionalValue("SiliconFlow"),
        regions: [.china],
        endpoint: regionalURL("https://api.siliconflow.cn/v1"),
        reasoningReplayModelIDs: ["deepseek-ai/DeepSeek-V4-Flash", "deepseek-ai/DeepSeek-V4-Pro", "zai-org/GLM-5.2"],
        website: regionalURL("https://cloud.siliconflow.cn/account/ak")
    )
}
