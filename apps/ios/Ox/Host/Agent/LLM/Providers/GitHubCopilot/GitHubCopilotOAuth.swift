import Foundation

nonisolated struct GitHubCopilotTokens: Codable, Sendable {
    let accessToken: String
    let accountLabel: String?
    let availableModelIDs: [String]?

    func withAvailableModelIDs(_ ids: [String]) -> Self {
        Self(accessToken: accessToken, accountLabel: accountLabel, availableModelIDs: ids)
    }
}

nonisolated struct GitHubCopilotDeviceGrant: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let interval: TimeInterval
    let expiresAt: Date
}

nonisolated enum GitHubCopilotOAuth {
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            struct Policy: Decodable {
                let state: String?
            }

            struct Capabilities: Decodable {
                struct Supports: Decodable {
                    let toolCalls: Bool?

                    enum CodingKeys: String, CodingKey {
                        case toolCalls = "tool_calls"
                    }
                }

                let supports: Supports
            }

            let id: String
            let modelPickerEnabled: Bool
            let policy: Policy?
            let capabilities: Capabilities

            enum CodingKeys: String, CodingKey {
                case id
                case modelPickerEnabled = "model_picker_enabled"
                case policy
                case capabilities
            }

            var isPickerAvailable: Bool {
                modelPickerEnabled
                    && policy?.state != "disabled"
                    && capabilities.supports.toolCalls != false
            }

            var isPolicyAvailable: Bool {
                policy?.state == "enabled"
                    && capabilities.supports.toolCalls != false
            }
        }

        let data: [Model]

        var availableModelIDs: (ids: [String], source: String) {
            let pickerIDs = data.filter(\.isPickerAvailable).map(\.id)
            if !pickerIDs.isEmpty { return (pickerIDs, "picker") }
            return (data.filter(\.isPolicyAvailable).map(\.id), "policy")
        }
    }

    static let clientID = "Ov23li8tweQw6odWQebz"
    static let apiVersion = "2026-06-01"
    static let apiURL = URL(string: "https://api.githubcopilot.com")!

    private static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private static let accessTokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    private static let userURL = URL(string: "https://api.github.com/user")!

    private static var headers: [String: String] {
        [
            "Accept": "application/json",
            "User-Agent": "Ox/iOS",
            "X-GitHub-Api-Version": apiVersion,
        ]
    }

    static func requestDeviceGrant() async throws -> GitHubCopilotDeviceGrant {
        let object = try await post(deviceCodeURL, body: ["client_id": clientID, "scope": "read:user"])
        guard let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String,
              let verification = object["verification_uri"] as? String,
              let verificationURL = URL(string: verification)
        else { throw GitHubCopilotError(message: "GitHub returned a malformed device authorization") }
        let interval = (object["interval"] as? NSNumber)?.doubleValue ?? 5
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 900
        return GitHubCopilotDeviceGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: max(interval, 1),
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    static func poll(_ grant: GitHubCopilotDeviceGrant) async throws -> GitHubCopilotTokens {
        var interval = grant.interval
        while Date() < grant.expiresAt {
            try Task.checkCancellation()
            let object = try await post(accessTokenURL, body: [
                "client_id": clientID,
                "device_code": grant.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let accessToken = object["access_token"] as? String, !accessToken.isEmpty {
                let availableModelIDs: [String]?
                do {
                    availableModelIDs = try await Self.availableModelIDs(accessToken: accessToken)
                } catch {
                    availableModelIDs = nil
                    Log.network.warning("GitHubCopilotOAuth models unavailable: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
                }
                return GitHubCopilotTokens(
                    accessToken: accessToken,
                    accountLabel: await accountLabel(accessToken: accessToken),
                    availableModelIDs: availableModelIDs
                )
            }
            switch object["error"] as? String {
            case "authorization_pending": break
            case "slow_down": interval += 5
            case "access_denied": throw GitHubCopilotError(message: "GitHub authorization was denied")
            case "expired_token": throw GitHubCopilotError(message: "GitHub device code expired")
            case let error?: throw GitHubCopilotError(message: "GitHub authorization failed: \(error)")
            case nil: break
            }
            try await Task.sleep(for: .seconds(interval + 3))
        }
        throw GitHubCopilotError(message: "GitHub device authorization timed out")
    }

    static func availableModelIDs(accessToken: String) async throws -> [String] {
        var url = apiURL
        url.appendPathComponent("models")
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            Log.network.error("GitHubCopilotOAuth models status=\(status)")
            throw GitHubCopilotError(message: "GitHub Copilot could not load the models available to this account")
        }
        guard let models = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw GitHubCopilotError(message: "GitHub Copilot returned a malformed model list")
        }
        let available = models.availableModelIDs
        Log.network.info("GitHubCopilotOAuth models available=\(available.ids.count) source=\(available.source) ids=\(available.ids.joined(separator: ","))")
        return available.ids
    }

    private static func post(_ url: URL, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Ox/iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            Log.network.error("GitHubCopilotOAuth POST status=\(status) path=\(url.path)")
            throw GitHubCopilotError(message: "GitHub authorization HTTP \(status)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubCopilotError(message: "GitHub returned malformed authorization data")
        }
        return object
    }

    private static func accountLabel(accessToken: String) async -> String? {
        var request = URLRequest(url: userURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ox/iOS", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["login"] as? String
    }
}

nonisolated struct GitHubCopilotError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(message: String, failureKind: LLMFailureKind = .authentication) {
        self.message = message
        self.failureKind = failureKind
    }
}
