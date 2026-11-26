import Foundation

extension Conversation {
    func agentConfiguration(client: any ProviderClient, model: ProviderModel) -> AgentConfiguration {
        let conversationID = id
        return AgentConfiguration(
            client: client,
            model: model,
            promptState: ConversationPromptState.system(memory: systemPromptMemory, deviceID: Device.qualifiedID, profileID: scope.profileID?.uuidString ?? "temporary:\(scope.generation.uuidString)"),
            tools: [ConversationTool(conversation: self)],
            streamOptions: StreamOptions(sessionID: conversationID.uuidString),
            transformContext: { request in
                return await ModelAdapterPipeline.transform(
                    messages: request.messages,
                    model: request.model,
                    loadsFilesLazily: client.supportsTools(for: request.model),
                    wireProtocol: client.wireProtocol(for: request.model)
                )
            }
        )
    }
}

extension Conversation: PrivateDataHost {
    var privateDataContext: PrivateDataAccessContext {
        PrivateDataAccessContext(
            conversationRetention: retention,
            provider: remoteAgent.map { .init(id: "agent:\($0.endpoint.absoluteString)", name: remoteAgentName ?? $0.endpoint.absoluteString, location: .remote) }
                ?? .init(id: client.id, name: client.displayName, location: client.inferenceLocation)
        )
    }

    func choosePrivateDataOption(prompt: String, options: [String]) async -> String {
        await awaitPrompt(
            prompt: prompt,
            options: options,
            allowsCustomAnswer: false,
            presentation: .application
        )
    }

    func continuePrivateDataTemporarily(_ continuation: ConversationContinuation) {
        onPrivateDataTemporaryContinuation?(continuation)
    }
}
