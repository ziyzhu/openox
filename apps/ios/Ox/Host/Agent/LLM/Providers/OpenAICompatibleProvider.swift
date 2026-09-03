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

nonisolated struct OpenAICompatibleProvider: Sendable {
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
    let promptCacheRouting: OpenAIChatTransport.PromptCacheRouting
    let maxTokensField: OpenAIChatTransport.MaxTokensField
    let reasoningReplayModelIDs: Set<String>
    let reasoningControl: OpenAIChatTransport.ReasoningControl
    let website: RegionalValue<URL>?
    let authNotice: String?
    let authNoticeRegions: Set<LLMRegion>
    let gettingStartedOffer: ProviderGettingStartedOffer?
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
        promptCacheRouting: OpenAIChatTransport.PromptCacheRouting = .sessionHeader,
        maxTokensField: OpenAIChatTransport.MaxTokensField = .maxTokens,
        reasoningReplayModelIDs: Set<String> = [],
        reasoningControl: OpenAIChatTransport.ReasoningControl = .providerDefault,
        website: RegionalValue<URL>? = nil,
        authNotice: String? = nil,
        authNoticeRegions: Set<LLMRegion> = [.global, .china],
        gettingStartedOffer: ProviderGettingStartedOffer? = nil,
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
        self.authNotice = authNotice
        self.authNoticeRegions = authNoticeRegions
        self.gettingStartedOffer = gettingStartedOffer
        self.inferenceLocation = inferenceLocation
    }

    func client(for region: LLMRegion, models fallbackModels: [ProviderModel]) -> OpenAIChatTransport {
        let baseURL = endpoint.value(for: region)
        let credentialID = regionalCredentials && region != .global ? "\(id):\(region.rawValue)" : id
        let resolvedAuth: any OpenAIChatTransportAuth
        let usesAPIKey: Bool
        switch auth {
        case .requiredAPIKey(let extraHeaders):
            resolvedAuth = OpenAIAPIKeyAuth(clientID: credentialID, baseURL: baseURL, extraHeaders: extraHeaders)
            usesAPIKey = true
        case .optionalBearer:
            resolvedAuth = OpenAIOptionalAPIKeyAuth(clientID: credentialID, baseURL: baseURL)
            usesAPIKey = false
        }
        return OpenAIChatTransport(
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
            authNotice: authNotice.flatMap { authNoticeRegions.contains(region) ? $0 : nil },
            gettingStartedOffer: gettingStartedOffer.flatMap { $0.regions.contains(region) ? $0 : nil },
            inferenceLocation: inferenceLocation,
            diagnosticsEndpoint: baseURL
        )
    }
}

nonisolated func regionalURL(_ defaultValue: String, overrides: [LLMRegion: String] = [:]) -> RegionalValue<URL> {
    RegionalValue(
        URL(string: defaultValue)!,
        overrides: overrides.mapValues { URL(string: $0)! }
    )
}
