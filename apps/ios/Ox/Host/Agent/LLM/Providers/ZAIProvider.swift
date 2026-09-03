import Foundation

nonisolated enum ZAIProvider {
    static let codingPlan = OpenAICompatibleProvider(
        id: "zai-coding-plan",
        displayName: RegionalValue("Z.AI Coding Plan"),
        regions: [.global, .china],
        endpoint: regionalURL("https://api.z.ai/api/coding/paas/v4", overrides: [.china: "https://open.bigmodel.cn/api/coding/paas/v4"]),
        credentialKind: .subscriptionKey,
        regionalCredentials: true,
        reasoningControl: .disabled(.thinking),
        website: regionalURL("https://z.ai/subscribe", overrides: [.china: "https://open.bigmodel.cn/glm-coding"])
    )

    static let api = OpenAICompatibleProvider(
        id: "zai",
        displayName: RegionalValue("Z.ai (GLM)"),
        regions: [.global, .china],
        endpoint: regionalURL("https://api.z.ai/api/paas/v4", overrides: [.china: "https://open.bigmodel.cn/api/paas/v4"]),
        regionalCredentials: true,
        reasoningControl: .disabled(.thinking),
        website: regionalURL("https://z.ai/manage-apikey/apikey-list", overrides: [.china: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"]),
        authNotice: "GLM-4.7 Flash is free. Other Z.AI models may charge your account. Usage and rate limits apply.",
        authNoticeRegions: [.china],
        gettingStartedOffer: ProviderGettingStartedOffer(
            summary: "API key · Free GLM-4.7 Flash",
            priority: 0,
            regions: [.china]
        )
    )
}
