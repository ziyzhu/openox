import CryptoKit
import Foundation

nonisolated struct RemoteMCPAuthorizationChallenge: Sendable {
    let resourceMetadataURL: URL?
    let scope: String?

    init(header: String?) {
        resourceMetadataURL = Self.parameter("resource_metadata", in: header).flatMap(URL.init(string:))
        scope = Self.parameter("scope", in: header)
    }

    private static func parameter(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|[,\\s])\(escaped)=(?:\"([^\"]*)\"|([^,\\s]+))"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = expression.firstMatch(in: header, range: range) else { return nil }
        for index in 1..<match.numberOfRanges {
            let matchRange = match.range(at: index)
            if matchRange.location != NSNotFound, let range = Range(matchRange, in: header) {
                return String(header[range])
            }
        }
        return nil
    }
}

nonisolated private struct RemoteMCPProtectedResourceMetadata: Decodable, Sendable {
    let resource: String
    let authorizationServers: [String]
    let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

nonisolated private struct RemoteMCPAuthorizationServerMetadata: Decodable, Sendable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String?
    let codeChallengeMethodsSupported: [String]?
    let tokenEndpointAuthMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }
}

nonisolated private struct RemoteMCPClientRegistration: Codable, Sendable {
    let clientID: String
    let clientSecret: String?
    let tokenEndpointAuthMethod: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

nonisolated private struct RemoteMCPTokenResponse: Decodable, Sendable {
    let accessToken: String
    let tokenType: String
    let refreshToken: String?
    let expiresIn: Double?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

nonisolated private struct RemoteMCPOAuthServer: Codable, Sendable {
    let resource: URL
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let scope: String?
}

nonisolated private struct RemoteMCPOAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresAt: Date?
    let scope: String?

    var needsRefresh: Bool {
        expiresAt.map { $0 <= Date().addingTimeInterval(60) } ?? false
    }
}

nonisolated private struct RemoteMCPOAuthCredential: Codable, Sendable {
    let server: RemoteMCPOAuthServer
    let registration: RemoteMCPClientRegistration
    var tokens: RemoteMCPOAuthTokens?
}

nonisolated private struct RemoteMCPHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

nonisolated private final class RemoteMCPOAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
enum RemoteMCPOAuth {
    private static let redirectURI = "http://localhost:49213/oauth/callback"
    private static let maxResponseBytes = 1 * 1_024 * 1_024

    static func accessToken(endpoint: URL, forceRefresh: Bool = false) async throws -> String? {
        guard var credential = load(endpoint: endpoint), let tokens = credential.tokens else { return nil }
        guard forceRefresh || tokens.needsRefresh else { return tokens.accessToken }
        guard let refreshToken = tokens.refreshToken else { return forceRefresh ? nil : tokens.accessToken }
        credential.tokens = try await refresh(refreshToken: refreshToken, credential: credential)
        save(credential, endpoint: endpoint)
        Log.service.info("RemoteMCPOAuth.refresh completed endpoint=\(LogPrivacy.url(endpoint.absoluteString))")
        return credential.tokens?.accessToken
    }

    static func authorize(endpoint: URL, challenge: RemoteMCPAuthorizationChallenge) async throws -> String {
        let server = try await discover(endpoint: endpoint, challenge: challenge)
        var credential = load(endpoint: endpoint)
        if credential?.server.issuer != server.issuer || credential?.server.resource != server.resource {
            credential = nil
        }
        if credential == nil {
            let registration = try await register(server: server)
            credential = RemoteMCPOAuthCredential(server: server, registration: registration, tokens: nil)
            save(credential!, endpoint: endpoint)
        }
        guard let credential else { throw RemoteMCPError.oauth("Ox could not prepare this OAuth client.") }
        return try await authorize(endpoint: endpoint, credential: credential)
    }

    static func reauthorize(endpoint: URL) async throws -> String {
        guard let credential = load(endpoint: endpoint) else {
            throw RemoteMCPError.oauth("Connect to this MCP server again to discover its OAuth settings.")
        }
        return try await authorize(endpoint: endpoint, credential: credential)
    }

    static func hasCredential(endpoint: URL) -> Bool {
        load(endpoint: endpoint) != nil
    }

    static func advertisesAuthorization(endpoint: URL) async -> Bool {
        guard let protectedResource = try? await discoverProtectedResource(
            endpoint: endpoint,
            challenge: RemoteMCPAuthorizationChallenge(header: nil)
        ),
        protectedResource.resource == endpoint.absoluteString,
        protectedResource.authorizationServers.contains(where: { value in
            guard let url = URL(string: value) else { return false }
            return allows(url)
        }) else { return false }
        Log.service.info("RemoteMCPOAuth.advertised endpoint=\(LogPrivacy.url(endpoint.absoluteString))")
        return true
    }

    private static func authorize(
        endpoint: URL,
        credential initialCredential: RemoteMCPOAuthCredential
    ) async throws -> String {
        var credential = initialCredential
        let server = credential.server
        let pkce = OAuthSupport.makePKCE()
        let state = UUID().uuidString
        let authorizeURL = try authorizationURL(server: server, registration: credential.registration, pkce: pkce, state: state)
        Log.service.info("RemoteMCPOAuth.authorize presenting issuer=\(LogPrivacy.url(server.issuer.absoluteString))")
        guard let callback = await OAuthWebLogin.present(authorizeURL: authorizeURL, redirectPrefix: redirectURI) else {
            throw RemoteMCPError.oauth("Sign-in was cancelled.")
        }
        if let message = OAuthSupport.queryValue("error_description", in: callback)
            ?? OAuthSupport.queryValue("error", in: callback) {
            throw RemoteMCPError.oauth(message)
        }
        guard OAuthSupport.queryValue("state", in: callback) == state,
              let code = OAuthSupport.queryValue("code", in: callback), !code.isEmpty else {
            throw RemoteMCPError.oauth("The OAuth callback was invalid.")
        }
        credential.tokens = try await exchange(code: code, verifier: pkce.verifier, credential: credential)
        save(credential, endpoint: endpoint)
        Log.service.info("RemoteMCPOAuth.authorize completed issuer=\(LogPrivacy.url(server.issuer.absoluteString))")
        return credential.tokens!.accessToken
    }

    static func clear(endpoint: URL) {
        Credentials.clearSecret(for: account(endpoint: endpoint))
    }

    private static func discover(endpoint: URL, challenge: RemoteMCPAuthorizationChallenge) async throws -> RemoteMCPOAuthServer {
        let protectedResource = try await discoverProtectedResource(endpoint: endpoint, challenge: challenge)
        guard let resource = URL(string: protectedResource.resource),
              resource.absoluteString == endpoint.absoluteString,
              let authorizationServerString = protectedResource.authorizationServers.first,
              let authorizationServer = URL(string: authorizationServerString),
              allows(authorizationServer) else {
            throw RemoteMCPError.oauth("The MCP server published invalid protected-resource metadata.")
        }
        let metadata = try await discoverAuthorizationServer(authorizationServer)
        guard let issuer = URL(string: metadata.issuer),
              sameIssuer(issuer, authorizationServer),
              let authorizationEndpoint = URL(string: metadata.authorizationEndpoint),
              let tokenEndpoint = URL(string: metadata.tokenEndpoint),
              allows(issuer), allows(authorizationEndpoint), allows(tokenEndpoint),
              metadata.codeChallengeMethodsSupported?.contains("S256") != false else {
            throw RemoteMCPError.oauth("The authorization server does not support a secure PKCE flow.")
        }
        let registrationEndpoint = metadata.registrationEndpoint.flatMap(URL.init(string:))
        if let registrationEndpoint, !allows(registrationEndpoint) {
            throw RemoteMCPError.oauth("The authorization server published an invalid registration endpoint.")
        }
        let scope = challenge.scope ?? protectedResource.scopesSupported?.joined(separator: " ")
        Log.service.info("RemoteMCPOAuth.discovery resource=\(LogPrivacy.url(endpoint.absoluteString)) issuer=\(LogPrivacy.url(issuer.absoluteString))")
        return RemoteMCPOAuthServer(
            resource: resource,
            issuer: issuer,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: registrationEndpoint,
            scope: scope
        )
    }

    private static func discoverProtectedResource(
        endpoint: URL,
        challenge: RemoteMCPAuthorizationChallenge
    ) async throws -> RemoteMCPProtectedResourceMetadata {
        var candidates: [URL] = []
        if let url = challenge.resourceMetadataURL, allows(url) { candidates.append(url) }
        if var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) {
            let path = components.path
            components.path = "/.well-known/oauth-protected-resource" + (path == "/" ? "" : path)
            components.query = nil
            if let url = components.url { candidates.append(url) }
            components.path = "/.well-known/oauth-protected-resource"
            if let url = components.url { candidates.append(url) }
        }
        for candidate in unique(candidates) {
            guard let response = try? await get(candidate), response.response.statusCode == 200,
                  let metadata = try? JSONDecoder().decode(RemoteMCPProtectedResourceMetadata.self, from: response.data) else { continue }
            return metadata
        }
        throw RemoteMCPError.oauth("The MCP server did not publish protected-resource metadata.")
    }

    private static func discoverAuthorizationServer(_ issuer: URL) async throws -> RemoteMCPAuthorizationServerMetadata {
        guard var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else {
            throw RemoteMCPError.oauth("The authorization server URL was invalid.")
        }
        let issuerPath = components.path == "/" ? "" : components.path
        components.path = "/.well-known/oauth-authorization-server" + issuerPath
        components.query = nil
        var candidates = components.url.map { [$0] } ?? []
        components.path = "/.well-known/openid-configuration" + issuerPath
        if let url = components.url { candidates.append(url) }
        components.path = issuerPath + "/.well-known/openid-configuration"
        if let url = components.url { candidates.append(url) }
        for candidate in unique(candidates) {
            guard let response = try? await get(candidate), response.response.statusCode == 200,
                  let metadata = try? JSONDecoder().decode(RemoteMCPAuthorizationServerMetadata.self, from: response.data) else { continue }
            return metadata
        }
        throw RemoteMCPError.oauth("The authorization server did not publish OAuth metadata.")
    }

    private static func register(server: RemoteMCPOAuthServer) async throws -> RemoteMCPClientRegistration {
        guard let endpoint = server.registrationEndpoint else {
            throw RemoteMCPError.oauth("This server requires a pre-registered OAuth client, which Ox does not have.")
        }
        let body: [String: Any] = [
            "client_name": "Ox",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await send(request)
        guard response.response.statusCode == 201 || response.response.statusCode == 200,
              let registration = try? JSONDecoder().decode(RemoteMCPClientRegistration.self, from: response.data),
              !registration.clientID.isEmpty else {
            throw RemoteMCPError.oauth("The authorization server rejected client registration.")
        }
        Log.service.info("RemoteMCPOAuth.registration completed issuer=\(LogPrivacy.url(server.issuer.absoluteString))")
        return registration
    }

    private static func authorizationURL(
        server: RemoteMCPOAuthServer,
        registration: RemoteMCPClientRegistration,
        pkce: OAuthPKCE,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw RemoteMCPError.oauth("The authorization endpoint was invalid.")
        }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: server.resource.absoluteString),
        ]
        if let scope = server.scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = items
        guard let url = components.url else { throw RemoteMCPError.oauth("The authorization request was invalid.") }
        return url
    }

    private static func exchange(
        code: String,
        verifier: String,
        credential: RemoteMCPOAuthCredential
    ) async throws -> RemoteMCPOAuthTokens {
        try await tokenRequest(
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "code_verifier": verifier,
                "resource": credential.server.resource.absoluteString,
            ],
            credential: credential,
            previousRefreshToken: nil
        )
    }

    private static func refresh(
        refreshToken: String,
        credential: RemoteMCPOAuthCredential
    ) async throws -> RemoteMCPOAuthTokens {
        try await tokenRequest(
            form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": credential.server.resource.absoluteString,
            ],
            credential: credential,
            previousRefreshToken: refreshToken
        )
    }

    private static func tokenRequest(
        form: [String: String],
        credential: RemoteMCPOAuthCredential,
        previousRefreshToken: String?
    ) async throws -> RemoteMCPOAuthTokens {
        var form = form
        var request = URLRequest(url: credential.server.tokenEndpoint)
        request.httpMethod = "POST"
        switch credential.registration.tokenEndpointAuthMethod {
        case "none":
            form["client_id"] = credential.registration.clientID
        case "client_secret_post":
            guard let secret = credential.registration.clientSecret else {
                throw RemoteMCPError.oauth("The OAuth client secret was missing.")
            }
            form["client_id"] = credential.registration.clientID
            form["client_secret"] = secret
        case "client_secret_basic":
            guard let secret = credential.registration.clientSecret else {
                throw RemoteMCPError.oauth("The OAuth client secret was missing.")
            }
            let value = Data("\(credential.registration.clientID):\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        default:
            throw RemoteMCPError.oauth("The authorization server selected an unsupported client authentication method.")
        }
        request.httpBody = OAuthSupport.formEncoded(form)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let response = try await send(request)
        guard (200...299).contains(response.response.statusCode),
              let tokens = try? JSONDecoder().decode(RemoteMCPTokenResponse.self, from: response.data),
              !tokens.accessToken.isEmpty,
              tokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw RemoteMCPError.oauth("The authorization server rejected the token request.")
        }
        return RemoteMCPOAuthTokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken ?? previousRefreshToken,
            tokenType: tokens.tokenType,
            expiresAt: tokens.expiresIn.map { Date().addingTimeInterval($0) },
            scope: tokens.scope
        )
    }

    private static func get(_ url: URL) async throws -> RemoteMCPHTTPResponse {
        guard allows(url) else { throw RemoteMCPError.oauth("OAuth metadata must use a public HTTPS URL.") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    private static func send(_ request: URLRequest) async throws -> RemoteMCPHTTPResponse {
        guard let url = request.url, allows(url) else { throw RemoteMCPError.oauth("OAuth endpoints must use public HTTPS URLs.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: RemoteMCPOAuthRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw RemoteMCPError.oauth("The OAuth server returned an invalid response.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxResponseBytes else { throw RemoteMCPError.oauth("The OAuth response was too large.") }
            data.append(byte)
        }
        return RemoteMCPHTTPResponse(data: data, response: response)
    }

    private static func load(endpoint: URL) -> RemoteMCPOAuthCredential? {
        guard let encoded = Credentials.secret(for: account(endpoint: endpoint)),
              let data = encoded.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteMCPOAuthCredential.self, from: data)
    }

    private static func save(_ credential: RemoteMCPOAuthCredential, endpoint: URL) {
        guard let data = try? JSONEncoder().encode(credential),
              let encoded = String(data: data, encoding: .utf8) else { return }
        Credentials.setSecret(encoded, for: account(endpoint: endpoint))
    }

    private static func account(endpoint: URL) -> String {
        let digest = SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return "oauth:mcp:\(digest)"
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var values = Set<String>()
        return urls.filter { values.insert($0.absoluteString).inserted }
    }

    private static func sameIssuer(_ lhs: URL, _ rhs: URL) -> Bool {
        guard var left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              var right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        if left.path == "/" { left.path = "" }
        if right.path == "/" { right.path = "" }
        return left == right
    }

    nonisolated private static func allows(_ url: URL) -> Bool {
        guard WebFetchURLPolicy.allows(url) else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        #if DEBUG && targetEnvironment(simulator)
        return url.scheme?.lowercased() == "http"
        #else
        return false
        #endif
    }
}
