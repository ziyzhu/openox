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
        return try await tracked(.appRenameChat, args, purpose: purpose) {
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
        try await tracked(.appInfo, .object([:]), purpose: purpose) {
            .object([
                "name": .string("Ox"),
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                "build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                "region": .string(AppRegion.shared.region.rawValue),
            ])
        }
    }

    public func appProfile(purpose: String) async throws -> JSONValue? {
        try await tracked(.appProfile, .object([:]), purpose: purpose) {
            StorageRoot.shared.active.map { active in
                JSONValue.object([
                    "name": .string(active.name),
                    "storage": .string(active.location.rawValue),
                ])
            } ?? .null
        }
    }

    public func appNotifications(purpose: String) async throws -> JSONValue? {
        try await tracked(.appNotifications, .object([:]), purpose: purpose) {
            let status = await NativePermission.notifications.state()
            return .object([
                "status": .string(status.appInformationValue),
            ])
        }
    }

    public func appLanguage(purpose: String) async throws -> JSONValue? {
        try await tracked(.appLanguage, .object([:]), purpose: purpose) {
            .object([
                "selection": .string(AppLocale.shared.language.rawValue),
                "locale": .string(AppLocale.shared.locale.identifier),
            ])
        }
    }

    public func appTheme(purpose: String) async throws -> JSONValue? {
        try await tracked(.appTheme, .object([:]), purpose: purpose) {
            let theme = ThemeManager.shared.theme
            return .object([
                "selection": .string(theme.rawValue),
                "appearance": .string(theme == .dark ? "dark" : "light"),
            ])
        }
    }

    public func appVoice(purpose: String) async throws -> JSONValue? {
        try await tracked(.appVoice, .object([:]), purpose: purpose) {
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

    public func appModel(purpose: String) async throws -> JSONValue? {
        try await tracked(.appModel, .object([:]), purpose: purpose) {
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
                "authentication": currentModelAuthentication(),
            ])
        }
    }

    public func appLogs(options: JSONValue?, purpose: String) async throws -> JSONValue? {
        let query = try AppLogQuery(options: options)
        return try await tracked(.appLogs, options ?? .object([:]), purpose: purpose) {
            try await requireApproval(
                action: InvocationName.appLogs.rawValue,
                prompt: "\(L10n.string("Logs"))\n\(L10n.string("Logs may include private data from other chats and Profiles and become available to the current model. Always approve applies to all app logs."))"
            )
            try Task.checkCancellation()
            let result = query.read(LogStore.shared.snapshot())
            Log.session.info("bridge.app.logs entries=\(result.objectValue?["entries"]?.arrayValue?.count ?? 0) truncated=\(result.objectValue?["truncated"]?.boolValue ?? false)")
            return result
        }
    }

    private func currentModelAuthentication() -> JSONValue {
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
