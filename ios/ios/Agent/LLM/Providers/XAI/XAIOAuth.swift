import Foundation

nonisolated struct XAITokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
}

nonisolated enum XAIOAuth {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let redirectURI = "http://127.0.0.1:56121/callback"
    static let responsesBaseURL = URL(string: "https://api.x.ai/v1")!

    private static let authorizeEndpoint = URL(string: "https://auth.x.ai/oauth2/authorize")!
    private static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!
    private static let scope = "openid profile email offline_access grok-cli:access api:access"

    static func authorizeURL(pkce: OAuthPKCE, state: String, nonce: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "plan", value: "generic"),
            URLQueryItem(name: "referrer", value: "ox"),
        ]
        return components.url!
    }

    static func exchangeCode(_ code: String, verifier: String) async throws -> XAITokens {
        try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refresh(_ tokens: XAITokens) async throws -> XAITokens {
        try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": clientID,
        ], fallbackRefresh: tokens.refreshToken, fallbackIDToken: tokens.idToken)
    }

    static func email(from tokens: XAITokens) -> String? {
        OAuthSupport.jwtClaims(tokens.idToken)?["email"] as? String
    }

    private static func postToken(
        _ form: [String: String],
        fallbackRefresh: String = "",
        fallbackIDToken: String = ""
    ) async throws -> XAITokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Ox/iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = OAuthSupport.formEncoded(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            Log.network.error("XAIOAuth.token status=\(status) grant=\(form["grant_type"] ?? "unknown")")
            throw XAIError(message: "xAI authorization HTTP \(status)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty
        else { throw XAIError(message: "xAI returned malformed authorization data") }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return XAITokens(
            accessToken: accessToken,
            refreshToken: (object["refresh_token"] as? String) ?? fallbackRefresh,
            idToken: (object["id_token"] as? String) ?? fallbackIDToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }
}

nonisolated struct XAIError: LLMClientError {
    let message: String
    let failureKind: LLMFailureKind = .authentication
}
