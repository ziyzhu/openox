import Foundation

nonisolated enum ModelArkProvider {
    static let profile = OpenAICompatibleProvider(
        id: "ark",
        displayName: RegionalValue("BytePlus ModelArk API", overrides: [.china: "Volcengine Ark API"]),
        models: RegionalValue(CuratedProviderModels.arkGlobal, overrides: [.china: CuratedProviderModels.arkChina]),
        regions: [.global, .china],
        endpoint: regionalURL(
            "https://ark.ap-southeast.bytepluses.com/api/v3",
            overrides: [.china: "https://ark.cn-beijing.volces.com/api/v3"]
        ),
        regionalCredentials: true,
        reasoningReplayModelIDs: CuratedProviderModels.arkReasoningReplayModelIDs,
        iconURL: regionalURL("https://openox.ai/assets/services/model-providers/byteplus/favicon.png", overrides: [.china: "https://openox.ai/assets/services/model-providers/volcengine/favicon.png"]),
        website: regionalURL("https://console.byteplus.com/ark/region:ark+ap-southeast-1/apikey", overrides: [.china: "https://console.volcengine.com/ark/region:ark+cn-beijing/apikey"])
    )
}
