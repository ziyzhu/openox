import Foundation
import CryptoKit

nonisolated extension ProviderDefinition {
    var credentialID: String {
        if auth.kind == .custom { return id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(auth)) ?? Data()
        let destination = Data(url.absoluteString.utf8) + data
        let digest = SHA256.hash(data: destination).map { String(format: "%02x", $0) }.joined()
        return "provider:\(id):\(digest)"
    }
}

nonisolated struct ProviderRequestAuthentication: OpenAIChatTransportAuth, OpenAIResponsesTransportAuth {
    let definition: ProviderDefinition
    let account: ProviderOAuthAccount?

    var canRefresh: Bool { account != nil }

    func headers(forceRefresh: Bool = false) async throws -> [String: String] {
        var headers = definition.options?.headers ?? [:]
        let credential: String?
        if let account, account.isSignedIn {
            credential = try await account.accessToken(forceRefresh: forceRefresh)
        } else {
            credential = Credentials.key(for: definition.credentialID)
        }
        switch definition.auth.kind {
        case .none: break
        case .bearer, .oauth:
            if let credential { headers["Authorization"] = "Bearer \(credential)" }
            else if definition.auth.requiresCredential { throw OpenAIAuthError.missingAPIKey(definition.id) }
        case .apiKey:
            if let credential { headers[definition.auth.header ?? "x-api-key"] = credential }
            else if definition.auth.requiresCredential { throw OpenAIAuthError.missingAPIKey(definition.id) }
        case .custom:
            throw RuntimeError.bridge("Custom authentication requires its registered adapter")
        }
        return headers
    }

    func resolve(forceRefresh: Bool) async throws -> OpenAIChatEndpoint {
        OpenAIChatEndpoint(baseURL: definition.url, headers: try await headers(forceRefresh: forceRefresh))
    }

    func resolve(forceRefresh: Bool) async throws -> OpenAIResponsesEndpoint {
        OpenAIResponsesEndpoint(url: definition.url.appendingPathComponent("responses"), headers: try await headers(forceRefresh: forceRefresh))
    }
}

nonisolated final class ProviderOAuthAccount: SubscriptionAccount, @unchecked Sendable {
    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date?
    }

    let definition: ProviderDefinition
    private let store: SubscriptionTokenStore<Tokens>

    init(_ definition: ProviderDefinition) {
        self.definition = definition
        store = SubscriptionTokenStore(key: "oauth:\(definition.credentialID)")
    }

    var providerName: String { definition.name }
    var isSignedIn: Bool { store.current() != nil }
    var planLabel: String? { nil }
    var policyNotice: String? { nil }
    var accountLabel: String? { store.current()?.idToken.flatMap(OAuthSupport.jwtClaims)?["email"] as? String }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let tokens = store.current() else { throw RuntimeError.bridge("Not authenticated with \(providerName)") }
        let expiring = tokens.expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false
        guard forceRefresh || expiring else { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            if expiring || forceRefresh { throw RuntimeError.bridge("Authentication expired; reconnect to \(providerName)") }
            return tokens.accessToken
        }
        let refresh = store.refreshTask(source: refreshToken) { [self] in
            let response = try await post(definition.auth.tokenURL!, fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": definition.auth.clientID!,
            ])
            return try decodeTokens(response, previous: tokens)
        }
        do {
            let refreshed = try await refresh.task.value
            try Task.checkCancellation()
            _ = store.install(refreshed, from: refresh)
            guard let current = store.current() else { throw RuntimeError.bridge("Authentication was cleared") }
            return current.accessToken
        } catch {
            store.clear(refresh)
            throw error
        }
    }

    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool {
        let generation = store.beginSignIn()
        let tokens: Tokens?
        switch definition.auth.flow {
        case .authorizationCode:
            tokens = try await authorize(using: presenter)
        case .deviceCode:
            let result = try await requestDeviceGrant()
            let poll = Task { try await self.pollDeviceGrant(result, generation: generation) }
            let completed = await presenter.device(result.verificationURL, result.userCode) { try await poll.value }
            poll.cancel()
            if !completed { store.cancelSignIn(expectedGeneration: generation) }
            return completed && isSignedIn
        case nil:
            throw RuntimeError.bridge("Missing OAuth flow")
        }
        guard let tokens else { return false }
        try Task.checkCancellation()
        return store.persist(tokens, expectedGeneration: generation)
    }

    @MainActor func signOut() { store.persist(nil) }

    @MainActor private func authorize(using presenter: SubscriptionAuthorizationPresenter) async throws -> Tokens? {
        let auth = definition.auth
        let pkce = OAuthSupport.makePKCE()
        let state = UUID().uuidString
        var components = URLComponents(url: auth.authorizeURL!, resolvingAgainstBaseURL: false)!
        var parameters = auth.authorizeParams ?? [:]
        parameters.merge([
            "response_type": "code", "client_id": auth.clientID!, "redirect_uri": auth.redirectURI!,
            "scope": (auth.scopes ?? []).joined(separator: " "), "state": state,
            "code_challenge": pkce.challenge, "code_challenge_method": "S256",
        ]) { _, value in value }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let callback = await presenter.oauth(components.url!, auth.redirectURI!) else { return nil }
        guard Self.matchesCallback(callback, expected: auth.redirectURI!),
              OAuthSupport.queryValue("state", in: callback) == state,
              let code = OAuthSupport.queryValue("code", in: callback), !code.isEmpty else {
            throw RuntimeError.bridge("OAuth returned an invalid callback")
        }
        let response = try await post(auth.tokenURL!, fields: [
            "grant_type": "authorization_code", "code": code, "client_id": auth.clientID!,
            "redirect_uri": auth.redirectURI!, "code_verifier": pkce.verifier,
        ])
        return try decodeTokens(response)
    }

    private struct DeviceGrant: Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: TimeInterval
        let expiresAt: Date
    }

    private func requestDeviceGrant() async throws -> DeviceGrant {
        let response = try await post(definition.auth.deviceAuthorizationURL!, fields: [
            "client_id": definition.auth.clientID!, "scope": (definition.auth.scopes ?? []).joined(separator: " "),
        ])
        guard let code = response["device_code"]?.stringValue, !code.isEmpty,
              let userCode = response["user_code"]?.stringValue, !userCode.isEmpty,
              let uri = response["verification_uri"]?.stringValue, let url = URL(string: uri),
              let expires = response["expires_in"]?.doubleValue, expires > 0 else {
            throw RuntimeError.bridge("OAuth returned an invalid device authorization")
        }
        try ProviderDefinition.validateURL(url, field: "verification_uri", allowHTTP: false)
        return DeviceGrant(deviceCode: code, userCode: userCode, verificationURL: url,
                           interval: max(response["interval"]?.doubleValue ?? 5, 1), expiresAt: Date().addingTimeInterval(expires))
    }

    private func pollDeviceGrant(_ grant: DeviceGrant, generation: UInt64) async throws -> Bool {
        var interval = grant.interval
        while Date() < grant.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            let response = try await post(definition.auth.tokenURL!, fields: [
                "client_id": definition.auth.clientID!, "device_code": grant.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ], allowOAuthError: true)
            switch response["error"]?.stringValue {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied", "expired_token": throw RuntimeError.bridge("OAuth device authorization ended without authorization")
            case .some: throw RuntimeError.bridge("OAuth device authorization failed")
            case nil:
                let tokens = try decodeTokens(response)
                try Task.checkCancellation()
                return store.persist(tokens, expectedGeneration: generation)
            }
        }
        throw RuntimeError.bridge("OAuth device authorization expired")
    }

    private func post(_ url: URL, fields: [String: String], allowOAuthError: Bool = false) async throws -> [String: JSONValue] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch definition.auth.requestEncoding ?? .form {
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = OAuthSupport.formEncoded(fields)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(fields)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        Log.network.info("ProviderOAuth exchange provider=\(definition.id) status=\(status)")
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              (200..<300).contains(status) || allowOAuthError && status == 400 && object["error"] != nil else {
            throw RuntimeError.bridge("OAuth endpoint returned HTTP \(status)")
        }
        return object
    }

    private func decodeTokens(_ response: [String: JSONValue], previous: Tokens? = nil) throws -> Tokens {
        guard let access = response["access_token"]?.stringValue, !access.isEmpty,
              response["token_type"]?.stringValue?.lowercased() == "bearer" else {
            throw RuntimeError.bridge("OAuth returned an invalid bearer-token response")
        }
        let expires = response["expires_in"]?.doubleValue
        guard expires.map({ $0 > 0 }) ?? true else { throw RuntimeError.bridge("OAuth returned an invalid token expiry") }
        return Tokens(accessToken: access, refreshToken: response["refresh_token"]?.stringValue ?? previous?.refreshToken,
                      idToken: response["id_token"]?.stringValue ?? previous?.idToken,
                      expiresAt: expires.map { Date().addingTimeInterval($0) })
    }

    static func matchesCallback(_ callback: URL, expected: String) -> Bool {
        guard let actual = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let target = URLComponents(string: expected) else { return false }
        return actual.scheme == target.scheme && actual.host == target.host && actual.port == target.port && actual.path == target.path
            && actual.user == nil && actual.password == nil && actual.fragment == nil
    }
}
