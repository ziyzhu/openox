import Foundation

nonisolated enum ModelScopeProvider {
    static let profile = OpenAICompatibleProvider(
        id: "modelscope",
        displayName: RegionalValue("ModelScope"),
        regions: [.china],
        endpoint: regionalURL("https://api-inference.modelscope.cn/v1"),
        reasoningReplayModelIDs: ["ZhipuAI/GLM-4.6"],
        website: regionalURL("https://modelscope.cn/my/myaccesstoken"),
        authNotice: "Free for development: 2,000 calls/day total, typically 200/model. Requires a verified, linked Alibaba Cloud account; limits can change.",
        gettingStartedOffer: ProviderGettingStartedOffer(
            summary: "SDK token · 2,000 calls/day",
            priority: 4,
            regions: [.china]
        )
    )
}
