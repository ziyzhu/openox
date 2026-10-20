import Foundation

nonisolated struct ChatGPTTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var clientID: String
    var subject: String
    var email: String?
    var scopes: Set<String>
    var expiresAt: Date

    var canInvoke: Bool { !accessToken.isEmpty && scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
}

nonisolated struct ChatGPTAuthError: ProviderClientError {
    let message: String
    var sessionExpired = false
    let failureKind: LLMFailureKind = .authentication
}

nonisolated enum ChatGPTOAuth {
    static let redirectURI = "http://127.0.0.1:1455/auth/callback"
    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!

    static func authorizeURL(pkce: OAuthPKCE, state: String, nonce: String, hostID: String, registration: ChatGPTTokens?) -> URL {
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var parameters = [
            "client_id": registration?.clientID ?? "dynamic_agent_client",
            "ext_agent_host_id": hostID,
            "response_type": "code",
            "redirect_uri": redirectURI,
            "scope": scope,
            "resource": resource,
            "state": state,
            "nonce": nonce,
            "code_challenge_method": "S256",
            "code_challenge": pkce.challenge,
        ]
        if let registration {
            if !registration.idToken.isEmpty { parameters["id_token_hint"] = registration.idToken }
            if let email = registration.email { parameters["login_hint"] = email }
            if !registration.accessToken.isEmpty, !registration.canInvoke { parameters["prompt"] = "consent" }
        } else {
            parameters["agent_name_hint"] = "OpenOx"
        }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func exchangeCode(_ code: String, clientID: String, verifier: String, nonce: String, registration: ChatGPTTokens?) async throws -> ChatGPTTokens {
        let response = try await postToken([
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": redirectURI, "code_verifier": verifier, "resource": resource,
        ])
        guard let idToken = response["id_token"] as? String else { throw ChatGPTAuthError(message: "ChatGPT did not return an ID token") }
        let identity = try await ChatGPTIDToken.validate(idToken, clientID: clientID, nonce: nonce)
        if let registration, identity.subject != registration.subject {
            throw ChatGPTAuthError(message: "ChatGPT returned a different account. The existing connection was not changed.")
        }
        return try tokens(response, clientID: clientID, subject: identity.subject, email: identity.email, previous: nil)
    }

    static func refresh(_ previous: ChatGPTTokens) async throws -> ChatGPTTokens {
        let response = try await postToken([
            "grant_type": "refresh_token", "refresh_token": previous.refreshToken,
            "client_id": previous.clientID, "resource": resource,
        ])
        if let idToken = response["id_token"] as? String {
            let identity = try await ChatGPTIDToken.validate(idToken, clientID: previous.clientID, nonce: nil)
            guard identity.subject == previous.subject else { throw ChatGPTAuthError(message: "ChatGPT refresh returned a different account", sessionExpired: true) }
        }
        return try tokens(response, clientID: previous.clientID, subject: previous.subject, email: previous.email, previous: previous)
    }

    static func revoke(_ tokens: ChatGPTTokens) async throws {
        guard !tokens.refreshToken.isEmpty else { return }
        let configuration = try await ChatGPTIDToken.configuration()
        guard let endpoint = configuration["revocation_endpoint"] as? String,
              let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" else {
            throw ChatGPTAuthError(message: "ChatGPT did not publish a valid revocation endpoint")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthSupport.formEncoded([
            "token": tokens.refreshToken, "token_type_hint": "refresh_token", "client_id": tokens.clientID,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTAuthError(message: "ChatGPT session revocation was not confirmed") }
    }

    private static func postToken(_ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthSupport.formEncoded(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = body?["error"]
            let code = (error as? String) ?? (error as? [String: Any])?["code"] as? String ?? "unknown"
            let expired = form["grant_type"] == "refresh_token" && [400, 401].contains(status)
                && ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_revoked", "refresh_token_invalidated", "refresh_token_reused"].contains(code)
            Log.network.error("ChatGPTOAuth.token grant=\(form["grant_type"] ?? "?") status=\(status) sessionExpired=\(expired)")
            throw ChatGPTAuthError(message: expired ? "ChatGPT session expired. Sign in again." : "ChatGPT token endpoint HTTP \(status)", sessionExpired: expired)
        }
        guard let body else { throw ChatGPTAuthError(message: "Malformed ChatGPT token response") }
        return body
    }

    private static func tokens(_ response: [String: Any], clientID: String, subject: String, email: String?, previous: ChatGPTTokens?) throws -> ChatGPTTokens {
        guard let access = response["access_token"] as? String, !access.isEmpty,
              let lifetime = response["expires_in"] as? Double, lifetime > 0,
              (response["token_type"] as? String)?.lowercased() == "bearer" else {
            throw ChatGPTAuthError(message: "ChatGPT returned invalid token credentials")
        }
        let scopes = (response["scope"] as? String).map { Set($0.split(separator: " ").map(String.init)) } ?? previous?.scopes ?? []
        return ChatGPTTokens(
            accessToken: access, refreshToken: response["refresh_token"] as? String ?? previous?.refreshToken ?? "",
            idToken: response["id_token"] as? String ?? previous?.idToken ?? "", clientID: clientID,
            subject: subject, email: email, scopes: scopes, expiresAt: Date().addingTimeInterval(lifetime)
        )
    }
}
