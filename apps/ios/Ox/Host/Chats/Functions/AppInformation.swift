import Foundation

extension Conversation {
    public func renameChat(title: String, purpose: String) async throws -> JSONValue? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        guard !trimmed.isEmpty else {
            throw RuntimeError.bridge("ox.app.renameChat: title must not be empty.")
        }
        guard trimmed.count <= 60 else {
            throw RuntimeError.bridge("ox.app.renameChat: title must contain at most 60 characters.")
        }
        guard wordCount <= 10 else {
            throw RuntimeError.bridge("ox.app.renameChat: title must contain at most 10 words.")
        }
        let previousAgentTitle = latestAgentChatTitle
        let args = JSONValue.object(["title": .string(trimmed)])
        return try await tracked(Actions.appRenameChat, args, purpose: purpose) {
            if let customTitle, !customTitle.isEmpty, customTitle != previousAgentTitle {
                Log.session.info("bridge.app.renameChat preserved user title")
                return .object([
                    "renamed": .bool(false),
                    "title": .string(customTitle),
                ])
            }
            let renamed = customTitle != trimmed
            if renamed { rename(to: trimmed) }
            Log.session.info("bridge.app.renameChat agentTitle changed=\(renamed) words=\(wordCount) chars=\(trimmed.count)")
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

    public func appProfile(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appProfile, .object([:]), purpose: purpose) {
            StorageRoot.shared.active.map { active in
                JSONValue.object([
                    "name": .string(active.name),
                    "storage": .string(active.location.rawValue),
                ])
            } ?? .null
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

    public func appTheme(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appTheme, .object([:]), purpose: purpose) {
            let theme = ThemeManager.shared.theme
            return .object([
                "selection": .string(theme.rawValue),
                "appearance": .string(theme == .dark ? "dark" : "light"),
            ])
        }
    }

    public func setAppLanguage(selection: String, purpose: String) async throws -> JSONValue? {
        guard let language = AppLocale.Language(rawValue: selection) else {
            throw RuntimeError.bridge("ox.app.setLanguage: selection must be system, en, or zh-Hans")
        }
        return try await tracked(Actions.appSetLanguage, .object(["selection": .string(selection)]), purpose: purpose) {
            try Task.checkCancellation()
            let locale = AppLocale.shared
            let changed = locale.language != language
            locale.language = language
            Log.app.info("bridge.app.setLanguage selection=\(selection) changed=\(changed)")
            return .object([
                "selection": .string(locale.language.rawValue),
                "locale": .string(locale.locale.identifier),
                "changed": .bool(changed),
            ])
        }
    }

    public func setAppTheme(selection: String, purpose: String) async throws -> JSONValue? {
        guard let theme = AppTheme(rawValue: selection) else {
            throw RuntimeError.bridge("ox.app.setTheme: selection must be creatorPick, light, or dark")
        }
        return try await tracked(Actions.appSetTheme, .object(["selection": .string(selection)]), purpose: purpose) {
            try Task.checkCancellation()
            let manager = ThemeManager.shared
            let changed = manager.theme != theme
            manager.theme = theme
            Log.app.info("bridge.app.setTheme selection=\(selection) changed=\(changed)")
            return .object([
                "selection": .string(manager.theme.rawValue),
                "appearance": .string(manager.theme == .dark ? "dark" : "light"),
                "changed": .bool(changed),
            ])
        }
    }

    public func setAppDefaultModel(options: JSONValue, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appSetDefaultModel, options, purpose: purpose) {
            let registry = ProviderRegistry.shared
            let previous = registry.defaultModel
            guard let selection = options.objectValue?["selection"] else {
                throw RuntimeError.bridge("ox.app.setDefaultModel: selection is required; use null for automatic selection")
            }
            let resolved = selection == .null ? nil : try await self.resolveAppModelSelection(selection, current: previous)
            try Task.checkCancellation()
            guard registry.defaultModel == previous else {
                throw RuntimeError.bridge("The default model changed during verification; inspect it before retrying")
            }
            let changed = try registry.setDefaultModel(resolved?.selection)
            return .object([
                "configured": .bool(registry.defaultModel != nil),
                "selection": registry.defaultModel?.appInformation ?? .null,
                "changed": .bool(changed),
            ])
        }
    }

    public func setAppModel(options: JSONValue, purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appSetModel, options, purpose: purpose) {
            let previous = self.modelSelection
            let previousChange = self.modelSelectionChange
            guard let selection = options.objectValue?["selection"], selection != .null else {
                throw RuntimeError.bridge("ox.app.setModel: an explicit selection is required")
            }
            let resolved = try await self.resolveAppModelSelection(selection, current: previous, pending: previousChange?.pendingSelection)
            try Task.checkCancellation()
            guard self.modelSelection == previous, self.modelSelectionChange == previousChange else {
                throw RuntimeError.bridge("The chat model selection changed during verification; inspect it before retrying")
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
        if let authenticated = try await client.websiteSessionIsAuthenticated(), !authenticated {
            throw RuntimeError.bridge("Sign in to this website provider before selecting its model")
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

    public func appActionPolicies(options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let query = try AppActionPolicyQuery(options: options)
        return try await tracked(Actions.appActionPolicies, options ?? .object([:]), purpose: purpose) {
            query.read(
                serviceManager.actionPolicies,
                actionDefaultPolicy: query.action.map(serviceManager.defaultPolicy(for:))
            )
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

    public func appLogs(options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let query = try AppLogQuery(options: options)
        return try await tracked(Actions.appLogs, options ?? .object([:]), purpose: purpose) {
            try Task.checkCancellation()
            let snapshot = try await LogFile.shared.snapshot()
            try Task.checkCancellation()
            let result = query.read(snapshot)
            Log.session.info("bridge.app.logs entries=\(result.objectValue?["entries"]?.arrayValue?.count ?? 0) truncated=\(result.objectValue?["truncated"]?.boolValue ?? false)")
            return result
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

nonisolated struct AppLogQuery {
    let level: Logger.Level
    let category: String?
    let query: String?
    let since: Date?
    let limit: Int

    init(options: JSONValue?) throws {
        guard let fields = options?.objectValue,
              Set(fields.keys).isSubset(of: ["level", "category", "query", "since", "limit"]) else {
            throw RuntimeError.bridge("ox.app.logs: expected log filters.")
        }
        func string(_ key: String, maximum: Int) throws -> String? {
            guard let value = fields[key] else { return nil }
            guard let text = value.stringValue, !text.isEmpty, text.count <= maximum else {
                throw RuntimeError.bridge("ox.app.logs: invalid \(key).")
            }
            return text
        }
        let levels: [String: Logger.Level] = ["debug": .debug, "info": .info, "warning": .warning, "error": .error]
        guard let level = levels[try string("level", maximum: 7) ?? "debug"] else {
            throw RuntimeError.bridge("ox.app.logs: invalid level.")
        }
        self.level = level
        category = try string("category", maximum: 80)
        query = try string("query", maximum: 200)
        if let timestamp = try string("since", maximum: 40) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: timestamp)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: timestamp) else {
                throw RuntimeError.bridge("ox.app.logs: since must be an ISO 8601 timestamp with a time zone.")
            }
            since = date
        } else {
            since = nil
        }
        if let value = fields["limit"] {
            guard case .int(let count) = value, (1...100).contains(count) else {
                throw RuntimeError.bridge("ox.app.logs: limit must be an integer from 1 to 100.")
            }
            limit = count
        } else {
            limit = 50
        }
    }

    func read(_ snapshot: [LogEntry]) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var entries: [JSONValue] = []
        var bytes = 0
        var truncated = false
        for entry in snapshot.reversed() {
            guard entry.level >= level,
                  category == nil || entry.category == category,
                  since.map({ entry.date >= $0 }) ?? true else { continue }
            let message = LogPrivacy.text(entry.message, limit: Int.max)
            guard query.map({ message.localizedCaseInsensitiveContains($0) }) ?? true else { continue }
            let value = JSONValue.object([
                "timestamp": .string(formatter.string(from: entry.date)),
                "level": .string(entry.level.name),
                "category": .string(entry.category),
                "message": .string(String(message.prefix(2_048))),
                "truncated": .bool(message.count > 2_048),
            ])
            let size = value.jsonString(fallback: "").utf8.count
            guard entries.count < limit, bytes + size <= 64 * 1024 else {
                truncated = true
                break
            }
            entries.append(value)
            bytes += size
        }
        return .object([
            "entries": .array(entries),
            "truncated": .bool(truncated),
            "oldestAvailable": snapshot.first.map { .string(formatter.string(from: $0.date)) } ?? .null,
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
