import Foundation

nonisolated enum QwenProvider {
    static let codingPlan = OpenAICompatibleProvider(
        id: "qwen-coding-plan",
        displayName: RegionalValue("Qwen Coding Plan"),
        regions: [.global, .china],
        endpoint: regionalURL("https://coding-intl.dashscope.aliyuncs.com/v1", overrides: [.china: "https://coding.dashscope.aliyuncs.com/v1"]),
        credentialKind: .subscriptionKey,
        regionalCredentials: true,
        cachesSystemPrompt: true,
        reasoningControl: .disabled(.qwen),
        website: regionalURL("https://modelstudio.console.alibabacloud.com/coding-plan", overrides: [.china: "https://bailian.console.aliyun.com/?tab=model#/efm/coding_plan"])
    )

    static let api = OpenAICompatibleProvider(
        id: "qwen",
        displayName: RegionalValue("Qwen"),
        regions: [.global, .china],
        endpoint: regionalURL("https://dashscope-intl.aliyuncs.com/compatible-mode/v1", overrides: [.china: "https://dashscope.aliyuncs.com/compatible-mode/v1"]),
        regionalCredentials: true,
        cachesSystemPrompt: true,
        reasoningControl: .disabled(.qwen),
        website: regionalURL("https://modelstudio.console.alibabacloud.com/?tab=model#/api-key", overrides: [.china: "https://bailian.console.aliyun.com/?tab=model#/api-key"])
    )
}
