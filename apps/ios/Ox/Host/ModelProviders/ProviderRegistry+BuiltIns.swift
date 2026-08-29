import Foundation

nonisolated struct RegionalValue<Value: Sendable>: Sendable {
    let defaultValue: Value
    let overrides: [LLMRegion: Value]

    init(_ defaultValue: Value, overrides: [LLMRegion: Value] = [:]) {
        self.defaultValue = defaultValue
        self.overrides = overrides
    }

    func value(for region: LLMRegion) -> Value {
        overrides[region] ?? defaultValue
    }
}

nonisolated struct OpenAICompatibleProviderProfile: Sendable {
    enum Auth: Sendable {
        case requiredAPIKey(extraHeaders: [String: String] = [:])
        case optionalBearer
    }

    let id: String
    let displayName: RegionalValue<String>
    let models: RegionalValue<[ProviderModel]>?
    let regions: Set<LLMRegion>
    let endpoint: RegionalValue<URL>
    let auth: Auth
    let credentialKind: LLMCredentialKind
    let regionalCredentials: Bool
    let extraBody: [String: JSONValue]
    let cachesSystemPrompt: Bool
    let promptCacheRouting: OpenAIChatClient.PromptCacheRouting
    let maxTokensField: OpenAIChatClient.MaxTokensField
    let reasoningReplayModelIDs: Set<String>
    let reasoningControl: OpenAIChatClient.ReasoningControl
    let website: RegionalValue<URL>?
    let inferenceLocation: LLMInferenceLocation

    init(
        id: String,
        displayName: RegionalValue<String>,
        models: RegionalValue<[ProviderModel]>? = nil,
        regions: Set<LLMRegion> = [.global],
        endpoint: RegionalValue<URL>,
        auth: Auth = .requiredAPIKey(),
        credentialKind: LLMCredentialKind = .apiKey,
        regionalCredentials: Bool = false,
        extraBody: [String: JSONValue] = [:],
        cachesSystemPrompt: Bool = false,
        promptCacheRouting: OpenAIChatClient.PromptCacheRouting = .sessionHeader,
        maxTokensField: OpenAIChatClient.MaxTokensField = .maxTokens,
        reasoningReplayModelIDs: Set<String> = [],
        reasoningControl: OpenAIChatClient.ReasoningControl = .providerDefault,
        website: RegionalValue<URL>? = nil,
        inferenceLocation: LLMInferenceLocation = .remote
    ) {
        self.id = id
        self.displayName = displayName
        self.models = models
        self.regions = regions
        self.endpoint = endpoint
        self.auth = auth
        self.credentialKind = credentialKind
        self.regionalCredentials = regionalCredentials
        self.extraBody = extraBody
        self.cachesSystemPrompt = cachesSystemPrompt
        self.promptCacheRouting = promptCacheRouting
        self.maxTokensField = maxTokensField
        self.reasoningReplayModelIDs = reasoningReplayModelIDs
        self.reasoningControl = reasoningControl
        self.website = website
        self.inferenceLocation = inferenceLocation
    }

    func client(for region: LLMRegion, models fallbackModels: [ProviderModel]) -> OpenAIChatClient {
        let baseURL = endpoint.value(for: region)
        let credentialID = regionalCredentials && region != .global ? "\(id):\(region.rawValue)" : id
        let resolvedAuth: any OpenAIChatAuth
        let usesAPIKey: Bool
        switch auth {
        case .requiredAPIKey(let extraHeaders):
            resolvedAuth = OpenAIAPIKeyAuth(clientID: credentialID, baseURL: baseURL, extraHeaders: extraHeaders)
            usesAPIKey = true
        case .optionalBearer:
            resolvedAuth = OpenAIOptionalAPIKeyAuth(clientID: credentialID, baseURL: baseURL)
            usesAPIKey = false
        }
        return OpenAIChatClient(
            id: id,
            displayName: displayName.value(for: region),
            models: models?.value(for: region) ?? fallbackModels,
            regions: regions,
            auth: resolvedAuth,
            usesAPIKey: usesAPIKey,
            acceptsAPIKey: true,
            credentialKind: credentialKind,
            credentialID: credentialID,
            extraBody: extraBody,
            cachesSystemPrompt: cachesSystemPrompt,
            promptCacheRouting: promptCacheRouting,
            maxTokensField: maxTokensField,
            reasoningReplayModelIDs: reasoningReplayModelIDs,
            reasoningControl: reasoningControl,
            website: website?.value(for: region),
            inferenceLocation: inferenceLocation,
            diagnosticsEndpoint: baseURL
        )
    }
}

extension ProviderRegistry {
    static func leadingClients(
        for region: LLMRegion,
        modelLookup: (String, LLMRegion) -> [ProviderModel]
    ) -> [any LLMClient] {
        leadingProfiles.filter { $0.regions.contains(region) }.map {
            $0.client(for: region, models: $0.models?.value(for: region) ?? modelLookup($0.id, region))
        }
    }

    static func trailingClients(
        for region: LLMRegion,
        modelLookup: (String, LLMRegion) -> [ProviderModel]
    ) -> [any LLMClient] {
        trailingProfiles.filter { $0.regions.contains(region) }.map {
            $0.client(for: region, models: $0.models?.value(for: region) ?? modelLookup($0.id, region))
        }
    }

    private static let leadingProfiles: [OpenAICompatibleProviderProfile] = [
        OpenAICompatibleProviderProfile(
            id: "opencode-go",
            displayName: RegionalValue("OpenCode Go"),
            endpoint: regionalURL("https://opencode.ai/zen/go/v1"),
            credentialKind: .subscriptionKey,
            reasoningReplayModelIDs: ["deepseek-v4-flash", "deepseek-v4-pro", "kimi-k3", "glm-5.2", "ox-alpha-free"],
            reasoningControl: .providerDefault,
            website: regionalURL("https://opencode.ai/go")
        ),
        OpenAICompatibleProviderProfile(
            id: "qwen-coding-plan",
            displayName: RegionalValue("Qwen Coding Plan"),
            regions: [.global, .china],
            endpoint: regionalURL("https://coding-intl.dashscope.aliyuncs.com/v1", overrides: [.china: "https://coding.dashscope.aliyuncs.com/v1"]),
            credentialKind: .subscriptionKey,
            regionalCredentials: true,
            cachesSystemPrompt: true,
            reasoningControl: .disabled(.qwen),
            website: regionalURL("https://modelstudio.console.alibabacloud.com/coding-plan", overrides: [.china: "https://bailian.console.aliyun.com/?tab=model#/efm/coding_plan"])
        ),
        OpenAICompatibleProviderProfile(
            id: "minimax-token-plan",
            displayName: RegionalValue("MiniMax Token Plan"),
            regions: [.global, .china],
            endpoint: regionalURL("https://api.minimax.io/v1", overrides: [.china: "https://api.minimaxi.com/v1"]),
            credentialKind: .subscriptionKey,
            regionalCredentials: true,
            extraBody: ["reasoning_split": .bool(true)],
            maxTokensField: .maxCompletionTokens,
            reasoningReplayModelIDs: ["MiniMax-M3"],
            reasoningControl: .disabled(.thinking),
            website: regionalURL("https://platform.minimax.io/subscribe/coding-plan", overrides: [.china: "https://platform.minimaxi.com/subscribe/coding-plan"])
        ),
        OpenAICompatibleProviderProfile(
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
        ),
        OpenAICompatibleProviderProfile(
            id: "ark",
            displayName: RegionalValue("BytePlus ModelArk", overrides: [.china: "Volcengine Ark"]),
            models: RegionalValue(CuratedProviderModels.arkGlobal, overrides: [.china: CuratedProviderModels.arkChina]),
            regions: [.global, .china],
            endpoint: regionalURL(
                "https://ark.ap-southeast.bytepluses.com/api/v3",
                overrides: [.china: "https://ark.cn-beijing.volces.com/api/v3"]
            ),
            regionalCredentials: true,
            reasoningReplayModelIDs: CuratedProviderModels.arkReasoningReplayModelIDs,
            website: regionalURL("https://console.byteplus.com/ark/region:ark+ap-southeast-1/apikey", overrides: [.china: "https://console.volcengine.com/ark/region:ark+cn-beijing/apikey"])
        ),
    ]

    private static let trailingProfiles: [OpenAICompatibleProviderProfile] = [
        OpenAICompatibleProviderProfile(
            id: "zai-coding-plan",
            displayName: RegionalValue("Z.AI Coding Plan"),
            regions: [.global, .china],
            endpoint: regionalURL("https://api.z.ai/api/coding/paas/v4", overrides: [.china: "https://open.bigmodel.cn/api/coding/paas/v4"]),
            credentialKind: .subscriptionKey,
            regionalCredentials: true,
            reasoningControl: .disabled(.thinking),
            website: regionalURL("https://z.ai/subscribe", overrides: [.china: "https://open.bigmodel.cn/glm-coding"])
        ),
        OpenAICompatibleProviderProfile(
            id: "mistral",
            displayName: RegionalValue("Mistral"),
            endpoint: regionalURL("https://api.mistral.ai/v1"),
            reasoningControl: .effort(.none),
            website: regionalURL("https://console.mistral.ai/api-keys")
        ),
        OpenAICompatibleProviderProfile(
            id: "kimi",
            displayName: RegionalValue("Kimi"),
            regions: [.global, .china],
            endpoint: regionalURL("https://api.moonshot.ai/v1", overrides: [.china: "https://api.moonshot.cn/v1"]),
            regionalCredentials: true,
            promptCacheRouting: .requestBody,
            maxTokensField: .maxCompletionTokens,
            reasoningReplayModelIDs: ["kimi-k3"],
            reasoningControl: .effort(.low),
            website: regionalURL("https://platform.kimi.ai/console/api-keys", overrides: [.china: "https://platform.moonshot.cn/console/api-keys"])
        ),
        OpenAICompatibleProviderProfile(
            id: "deepseek",
            displayName: RegionalValue("DeepSeek"),
            regions: [.global, .china],
            endpoint: regionalURL("https://api.deepseek.com/v1"),
            reasoningReplayModelIDs: ["deepseek-v4-flash", "deepseek-v4-pro"],
            reasoningControl: .disabled(.thinking),
            website: regionalURL("https://platform.deepseek.com/api_keys")
        ),
        OpenAICompatibleProviderProfile(
            id: "zai",
            displayName: RegionalValue("Z.ai (GLM)"),
            regions: [.global, .china],
            endpoint: regionalURL("https://api.z.ai/api/paas/v4", overrides: [.china: "https://open.bigmodel.cn/api/paas/v4"]),
            regionalCredentials: true,
            reasoningControl: .disabled(.thinking),
            website: regionalURL("https://z.ai/manage-apikey/apikey-list", overrides: [.china: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys"])
        ),
        OpenAICompatibleProviderProfile(
            id: "qwen",
            displayName: RegionalValue("Qwen"),
            regions: [.global, .china],
            endpoint: regionalURL("https://dashscope-intl.aliyuncs.com/compatible-mode/v1", overrides: [.china: "https://dashscope.aliyuncs.com/compatible-mode/v1"]),
            regionalCredentials: true,
            cachesSystemPrompt: true,
            reasoningControl: .disabled(.qwen),
            website: regionalURL("https://modelstudio.console.alibabacloud.com/?tab=model#/api-key", overrides: [.china: "https://bailian.console.aliyun.com/?tab=model#/api-key"])
        ),
        OpenAICompatibleProviderProfile(
            id: "minimax",
            displayName: RegionalValue("MiniMax"),
            regions: [.china],
            endpoint: regionalURL("https://api.minimax.io/v1", overrides: [.china: "https://api.minimaxi.com/v1"]),
            regionalCredentials: true,
            extraBody: ["reasoning_split": .bool(true)],
            maxTokensField: .maxCompletionTokens,
            reasoningReplayModelIDs: ["MiniMax-M3"],
            reasoningControl: .disabled(.thinking),
            website: regionalURL("https://platform.minimax.io/user-center/basic-information/interface-key", overrides: [.china: "https://platform.minimaxi.com/user-center/basic-information/interface-key"])
        ),
        OpenAICompatibleProviderProfile(
            id: "stepfun",
            displayName: RegionalValue("StepFun"),
            regions: [.china],
            endpoint: regionalURL("https://api.stepfun.com/v1"),
            reasoningReplayModelIDs: ["step-3.7-flash"],
            website: regionalURL("https://platform.stepfun.com/interface-key")
        ),
        OpenAICompatibleProviderProfile(
            id: "siliconflow",
            displayName: RegionalValue("SiliconFlow"),
            regions: [.china],
            endpoint: regionalURL("https://api.siliconflow.cn/v1"),
            reasoningReplayModelIDs: ["deepseek-ai/DeepSeek-V4-Flash", "deepseek-ai/DeepSeek-V4-Pro", "zai-org/GLM-5.2"],
            website: regionalURL("https://cloud.siliconflow.cn/account/ak")
        ),
    ]

    private static func regionalURL(_ defaultValue: String, overrides: [LLMRegion: String] = [:]) -> RegionalValue<URL> {
        RegionalValue(
            URL(string: defaultValue)!,
            overrides: overrides.mapValues { URL(string: $0)! }
        )
    }
}
