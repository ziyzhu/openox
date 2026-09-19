import CryptoKit
import Foundation

nonisolated enum APIServiceAuth: Sendable {
    case none
    case apiKey(location: String, name: String)
    case basic
    case bearer
    case oauth(OAuth)

    struct OAuth: Sendable {
        let authorizationURL: URL
        let tokenURL: URL
        let clientID: String
        let redirectURI: String
        let scopes: [String]
    }

    init(_ value: JSONValue) throws {
        guard let raw = value.objectValue, let type = raw["type"]?.stringValue else {
            throw APIServiceError.invalidConfiguration
        }
        let allowed: Set<String>
        switch type {
        case "none":
            allowed = ["type"]
            self = .none
        case "apiKey":
            allowed = ["type", "in", "name"]
            guard let location = raw["in"]?.stringValue, ["header", "query"].contains(location),
                  let name = raw["name"]?.stringValue,
                  name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw APIServiceError.invalidConfiguration
            }
            self = .apiKey(location: location, name: name)
        case "http":
            allowed = ["type", "scheme"]
            switch raw["scheme"]?.stringValue {
            case "basic": self = .basic
            case "bearer": self = .bearer
            default: throw APIServiceError.invalidConfiguration
            }
        case "oauth2":
            allowed = ["type", "flow", "authorizationURL", "tokenURL", "clientID", "redirectURI", "scopes", "pkce"]
            guard raw["flow"]?.stringValue == "authorizationCode", raw["pkce"]?.stringValue == "S256",
                  let authorizationURL = raw["authorizationURL"]?.stringValue.flatMap(URL.init(string:)),
                  let tokenURL = raw["tokenURL"]?.stringValue.flatMap(URL.init(string:)),
                  Self.validEndpoint(authorizationURL), Self.validEndpoint(tokenURL),
                  let clientID = raw["clientID"]?.stringValue, !clientID.isEmpty,
                  let redirectURI = raw["redirectURI"]?.stringValue,
                  let redirect = URL(string: redirectURI), let scheme = redirect.scheme,
                  !["http", "https"].contains(scheme.lowercased()), redirect.query == nil, redirect.fragment == nil,
                  let values = raw["scopes"]?.arrayValue,
                  values.allSatisfy({ $0.stringValue?.isEmpty == false }) else {
                throw APIServiceError.invalidConfiguration
            }
            self = .oauth(OAuth(authorizationURL: authorizationURL, tokenURL: tokenURL, clientID: clientID,
                                redirectURI: redirectURI, scopes: values.compactMap(\.stringValue)))
        default: throw APIServiceError.invalidConfiguration
        }
        guard Set(raw.keys).isSubset(of: allowed) else { throw APIServiceError.invalidConfiguration }
    }

    var requiresCredentials: Bool {
        if case .none = self { return false }
        return true
    }

    static func validEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }
}

nonisolated enum APIServiceError: LocalizedError {
    case invalidConfiguration
    case authorizationRequired
    case invalidRequest
    case destinationDenied
    case mutationDenied
    case responseTooLarge
    case http(Int)
    case authorizationFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The API service configuration is invalid."
        case .authorizationRequired: "Set up authentication for this service before invoking it."
        case .invalidRequest: "The API request is invalid."
        case .destinationDenied: "The API request destination is outside this service's base URL."
        case .mutationDenied: "This capability must require approval before sending a mutation."
        case .responseTooLarge: "The API response exceeded the size limit."
        case .http(let status): "The API returned HTTP \(status)."
        case .authorizationFailed: "Authorization failed. Sign in again and grant the required permissions."
        case .invalidResponse: "The API returned an invalid response."
        }
    }
}

nonisolated struct APIServiceCredential: Codable, Sendable, Equatable {
    var version = 1
    let binding: String
    var secret: String
    var username: String?
    var refreshToken: String?
    var expiresAt: Date?
    var scopes: [String]?
}

@MainActor
final class APIServiceAuthorization {
    let auth: APIServiceAuth
    let binding: String
    private let account: String
    private static var refreshTasks: [String: (id: UUID, task: Task<APIServiceCredential, Error>)] = [:]
    private var rejectedCredential: APIServiceCredential?

    init(definition: ServiceDefinition) throws {
        guard let raw = definition.manifest.objectValue?["auth"], let baseURL = definition.baseURL else {
            throw APIServiceError.invalidConfiguration
        }
        auth = try APIServiceAuth(raw)
        let configuration: [String: Any] = [
            "auth": raw.toAny(), "baseURL": baseURL.absoluteString,
            "repository": definition.repositoryID ?? "", "domain": definition.domain,
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        binding = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = Data("\(definition.repositoryID ?? ""):\(definition.domain)".utf8)
        account = "service:api:" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    var credential: APIServiceCredential? {
        guard let value = Credentials.secret(for: account), let data = value.data(using: .utf8),
              let credential = try? JSONDecoder().decode(APIServiceCredential.self, from: data),
              credential.version == 1, credential.binding == binding else { return nil }
        return credential
    }

    var isConfigured: Bool {
        if !auth.requiresCredentials { return true }
        guard let credential else { return false }
        if case .oauth = auth, credential.expiresAt.map({ $0 <= Date() }) == true {
            return credential.refreshToken != nil
        }
        return true
    }

    func checkAccess(previous: Service.AuthObservation?) async throws -> Service.Auth {
        guard auth.requiresCredentials else { return .notRequired }
        var current = credential
        if let stored = current, case .oauth(let configuration) = auth,
           stored.expiresAt.map({ $0 <= Date().addingTimeInterval(60) }) ?? false {
            do {
                current = try await refreshed(stored, configuration: configuration)
            } catch APIServiceError.authorizationRequired {
                current = nil
            }
        }
        let value: Service.AuthObservation.Value = current != nil && current != rejectedCredential ? .signedIn : .signedOut
        if let previous, previous.value == value { return .observed(previous) }
        return .observed(Service.AuthObservation(value: value, observedAt: Date(), evidence: .configured))
    }

    func rejectCredential() {
        rejectedCredential = credential
    }

    func save(_ credential: APIServiceCredential) throws {
        try persist(credential)
        cancelRefresh()
        rejectedCredential = nil
    }

    private func persist(_ credential: APIServiceCredential) throws {
        let value = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        try Credentials.setSecretChecked(value, for: account)
        rejectedCredential = nil
    }

    func clear() {
        rejectedCredential = nil
        cancelRefresh()
        Credentials.clearSecret(for: account)
    }

    func prepare(_ request: URLRequest) async throws -> URLRequest {
        guard auth.requiresCredentials else { return request }
        guard var credential, credential != rejectedCredential else { throw APIServiceError.authorizationRequired }
        if case .oauth(let configuration) = auth,
           credential.expiresAt.map({ $0 <= Date().addingTimeInterval(60) }) ?? false {
            credential = try await refreshed(credential, configuration: configuration)
        }
        var request = request
        switch auth {
        case .none: break
        case .apiKey(let location, let name):
            if location == "header" {
                request.setValue(credential.secret, forHTTPHeaderField: name)
            } else {
                guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw APIServiceError.invalidRequest
                }
                components.queryItems = (components.queryItems ?? []).filter { $0.name != name }
                    + [URLQueryItem(name: name, value: credential.secret)]
                request.url = components.url
            }
        case .basic:
            let encoded = Data("\(credential.username ?? ""):\(credential.secret)".utf8).base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        case .bearer, .oauth:
            request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func cancelRefresh() {
        Self.refreshTasks.removeValue(forKey: account)?.task.cancel()
    }

    private func refreshed(_ credential: APIServiceCredential, configuration: APIServiceAuth.OAuth) async throws -> APIServiceCredential {
        if let pending = Self.refreshTasks[account] { return try await pending.task.value }
        guard let token = credential.refreshToken else { throw APIServiceError.authorizationRequired }
        let id = UUID()
        let task = Task {
            defer { if Self.refreshTasks[account]?.id == id { Self.refreshTasks[account] = nil } }
            do {
                let result = try await exchange(configuration, form: ["grant_type": "refresh_token", "refresh_token": token], previous: credential)
                guard Self.refreshTasks[account]?.id == id, self.credential == credential else { throw CancellationError() }
                try persist(result)
                return result
            } catch APIServiceError.authorizationRequired {
                if Self.refreshTasks[account]?.id == id { clear() }
                throw APIServiceError.authorizationRequired
            }
        }
        Self.refreshTasks[account] = (id, task)
        return try await task.value
    }

    func exchange(_ configuration: APIServiceAuth.OAuth, form: [String: String], previous: APIServiceCredential? = nil) async throws -> APIServiceCredential {
        var form = form
        form["client_id"] = configuration.clientID
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthSupport.formEncoded(form)
        let result = try await APIServiceHTTP.send(request, maximumBytes: 64_000)
        if result.status == 400,
           (try? JSONDecoder().decode(JSONValue.self, from: result.data))?.objectValue?["error"]?.stringValue == "invalid_grant" {
            throw APIServiceError.authorizationRequired
        }
        guard (200..<300).contains(result.status),
              let raw = try? JSONDecoder().decode(JSONValue.self, from: result.data).objectValue,
              let token = raw["access_token"]?.stringValue, !token.isEmpty,
              raw["token_type"]?.stringValue?.lowercased() == "bearer" else {
            throw APIServiceError.authorizationFailed
        }
        let scopes = raw["scope"]?.stringValue?.split(separator: " ").map(String.init)
            ?? previous?.scopes ?? configuration.scopes
        guard Set(configuration.scopes).isSubset(of: Set(scopes)) else { throw APIServiceError.authorizationFailed }
        return APIServiceCredential(binding: binding, secret: token,
            refreshToken: raw["refresh_token"]?.stringValue ?? previous?.refreshToken,
            expiresAt: Date().addingTimeInterval(raw["expires_in"]?.doubleValue ?? 3600), scopes: scopes)
    }
}
