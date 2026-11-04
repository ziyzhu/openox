import Foundation

extension Conversation {
    public func renameConversation(title: String, purpose: String) async throws -> JSONValue? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RuntimeError.bridge("ox.conversation.rename: title must not be empty.")
        }
        guard trimmed.count <= 50 else {
            throw RuntimeError.bridge("ox.conversation.rename: title must contain at most 50 characters.")
        }
        let previousAgentTitle = latestAgentConversationTitle
        let args = JSONValue.object(["title": .string(trimmed)])
        return try await tracked(Actions.appRenameConversation, args, purpose: purpose) {
            if let customTitle, !customTitle.isEmpty, customTitle != previousAgentTitle {
                Log.session.info("bridge.app.renameConversation preserved user title")
                return .object([
                    "renamed": .bool(false),
                    "title": .string(customTitle),
                ])
            }
            let renamed = customTitle != trimmed
            if renamed { rename(to: trimmed) }
            Log.session.info("bridge.app.renameConversation agentTitle changed=\(renamed) chars=\(trimmed.count)")
            return .object([
                "renamed": .bool(renamed),
                "title": .string(trimmed),
            ])
        }
    }

    public func appInfo(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appInfo, .object([:]), purpose: purpose) {
            .object([
                "name": .string("Ox"),
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                "build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                "region": .string(AppRegion.shared.region.rawValue),
            ])
        }
    }

    public func appProfiles(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appProfiles, .object([:]), purpose: purpose) {
            let storage = StorageRoot.shared
            let limit = 100
            return .object([
                "profiles": .array(storage.profiles.prefix(limit).map { profile in
                    .object([
                        "name": .string(profile.name),
                        "storage": .string(profile.location.rawValue),
                        "active": .bool(profile.id == storage.activeId),
                    ])
                }),
                "truncated": .bool(storage.profiles.count > limit),
            ])
        }
    }

    public func appNotifications(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appNotifications, .object([:]), purpose: purpose) {
            let status = await NativePermission.notifications.state()
            return .object([
                "status": .string(status.appInformationValue),
            ])
        }
    }

    public func appLanguage(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appLanguage, .object([:]), purpose: purpose) {
            .object([
                "selection": .string(AppLocale.shared.language.rawValue),
                "locale": .string(AppLocale.shared.locale.identifier),
            ])
        }
    }

    public func setAppModel(options: JSONValue, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appSetModel, options, purpose: purpose) {
            let previous = self.modelSelection
            let previousChange = self.modelSelectionChange
            guard let selection = options.objectValue?["selection"], selection != .null else {
                throw RuntimeError.bridge("ox.conversation.setModel: an explicit selection is required")
            }
            let resolved = try await self.resolveAppModelSelection(selection, current: previous, pending: previousChange?.pendingSelection)
            try Task.checkCancellation()
            guard self.modelSelection == previous, self.modelSelectionChange == previousChange else {
                throw RuntimeError.bridge("The conversation model selection changed during verification; inspect it before retrying")
            }
            let changed = (previousChange?.pendingSelection ?? previous) != resolved.selection
            let status = self.requestModelSelection(resolved)
            return .object([
                "status": .string(status),
                "selection": resolved.selection.appInformation,
                "changed": .bool(changed),
            ])
        }
    }

    private func resolveAppModelSelection(_ value: JSONValue, current: ModelSelection?, pending: ModelSelection? = nil) async throws -> ProviderRegistry.SelectedModel {
        guard let fields = value.objectValue,
              let provider = fields["provider"]?.stringValue, !provider.isEmpty,
              let model = fields["model"]?.stringValue, !model.isEmpty else {
            throw RuntimeError.bridge("Model selection requires an existing provider and exact model ID")
        }
        let previous: ModelSelection? = if let pending, pending.providerID == provider, pending.modelID == model { pending } else { current }
        let effort = if fields["thinkingLevel"] != nil {
            fields["thinkingLevel"]?.stringValue
        } else if previous?.providerID == provider, previous?.modelID == model {
            previous?.reasoningEffort
        } else { nil as String? }
        let registry = ProviderRegistry.shared
        let selection = ModelSelection(providerID: provider, modelID: model, reasoningEffort: effort)
        guard let client = registry.client(id: provider), client.models.contains(where: { $0.id == model }) else {
            throw RuntimeError.bridge("Choose an existing provider from ox.provider.list and an exact available model ID from ox.provider.get")
        }
        return try registry.resolveSelection(selection)
    }

    public func appModel(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appModel, .object([:]), purpose: purpose) {
            .object([
                "provider": .object([
                    "id": .string(client.id),
                    "name": .string(client.displayName),
                ]),
                "model": .object([
                    "id": .string(model.id),
                    "name": .string(model.displayName),
                ]),
                "supportsTools": .bool(client.supportsTools(for: model)),
                "thinkingLevel": model.selectedReasoningEffort.map(JSONValue.string) ?? .null,
                "change": modelSelectionChange?.appInformation ?? .null,
                "authentication": modelAuthentication(for: client),
            ])
        }
    }

    public func appDefaultModel(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appDefaultModel, .object([:]), purpose: purpose) {
            let registry = ProviderRegistry.shared
            let selection = registry.sessionModel
            let defaultClient = registry.client(for: selection)
            let defaultModel = registry.model(for: selection, client: defaultClient)
            return .object([
                "configured": .bool(registry.defaultModel != nil),
                "region": .string(selection.region.rawValue),
                "provider": .object([
                    "id": .string(defaultClient.id),
                    "name": .string(defaultClient.displayName),
                ]),
                "model": .object([
                    "id": .string(defaultModel.id),
                    "name": .string(defaultModel.displayName),
                ]),
                "thinkingLevel": defaultModel.selectedReasoningEffort.map(JSONValue.string) ?? .null,
                "supportsTools": .bool(defaultClient.supportsTools(for: defaultModel)),
                "authentication": modelAuthentication(for: defaultClient),
            ])
        }
    }

    public func appRepositories(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appRepositories, .object([:]), purpose: purpose) {
            let repositories = serviceManager.repositories
            let limit = 50
            return .object([
                "status": .string(serviceManager.repositoryState.appInformationValue),
                "repositories": .array(repositories.prefix(limit).map { repository in
                    .object([
                        "id": .string(repository.id),
                        "path": .string("repositories/\(repository.id)"),
                        "name": .string(repository.name),
                        "provenance": .string(repository.provenance.rawValue),
                        "enabled": .bool(repository.isEnabled),
                        "state": .string(repository.state.appInformationValue),
                        "serviceCount": .int(repository.serviceCount),
                        "skillCount": .int(repository.skills.count),
                    ])
                }),
                "truncated": .bool(repositories.count > limit),
            ])
        }
    }

    private func modelAuthentication(for client: any ProviderClient) -> JSONValue {
        let account = client.subscriptionAccount
        let hasCredential = client.acceptsAPIKey && Credentials.key(for: client.credentialID) != nil
        let method: String
        let status: String
        if account?.isSignedIn == true {
            method = "subscription"
            status = "ready"
        } else if hasCredential {
            method = client.credentialKind.appInformationValue
            status = "ready"
        } else if account != nil {
            method = "subscription"
            status = "signedOut"
        } else if client.usesAPIKey, (try? ProviderRegistry.shared.definition(id: client.id).auth.requiresCredential) != false {
            method = client.credentialKind.appInformationValue
            status = "missingCredential"
        } else {
            method = "none"
            status = "notRequired"
        }
        return .object([
            "method": .string(method),
            "status": .string(status),
            "settingsPath": .string("Settings > Model"),
        ])
    }

}

nonisolated struct AppActionPolicyQuery {
    let source: String?
    let action: String?
    let query: String?
    let limit: Int

    init(options: JSONValue?) throws {
        guard let fields = options?.objectValue,
              Set(fields.keys).isSubset(of: ["source", "action", "query", "limit"]) else {
            throw RuntimeError.bridge("ox.app.actionPolicies: expected policy filters.")
        }
        func string(_ key: String, maximum: Int) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value.stringValue, !text.isEmpty, text.count <= maximum else {
                throw RuntimeError.bridge("ox.app.actionPolicies: invalid \(key).")
            }
            return text
        }
        source = try string("source", maximum: 500)
        action = try string("action", maximum: 500)
        query = try string("query", maximum: 200)
        if let value = fields["limit"] {
            guard case .int(let count) = value, (1...100).contains(count) else {
                throw RuntimeError.bridge("ox.app.actionPolicies: limit must be an integer from 1 to 100.")
            }
            limit = count
        } else {
            limit = 50
        }
    }

    func read(
        _ configuration: ActionPolicyConfiguration,
        actionDefaultPolicy: ActionPolicy? = nil
    ) -> JSONValue {
        let sourceOverrides = configuration.sources
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .compactMap { name, policy -> JSONValue? in
                guard source == nil || source == name,
                      action == nil,
                      query.map({ name.localizedCaseInsensitiveContains($0) }) ?? true else { return nil }
                return .object([
                    "scope": .string("source"),
                    "id": .string(name),
                    "source": .string(name),
                    "policy": .string(policy.rawValue),
                ])
            }
        let actionOverrides = configuration.actions
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .compactMap { name, policy -> JSONValue? in
                let sourceID = ActionPolicyConfiguration.sourceID(for: name)
                guard source == nil || source == sourceID,
                      action == nil || action == name,
                      query.map({ name.localizedCaseInsensitiveContains($0) || sourceID.localizedCaseInsensitiveContains($0) }) ?? true else { return nil }
                return .object([
                    "scope": .string("action"),
                    "id": .string(name),
                    "source": .string(sourceID),
                    "policy": .string(policy.rawValue),
                ])
            }
        let matches = sourceOverrides + actionOverrides
        return .object([
            "defaultPolicy": configuration.defaultPolicy.map { .string($0.rawValue) } ?? .null,
            "resolved": action.map { name in
                let sourceID = ActionPolicyConfiguration.sourceID(for: name)
                let inheritedFrom: String
                if configuration.actions[name] != nil { inheritedFrom = "action" }
                else if configuration.sources[sourceID] != nil { inheritedFrom = "source" }
                else if configuration.defaultPolicy != nil { inheritedFrom = "default" }
                else { inheritedFrom = "actionDefault" }
                return .object([
                    "action": .string(name),
                    "source": .string(sourceID),
                    "policy": .string(configuration.policy(for: name, default: actionDefaultPolicy ?? .ask).rawValue),
                    "inheritedFrom": .string(inheritedFrom),
                ])
            } ?? .null,
            "overrides": .array(Array(matches.prefix(limit))),
            "truncated": .bool(matches.count > limit),
        ])
    }
}

private extension LLMCredentialKind {
    var appInformationValue: String {
        switch self {
        case .apiKey: "apiKey"
        case .subscriptionKey: "subscriptionKey"
        case .bearerToken: "bearerToken"
        }
    }
}

private extension NativePermissionState {
    var appInformationValue: String {
        switch self {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        }
    }
}

private extension ServiceManager.RepositoryState {
    var appInformationValue: String {
        switch self {
        case .idle: "idle"
        case .syncing: "syncing"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}

private extension Repository.Descriptor.State {
    var appInformationValue: String {
        switch self {
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
