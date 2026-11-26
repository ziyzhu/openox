import Foundation

nonisolated struct OpenRouterCredential: Codable, Sendable {
    let apiKey: String
}

nonisolated enum OpenRouterOAuth {
    static let redirectURI = "http://localhost:14101/callback"
    static let apiBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    private static let authorizeEndpoint = URL(string: "https://openrouter.ai/auth")!
    private static let keyEndpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    private struct KeyRequest: Encodable {
        let code: String
        let codeVerifier: String
        let codeChallengeMethod = "S256"

        enum CodingKeys: String, CodingKey {
            case code
            case codeVerifier = "code_verifier"
            case codeChallengeMethod = "code_challenge_method"
        }
    }

    private struct KeyResponse: Decodable {
        let key: String
    }

    static func authorizeURL(pkce: OAuthPKCE) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    static func exchangeCode(_ code: String, verifier: String) async throws -> OpenRouterCredential {
        var request = URLRequest(url: keyEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Ox/iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(KeyRequest(code: code, codeVerifier: verifier))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            Log.network.error("OpenRouterOAuth.exchange status=\(status)")
            throw OpenRouterError(message: "OpenRouter authorization HTTP \(status)")
        }
        guard let response = try? JSONDecoder().decode(KeyResponse.self, from: data),
              !response.key.isEmpty
        else { throw OpenRouterError(message: "OpenRouter returned malformed authorization data") }
        return OpenRouterCredential(apiKey: response.key)
    }
}

nonisolated struct OpenRouterError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind = .authentication
}
