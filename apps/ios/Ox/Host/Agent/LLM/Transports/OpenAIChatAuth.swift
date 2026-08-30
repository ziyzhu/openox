import Foundation

nonisolated public struct OpenAIChatEndpoint: Sendable {
    public let baseURL: URL
    public let headers: [String: String]

    public init(baseURL: URL, headers: [String: String]) {
        self.baseURL = baseURL
        self.headers = headers
    }
}

// Resolves where an OpenAI-compatible request should go and how it authenticates.
// A pasted API key resolves to a fixed base URL and a static bearer; a
// subscription resolves to a token (and possibly a base URL) that may be
// refreshed when the server rejects the current one with a 401.
nonisolated public protocol OpenAIChatTransportAuth: Sendable {
    var canRefresh: Bool { get }
    func resolve(forceRefresh: Bool) async throws -> OpenAIChatEndpoint
}

nonisolated public enum OpenAIAuthError: ProviderClientError {
    case missingAPIKey(String)

    public var message: String {
        switch self {
        case .missingAPIKey(let clientID): return "Missing API key for \(clientID). Add one in provider settings."
        }
    }
}

nonisolated public struct OpenAIAPIKeyAuth: OpenAIChatTransportAuth {
    let clientID: String
    let baseURL: URL
    let extraHeaders: [String: String]

    public var canRefresh: Bool { false }
    public func resolve(forceRefresh: Bool) async throws -> OpenAIChatEndpoint {
        guard let key = Credentials.key(for: clientID) else {
            throw OpenAIAuthError.missingAPIKey(clientID)
        }
        var headers = extraHeaders
        headers["Authorization"] = "Bearer \(key)"
        return OpenAIChatEndpoint(baseURL: baseURL, headers: headers)
    }
}

nonisolated public struct OpenAIOptionalAPIKeyAuth: OpenAIChatTransportAuth {
    let clientID: String
    let baseURL: URL

    public var canRefresh: Bool { false }
    public func resolve(forceRefresh: Bool) async throws -> OpenAIChatEndpoint {
        var headers: [String: String] = [:]
        if let key = Credentials.key(for: clientID) {
            headers["Authorization"] = "Bearer \(key)"
        }
        return OpenAIChatEndpoint(baseURL: baseURL, headers: headers)
    }
}
