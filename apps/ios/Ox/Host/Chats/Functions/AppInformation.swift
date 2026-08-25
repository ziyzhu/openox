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

    public func inspectApp(purpose: String) async throws -> JSONValue? {
        try await tracked(.appInspect, .object([:]), purpose: purpose) {
            let notificationStatus = await NativePermission.notifications.state()
            let authentication = currentModelAuthentication()
            let profile = StorageRoot.shared.active.map { active in
                JSONValue.object([
                    "name": .string(active.name),
                    "storage": .string(active.location.rawValue),
                    "settingsPath": .string("Settings > Profiles"),
                ])
            } ?? .null
            let result = JSONValue.object([
                "app": .object([
                    "name": .string("Ox"),
                    "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"),
                    "build": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
                    "region": .string(AppRegion.shared.region.rawValue),
                    "language": .string(AppLocale.shared.locale.identifier),
                ]),
                "model": .object([
                    "provider": .object([
                        "id": .string(client.id),
                        "name": .string(client.displayName),
                    ]),
                    "model": .object([
                        "id": .string(model.id),
                        "name": .string(model.displayName),
                    ]),
                    "supportsTools": .bool(client.supportsTools(for: model)),
                    "authentication": authentication.value,
                ]),
                "profile": profile,
                "setup": .object([
                    "coreStatus": .string(authentication.ready ? "ready" : "actionRequired"),
                    "notifications": .object([
                        "status": .string(notificationStatus.appInformationValue),
                        "required": .bool(false),
                        "settingsPath": .string("Settings > Notifications"),
                    ]),
                    "siri": .object([
                        "status": .string("notInspectable"),
                        "required": .bool(false),
                        "settingsPath": .string("Settings > Siri"),
                    ]),
                    "tourSettingsPath": .string("Settings > Take the tour"),
                ]),
            ])
            Log.session.info("bridge.app.inspect auth=\(authentication.status) notifications=\(notificationStatus.appInformationValue) profile=\(profile == .null ? "none" : "active")")
            return result
        }
    }

    private func currentModelAuthentication() -> (value: JSONValue, ready: Bool, status: String) {
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
        return (
            .object([
                "method": .string(method),
                "status": .string(status),
                "settingsPath": .string("Settings > Model"),
            ]),
            status == "ready" || status == "notRequired",
            status
        )
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
