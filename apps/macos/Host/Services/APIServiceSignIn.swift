import Foundation

@MainActor
enum APIServiceSignIn {
    static func present(_ service: Service) async throws {
        guard let api = service.apiService else { throw APIServiceError.authorizationFailed }
        let authorization = api.authorization
        switch authorization.auth {
        case .none: return
        case .oauth(let configuration):
            let pkce = OAuthSupport.makePKCE()
            let state = UUID().uuidString
            guard var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false) else {
                throw APIServiceError.authorizationFailed
            }
            components.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            guard let url = components.url,
                  let callback = await OAuthWebLogin.present(authorizeURL: url, redirectPrefix: configuration.redirectURI),
                  var received = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                  OAuthSupport.queryValue("state", in: callback) == state,
                  let code = OAuthSupport.queryValue("code", in: callback), !code.isEmpty else {
                throw APIServiceError.authorizationFailed
            }
            received.query = nil
            received.fragment = nil
            guard received.url?.absoluteString == configuration.redirectURI else { throw APIServiceError.authorizationFailed }
            let credential = try await authorization.exchange(configuration, form: [
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": configuration.redirectURI, "code_verifier": pkce.verifier,
            ])
            try Task.checkCancellation()
            try authorization.save(credential)
        case .apiKey, .basic, .bearer:
            let basic: Bool
            if case .basic = authorization.auth { basic = true } else { basic = false }
            let entry = try await MacCredentialPrompt.enter(title: service.title, username: basic)
            try Task.checkCancellation()
            try authorization.save(APIServiceCredential(binding: authorization.binding, secret: entry.secret, username: entry.username))
        }
    }
}
