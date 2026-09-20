import Foundation

extension Chat {
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
                return .array(registry.definitions.map {
                    .object(["id": .string($0.id), "name": .string($0.name), "api": .string($0.api.rawValue),
                             "models": .int($0.models.count), "authentication": .string(registry.authenticationStatus(id: $0.id))])
                })
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
            default: throw RuntimeError.bridge("Unknown provider operation")
            }
        }
    }

    private func authenticateProvider(_ definition: ProviderDefinition) async throws -> JSONValue {
        if definition.auth.kind == .none {
            return .object(["id": .string(definition.id), "status": .string("not-required")])
        }
        guard let presenter = presentations.providerAuthentication,
              let client = ProviderRegistry.shared.client(id: definition.id) else {
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
}
