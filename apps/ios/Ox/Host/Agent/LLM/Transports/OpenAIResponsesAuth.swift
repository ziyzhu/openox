import Foundation

nonisolated public struct OpenAIResponsesEndpoint: Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

nonisolated public protocol OpenAIResponsesTransportAuth: Sendable {
    var canRefresh: Bool { get }
    func resolve(forceRefresh: Bool) async throws -> OpenAIResponsesEndpoint
}

nonisolated public struct OpenAIResponsesAPIKeyAuth: OpenAIResponsesTransportAuth {
    let clientID: String
    let baseURL: URL
    let extraHeaders: [String: String]

    public var canRefresh: Bool { false }
    public init(clientID: String, baseURL: URL, extraHeaders: [String: String] = [:]) {
        self.clientID = clientID
        self.baseURL = baseURL
        self.extraHeaders = extraHeaders
    }

    public func resolve(forceRefresh: Bool) async throws -> OpenAIResponsesEndpoint {
        guard let key = Credentials.key(for: clientID) else {
            throw OpenAIAuthError.missingAPIKey(clientID)
        }
        var url = baseURL
        url.appendPathComponent("responses")
        var headers = extraHeaders
        headers["Authorization"] = "Bearer \(key)"
        return OpenAIResponsesEndpoint(url: url, headers: headers)
    }
}
