import AuthenticationServices
import UIKit

@MainActor
final class APIServiceSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: UIWindow
    private var session: ASWebAuthenticationSession?

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }

    static func present(_ service: Service) async throws {
        guard let api = service.apiService,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow else { throw APIServiceError.authorizationFailed }
        let presenter = APIServiceSignIn(window: window)
        let authorization = api.authorization
        switch authorization.auth {
        case .none: return
        case .oauth(let configuration):
            let pkce = OAuthSupport.makePKCE()
            let state = UUID().uuidString
            var components = URLComponents(url: configuration.authorizationURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            let callback = try await presenter.authorize(url: components.url!, redirectURI: configuration.redirectURI)
            guard var received = URLComponents(url: callback, resolvingAgainstBaseURL: false),
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
            let credential = try await presenter.enterCredentials(title: service.title, authorization: authorization)
            try Task.checkCancellation()
            try authorization.save(credential)
        }
    }

    private func authorize(url: URL, redirectURI: String) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: URL(string: redirectURI)?.scheme) { url, _ in
                    if let url { continuation.resume(returning: url) }
                    else { continuation.resume(throwing: APIServiceError.authorizationFailed) }
                }
                session.presentationContextProvider = self
                self.session = session
                if !session.start() { continuation.resume(throwing: APIServiceError.authorizationFailed) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.session?.cancel() }
        }
    }

    private func enterCredentials(title: String, authorization: APIServiceAuthorization, credentialURL: URL? = nil) async throws -> APIServiceCredential {
        let basic: Bool
        if case .basic = authorization.auth { basic = true } else { basic = false }
        let label: String = switch authorization.auth {
        case .basic: String(localized: "Password")
        case .apiKey: String(localized: "API key")
        default: String(localized: "Token")
        }
        let fields = (basic ? [CredentialEntryPrompt.Field(label: String(localized: "Username"), value: "", secure: false, contentType: .username, accessibilityIdentifier: "service.api.username")] : [])
            + [CredentialEntryPrompt.Field(label: label, value: "", secure: true, contentType: basic ? .password : nil, accessibilityIdentifier: "service.api.secret")]
        let linkLabel: String = switch authorization.auth {
        case .basic: String(localized: "Open account page")
        case .apiKey: String(localized: "Get API Key")
        default: String(localized: "Create token")
        }
        let website = credentialURL.map { CredentialEntryPrompt.Website(url: $0, label: linkLabel, accessibilityIdentifier: "service.api.credentialWebsite") }
        let values = try await CredentialEntryPrompt.enter(title: title, fields: fields, website: website, accessibilityIdentifier: "service.api.authentication") { values in
            guard let secret = values.last, !secret.isEmpty, !secret.contains("\r"), !secret.contains("\n") else { return false }
            return !basic || (!values[0].isEmpty && !values[0].contains(":") && !values[0].contains("\r") && !values[0].contains("\n"))
        }
        return APIServiceCredential(binding: authorization.binding, secret: values.last!, username: basic ? values.first : nil)
    }
}
