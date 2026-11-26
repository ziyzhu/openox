import Foundation

nonisolated public struct OpenAIEndpoint: Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

nonisolated public protocol OpenAITransportAuth: Sendable {
    var canRefresh: Bool { get }
    func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint
}

nonisolated public enum OpenAIAuthError: ProviderClientError {
    case missingAPIKey(String)

    public var message: String {
        switch self {
        case .missingAPIKey(let clientID): return "Missing API key for \(clientID). Add one in provider settings."
        }
    }
}

nonisolated public struct OpenAIAPIKeyAuth: OpenAITransportAuth {
    let clientID: String
    let baseURL: URL
    let path: String
    let extraHeaders: [String: String]

    public init(clientID: String, baseURL: URL, path: String, extraHeaders: [String: String] = [:]) {
        self.clientID = clientID
        self.baseURL = baseURL
        self.path = path
        self.extraHeaders = extraHeaders
    }

    public var canRefresh: Bool { false }
    public func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint {
        guard let key = Credentials.key(for: clientID) else {
            throw OpenAIAuthError.missingAPIKey(clientID)
        }
        var headers = extraHeaders
        headers["Authorization"] = "Bearer \(key)"
        return OpenAIEndpoint(url: baseURL.appendingPathComponent(path), headers: headers)
    }
}

nonisolated public struct OpenAIOptionalAPIKeyAuth: OpenAITransportAuth {
    let clientID: String
    let baseURL: URL

    public var canRefresh: Bool { false }
    public func resolve(forceRefresh: Bool) async throws -> OpenAIEndpoint {
        var headers: [String: String] = [:]
        if let key = Credentials.key(for: clientID) {
            headers["Authorization"] = "Bearer \(key)"
        }
        return OpenAIEndpoint(url: baseURL.appendingPathComponent("chat/completions"), headers: headers)
    }
}
