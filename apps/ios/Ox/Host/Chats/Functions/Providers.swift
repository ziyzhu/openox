import Foundation

extension Conversation {
    public func providerOperation(name: String, arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        guard OxProviders.operations.contains(where: { $0.0 == name }),
              let fields = arguments.objectValue else { throw RuntimeError.bridge("Unknown provider operation") }
        let operation = "ox.provider.\(name)"
        let registry = ProviderRegistry.shared
        let definition: ProviderDefinition?
        if name == "save" || name == "validate" {
            guard let document = fields["provider"] else { throw RuntimeError.bridge("A provider document is required") }
            let decoded = try ProviderDefinition.decode(document)
            try ProviderClientFactory.validateAdapter(decoded)
            definition = decoded
        } else if name != "list" && name != "default" {
            definition = try registry.definition(id: fields["id"]?.stringValue ?? "")
        } else { definition = nil }
        return try await tracked(operation, arguments, purpose: purpose) {
            switch name {
            case "default": return .array(try registry.defaultDefinitions.map { try $0.json })
            case "list":
                return .array(registry.definitions.map { providerSummary($0, registry: registry) })
            case "get": return try definition!.json
            case "validate": return .object(["id": .string(definition!.id), "valid": .bool(true)])
            case "save":
                try requireProfileMutation(operation)
                try Task.checkCancellation()
                try registry.save(definition!)
                return .object(["id": .string(definition!.id), "saved": .bool(true)])
            case "delete":
                try requireProfileMutation(operation)
                try Task.checkCancellation()
                try registry.delete(id: definition!.id)
                return .object(["id": .string(definition!.id), "deleted": .bool(true)])
            case "deauthenticate":
                try Task.checkCancellation()
                registry.deauthenticate(definition!)
                return .object(["id": .string(definition!.id), "status": .string(registry.authenticationStatus(id: definition!.id))])
            case "authenticate":
                return try await authenticateProvider(definition!)
            case "connect":
                guard let credential = fields["credential"]?.objectValue,
                      let kind = credential["kind"]?.stringValue else {
                    throw RuntimeError.bridge("Provider credential source is required")
                }
                if kind == "oauth" {
                    guard credential["secretKey"] == nil,
                          registry.client(id: definition!.id)?.subscriptionAccount != nil else {
                        throw RuntimeError.bridge("Provider does not support managed OAuth")
                    }
                    return try await authenticateProvider(definition!)
                }
                guard kind == "secret", let key = credential["secretKey"]?.stringValue,
                      registry.client(id: definition!.id)?.acceptsAPIKey == true,
                      let entry = try Secret.entry(key: key) else {
                    throw RuntimeError.bridge("Provider cannot use this Secret entry")
                }
                let prompt = "Connect \(definition!.name) to \(entry.displayName) (\(key))?\nDestination: \(definition!.url.absoluteString)\nField supplied: apiKey"
                let answer = await awaitPrompt(prompt: prompt, options: ["Connect", "Cancel"])
                guard answer == "Connect" else {
                    return .object(["id": .string(definition!.id), "status": .string("cancelled")])
                }
                try Secret.bindProvider(key: key, definition: definition!)
                return .object(["id": .string(definition!.id), "status": .string("connected")])
            default: throw RuntimeError.bridge("Unknown provider operation")
            }
        }
    }

    private func authenticateProvider(_ definition: ProviderDefinition) async throws -> JSONValue {
        if definition.auth.kind == .none {
            return .object(["id": .string(definition.id), "status": .string("not-required")])
        }
        guard let client = ProviderRegistry.shared.client(id: definition.id) else {
            throw RuntimeError.bridge("Provider authentication UI is unavailable")
        }
        if client.models.first.flatMap({ client.wireProtocol(for: $0) }) == .web,
           (try? await client.websiteSessionIsAuthenticated()) == true {
            return .object(["id": .string(definition.id), "status": .string(ProviderAuthenticationSession.Outcome.authenticated.rawValue)])
        }
        guard let presenter = presentations.providerAuthentication else {
            throw RuntimeError.bridge("Provider authentication UI is unavailable")
        }
        let session = ProviderAuthenticationSession(definition: definition, client: client)
        let outcome = await presenter.present(session: session)
        try Task.checkCancellation()
        guard outcome == .authenticated || outcome == .credentialStored else {
            throw RuntimeError.bridge(outcome == .cancelled ? "Provider authentication was cancelled" : "Provider authentication could not be presented")
        }
        return .object(["id": .string(definition.id), "status": .string(outcome.rawValue)])
    }

    private func providerSummary(_ definition: ProviderDefinition, registry: ProviderRegistry) -> JSONValue {
        let client = registry.client(id: definition.id)
        let website = client?.website
        let offer = client?.gettingStartedOffer
        return .object([
            "id": .string(definition.id),
            "name": .string(definition.name),
            "source": .string(registry.source(id: definition.id).rawValue),
            "api": .string(definition.api.rawValue),
            "url": .string(definition.url.absoluteString),
            "website": website.map { .string($0.absoluteString) } ?? .null,
            "regions": .array((client?.regions ?? []).sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
            "inferenceLocation": .string((client?.inferenceLocation ?? .remote).providerInformationValue),
            "models": .int(definition.models.count),
            "availableModels": .int(client?.models.count ?? 0),
            "authentication": .string(registry.authenticationStatus(id: definition.id)),
            "access": providerAccess(definition, client: client),
            "capabilities": .object([
                "supportsTools": .bool(client?.supportsTools ?? false),
                "canLoadModels": .bool(client?.canLoadModels ?? false),
                "reasoningPolicy": .string((client?.reasoningPolicy ?? .unavailable).rawValue),
            ]),
            "gettingStarted": offer.map {
                .object([
                    "summary": .string($0.summary),
                    "priority": .int($0.priority),
                    "regions": .array($0.regions.sorted { $0.rawValue < $1.rawValue }.map { .string($0.rawValue) }),
                ])
            } ?? .null,
        ])
    }

    private func providerAccess(_ definition: ProviderDefinition, client: (any ProviderClient)?) -> JSONValue {
        var methods: [String] = []
        if definition.api == .web {
            methods.append("browser-session")
        } else {
            if client?.subscriptionAccount != nil {
                methods.append(definition.auth.kind == .oauth ? "oauth" : "subscription")
            }
            if let client, client.acceptsAPIKey {
                methods.append(client.credentialKind.providerInformationValue)
            }
            if methods.isEmpty {
                methods.append(definition.auth.kind == .none ? "none" : definition.auth.kind.rawValue)
            }
        }
        return .object([
            "methods": .array(methods.map(JSONValue.string)),
            "credentialKind": client.flatMap { $0.acceptsAPIKey ? $0.credentialKind.providerInformationValue : nil }.map(JSONValue.string) ?? .null,
            "acceptsSecret": .bool(definition.api != .web && client?.acceptsAPIKey == true),
            "optional": .bool(definition.auth.optional == true),
            "notice": client?.authNotice.map(JSONValue.string) ?? .null,
        ])
    }
}

private extension LLMCredentialKind {
    var providerInformationValue: String {
        switch self {
        case .apiKey: "api-key"
        case .subscriptionKey: "subscription-key"
        case .bearerToken: "bearer-token"
        }
    }
}

private extension LLMInferenceLocation {
    var providerInformationValue: String {
        switch self {
        case .remote: "remote"
        case .userHosted: "user-hosted"
        case .onDevice: "on-device"
        }
    }
}
