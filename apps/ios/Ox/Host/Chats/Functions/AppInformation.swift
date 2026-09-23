import AVFAudio
import Foundation

extension Chat {
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

    public func appVoice(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appVoice, .object([:]), purpose: purpose) {
            let settings = SpeechVoiceSettings.shared
            let voice = settings.preferredVoice(for: AppLocale.shared.locale)
            return .object([
                "selection": settings.selectedVoiceIdentifier.map(JSONValue.string) ?? .null,
                "effective": voice.map {
                    .object([
                        "id": .string($0.identifier),
                        "name": .string($0.name),
                        "language": .string($0.language),
                    ])
                } ?? .null,
            ])
        }
    }

    public func appVoiceOptions(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appVoiceOptions, .object([:]), purpose: purpose) {
            let settings = SpeechVoiceSettings.shared
            let locale = AppLocale.shared.locale
            let voices = settings.availableVoices(for: locale)
            let effective = settings.preferredVoice(for: locale)
            let limit = 100
            return .object([
                "selection": settings.selectedVoiceIdentifier.map(JSONValue.string) ?? .null,
                "effective": effective.map(Self.voiceInformation) ?? .null,
                "options": .array(voices.prefix(limit).map { voice in
                    var information = Self.voiceInformation(voice).objectValue ?? [:]
                    information["selected"] = .bool(voice.identifier == settings.selectedVoiceIdentifier)
                    information["effective"] = .bool(voice.identifier == effective?.identifier)
                    return .object(information)
                }),
                "truncated": .bool(voices.count > limit),
            ])
        }
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

    public func appServiceRepositories(purpose: String) async throws -> JSONValue? {
        try await tracked(Actions.appServiceRepositories, .object([:]), purpose: purpose) {
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
            let result = query.read(LogStore.shared.snapshot())
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
        } else if client.usesAPIKey {
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

    private static func voiceInformation(_ voice: AVSpeechSynthesisVoice) -> JSONValue {
        let quality = switch voice.quality {
        case .default: "basic"
        case .enhanced: "enhanced"
        case .premium: "premium"
        @unknown default: "unknown"
        }
        return .object([
            "id": .string(voice.identifier),
            "name": .string(voice.name),
            "language": .string(voice.language),
            "quality": .string(quality),
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

private extension ServiceRepository.Repository.State {
    var appInformationValue: String {
        switch self {
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
