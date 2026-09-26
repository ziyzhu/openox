import Foundation

nonisolated struct BundledProviderDefinition: Sendable {
    var definition: ProviderDefinition
    var presentation: ProviderPresentation
    var legacyID: String
    var legacyRegion: LLMRegion?
    var legacyCredentialID: String
}

nonisolated extension BuiltInProviders {
    static func definitions(modelLookup: (String, LLMRegion) -> [ProviderModel]) -> [BundledProviderDefinition] {
        var entries: [BundledProviderDefinition] = []
        let chatgpt = ChatGPTProvider(models: modelLookup("chatgpt", .global))
        entries.append(custom(chatgpt, url: ChatGPTOAuth.responsesURL.deletingLastPathComponent(), api: .openAIResponses,
                              options: .init(sessionHeader: "session-id", streaming: "websocket-with-sse-fallback", accountHeader: "ChatGPT-Account-Id"),
                              models: chatgpt.models.map { .init($0, options: $0.variant == .fast ? .init(serviceTier: "priority") : nil) }))
        let gemini = GeminiProvider(models: modelLookup("gemini", .global))
        entries.append(entry(gemini, url: gemini.config.baseURL, api: .geminiGenerateContent, auth: .init(kind: .apiKey, header: "x-goog-api-key")))
        entries.append(custom(GitHubCopilotProvider(models: modelLookup("github-copilot", .global)), url: GitHubCopilotOAuth.apiURL, api: .openAIResponses))
        entries += profiles(planProfiles, modelLookup: modelLookup)
        let router = OpenRouterProvider.client(models: modelLookup("openrouter", .global))
        entries.append(custom(router, url: OpenRouterOAuth.apiBaseURL, api: .openAIChatCompletions, options: chatOptions(router), models: chatModels(router)))
        entries += profiles([ModelArkProvider.profile], modelLookup: modelLookup)
        let openai = OpenAIProvider.client(models: modelLookup("openai", .global))
        entries.append(entry(openai, url: (openai.auth as! OpenAIResponsesAPIKeyAuth).baseURL, api: .openAIResponses,
                             auth: .init(kind: .bearer), options: .init(reasoningEffort: openai.reasoningEffort.rawValue)))
        entries.append(messages(AnthropicProvider.client(models: modelLookup("anthropic", .global))))
        let bedrock = AmazonBedrockProvider(models: modelLookup("amazon-bedrock", .global))
        var bedrockResponses = entry(bedrock.responses, url: (bedrock.responses.auth as! OpenAIResponsesAPIKeyAuth).baseURL,
                                    api: .openAIResponses, auth: .init(kind: .bearer))
        bedrockResponses.definition.id = "amazon-bedrock:responses"
        bedrockResponses.definition.name = "Amazon Bedrock API · Responses"
        bedrockResponses.legacyID = bedrock.id
        bedrockResponses.legacyCredentialID = bedrock.id
        entries.append(bedrockResponses)
        var bedrockMessages = messages(bedrock.messages)
        bedrockMessages.definition.id = "amazon-bedrock:messages"
        bedrockMessages.definition.name = "Amazon Bedrock API · Messages"
        bedrockMessages.presentation = presentation(bedrock)
        bedrockMessages.legacyID = bedrock.id
        bedrockMessages.legacyCredentialID = bedrock.id
        entries.append(bedrockMessages)
        entries.append(custom(XAIProvider.client(models: modelLookup("xai", .global)), url: XAIOAuth.responsesBaseURL, api: .openAIResponses))
        entries += profiles(trailingProfiles, modelLookup: modelLookup)
        let webModel = ProviderModel(
            id: "website-default", displayName: "Default", maxTokens: 4_096,
            maxContext: 32_768, supportsTools: true
        )
        entries.append(BundledProviderDefinition(
            definition: ProviderDefinition(
                id: "kimi-web", name: "Kimi Website", url: URL(string: "https://www.kimi.com/")!,
                api: .web, auth: .init(kind: .custom, adapter: "kimi-web"),
                options: nil, models: [.init(webModel)]
            ),
            presentation: ProviderPresentation(
                regions: [.global], website: URL(string: "https://www.kimi.com/"),
                authNotice: "Kimi Website uses your Ox browser session. Website inference accepts text inputs; Ox Action calls are experimental.",
                credentialKind: .bearerToken
            ),
            legacyID: "kimi-web", legacyRegion: nil, legacyCredentialID: "kimi-web"
        ))
        entries.append(BundledProviderDefinition(
            definition: ProviderDefinition(
                id: "qwen-web", name: "Qwen Website", url: URL(string: "https://chat.qwen.ai/")!,
                api: .web, auth: .init(kind: .custom, adapter: "qwen-web"),
                options: nil, models: [.init(webModel)]
            ),
            presentation: ProviderPresentation(
                regions: [.global], website: URL(string: "https://chat.qwen.ai/"),
                authNotice: "Qwen Website uses your Ox browser session. Website inference accepts text inputs; Ox Action calls are experimental.",
                credentialKind: .bearerToken
            ),
            legacyID: "qwen-web", legacyRegion: nil, legacyCredentialID: "qwen-web"
        ))
        entries.append(BundledProviderDefinition(
            definition: ProviderDefinition(
                id: "grok-web", name: "Grok Website", url: URL(string: "https://grok.com/")!,
                api: .web, auth: .init(kind: .custom, adapter: "grok-web"),
                options: nil, models: [.init(webModel)]
            ),
            presentation: ProviderPresentation(
                regions: [.global], website: URL(string: "https://grok.com/"),
                authNotice: "Grok Website uses your Ox browser session. Website inference accepts text inputs; Ox Action calls are experimental.",
                credentialKind: .bearerToken
            ),
            legacyID: "grok-web", legacyRegion: nil, legacyCredentialID: "grok-web"
        ))
        entries.append(BundledProviderDefinition(
            definition: ProviderDefinition(
                id: "claude-web", name: "Claude Website", url: URL(string: "https://claude.ai/")!,
                api: .web, auth: .init(kind: .custom, adapter: "claude-web"),
                options: nil, models: [.init(webModel)]
            ),
            presentation: ProviderPresentation(
                regions: [.global], website: URL(string: "https://claude.ai/"),
                authNotice: "Claude Website uses your Ox browser session. Text replies appear after completion; Ox Action calls are experimental. Stopping Ox may not stop Claude generation.",
                credentialKind: .bearerToken
            ),
            legacyID: "claude-web", legacyRegion: nil, legacyCredentialID: "claude-web"
        ))
        return entries
    }

    private static func profiles(_ profiles: [OpenAICompatibleProvider], modelLookup: (String, LLMRegion) -> [ProviderModel]) -> [BundledProviderDefinition] {
        profiles.flatMap { profile -> [BundledProviderDefinition] in
            let split = profile.regionalCredentials || !profile.endpoint.overrides.isEmpty || !(profile.models?.overrides.isEmpty ?? true)
            let regions = split ? LLMRegion.allCases.filter { profile.regions.contains($0) } : [profile.regions.contains(.global) ? .global : .china]
            return regions.map { region in
                let client = profile.client(for: region, models: profile.models?.value(for: region) ?? modelLookup(profile.id, region))
                let auth: ProviderDefinition.Authentication
                switch profile.auth {
                case .requiredAPIKey: auth = .init(kind: .bearer)
                case .optionalBearer: auth = .init(kind: .bearer, optional: true)
                }
                var value = entry(client, url: profile.endpoint.value(for: region), api: .openAIChatCompletions,
                                  auth: auth, options: chatOptions(client), models: chatModels(client))
                if split {
                    value.definition.id = "\(profile.id):\(region.rawValue)"
                    value.presentation.regions = [region]
                    value.legacyRegion = region
                }
                return value
            }
        }
    }

    private static func messages(_ client: AnthropicMessagesTransport) -> BundledProviderDefinition {
        entry(client, url: client.endpoint.deletingLastPathComponent(), api: .anthropicMessages,
              auth: .init(kind: .apiKey, header: "x-api-key"),
              models: client.models.map { .init($0, options: client.adaptiveThinkingModelIDs.contains($0.wireID) ? .init(adaptiveThinking: true) : nil) })
    }

    private static func custom(_ client: any ProviderClient, url: URL, api: LLMWireProtocol,
                               options: ProviderDefinition.Options? = nil, models: [ProviderDefinition.Model]? = nil) -> BundledProviderDefinition {
        entry(client, url: url, api: api, auth: .init(kind: .custom, adapter: client.id), options: options, models: models)
    }

    private static func entry(_ client: any ProviderClient, url: URL, api: LLMWireProtocol,
                              auth: ProviderDefinition.Authentication, options: ProviderDefinition.Options? = nil,
                              models: [ProviderDefinition.Model]? = nil) -> BundledProviderDefinition {
        let supported = models ?? client.models.filter { client.supportsTools(for: $0) }.map { ProviderDefinition.Model($0) }
        return BundledProviderDefinition(
            definition: ProviderDefinition(id: client.id, name: client.displayName, url: url, api: api, auth: auth, options: options, models: supported),
            presentation: presentation(client), legacyID: client.id, legacyRegion: nil, legacyCredentialID: client.credentialID
        )
    }

    private static func presentation(_ client: any ProviderClient) -> ProviderPresentation {
        ProviderPresentation(regions: client.regions, website: client.website, authNotice: client.authNotice,
                             offer: client.gettingStartedOffer, credentialKind: client.credentialKind, inferenceLocation: client.inferenceLocation)
    }

    private static func chatModels(_ client: OpenAIChatTransport) -> [ProviderDefinition.Model] {
        client.models.filter { client.supportsTools(for: $0) }.map {
            .init($0, options: client.reasoningReplayModelIDs.contains($0.wireID) ? .init(replayReasoning: true) : nil)
        }
    }

    private static func chatOptions(_ client: OpenAIChatTransport) -> ProviderDefinition.Options {
        let format: String
        var effort: String?
        switch client.reasoningControl {
        case .providerDefault: format = "provider-default"
        case .effort(let value): format = "reasoning_effort"; effort = value.rawValue
        case .reasoningObject: format = "reasoning_object"
        case .disabled(.reasoning): format = "disable-reasoning"
        case .disabled(.thinking): format = "disable-thinking"
        case .disabled(.chatTemplate): format = "disable-chat-template"
        case .disabled(.qwen): format = "disable-qwen"
        }
        let headers = (client.auth as? OpenAIAPIKeyAuth)?.extraHeaders
        return .init(headers: headers?.isEmpty == false ? headers : nil,
                     extraBody: client.extraBody.isEmpty ? nil : client.extraBody,
                     maxTokensField: client.maxTokensField.rawValue, reasoningFormat: format, reasoningEffort: effort,
                     cachesSystemPrompt: client.cachesSystemPrompt, cacheRouting: client.promptCacheRouting.rawValue)
    }
}
