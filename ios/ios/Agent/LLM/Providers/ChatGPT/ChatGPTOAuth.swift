import Foundation

nonisolated struct ChatGPTTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accountID: String
}

nonisolated struct ChatGPTAuthError: LLMClientError {
    let message: String
    let failureKind: LLMFailureKind = .authentication
}

// The Codex "Sign in with ChatGPT" OAuth contract: PKCE against auth.openai.com
// using the public Codex CLI client id. The resulting access token authorizes
// the ChatGPT-backend Responses API — the same surface Codex uses — not the
// metered platform API.
nonisolated enum ChatGPTOAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = URL(string: "https://auth.openai.com")!
    static let originator = "codex_cli_rs"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let responsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let scope = "openid profile email offline_access"

    private static var authorizeEndpoint: URL { issuer.appendingPathComponent("oauth/authorize") }
    private static var tokenEndpoint: URL { issuer.appendingPathComponent("oauth/token") }

    static func authorizeURL(pkce: OAuthPKCE, state: String) -> URL {
        var c = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: originator),
        ]
        return c.url!
    }

    static func exchangeCode(_ code: String, verifier: String) async throws -> ChatGPTTokens {
        try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refresh(_ refreshToken: String) async throws -> ChatGPTTokens {
        try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ], fallbackRefresh: refreshToken)
    }

    private static func postToken(_ form: [String: String], fallbackRefresh: String? = nil) async throws -> ChatGPTTokens {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = OAuthSupport.formEncoded(form)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.network.error("ChatGPTOAuth.token grant=\(form["grant_type"] ?? "?") HTTP \(status): \(LogPrivacy.text(body, limit: 300))")
            throw ChatGPTAuthError(message: "ChatGPT token endpoint HTTP \(status)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTAuthError(message: "Malformed ChatGPT token response")
        }
        let access = obj["access_token"] as? String ?? ""
        let id = obj["id_token"] as? String ?? ""
        let refresh = (obj["refresh_token"] as? String) ?? fallbackRefresh ?? ""
        guard !access.isEmpty else { throw ChatGPTAuthError(message: "ChatGPT token response missing access_token") }
        return ChatGPTTokens(
            accessToken: access,
            refreshToken: refresh,
            idToken: id,
            accountID: accountID(fromIDToken: id)
        )
    }

    static func accountID(fromIDToken idToken: String) -> String {
        guard let auth = OAuthSupport.jwtClaims(idToken)?["https://api.openai.com/auth"] as? [String: Any],
              let acct = auth["chatgpt_account_id"] as? String else { return "" }
        return acct
    }

    static func email(fromIDToken idToken: String) -> String? {
        guard let email = OAuthSupport.jwtClaims(idToken)?["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    static func planType(fromAccessToken token: String) -> String? {
        guard let claims = OAuthSupport.jwtClaims(token) else { return nil }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let plan = auth["chatgpt_plan_type"] as? String { return plan }
        return claims["chatgpt_plan_type"] as? String
    }

    static func expiry(ofJWT token: String) -> Date? {
        guard let exp = OAuthSupport.jwtClaims(token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
