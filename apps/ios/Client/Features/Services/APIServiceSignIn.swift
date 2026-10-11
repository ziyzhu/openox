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

    private func enterCredentials(title: String, authorization: APIServiceAuthorization) async throws -> APIServiceCredential {
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        guard let presenter else { throw APIServiceError.authorizationFailed }
        return try await withCheckedThrowingContinuation { continuation in
            let alert = UIAlertController(title: title, message: String(localized: "Authentication"), preferredStyle: .alert)
            if case .basic = authorization.auth {
                alert.addTextField { field in
                    field.placeholder = String(localized: "Username")
                    field.autocapitalizationType = .none
                    field.autocorrectionType = .no
                    field.accessibilityIdentifier = "service.api.username"
                }
            }
            alert.addTextField { field in
                switch authorization.auth {
                case .basic: field.placeholder = String(localized: "Password")
                case .apiKey: field.placeholder = String(localized: "API key")
                default: field.placeholder = String(localized: "Token")
                }
                field.isSecureTextEntry = true
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.accessibilityIdentifier = "service.api.secret"
            }
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in
                continuation.resume(throwing: CancellationError())
            })
            alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { _ in
                let fields = alert.textFields ?? []
                guard let secret = fields.last?.text, !secret.isEmpty,
                      !secret.contains("\r"), !secret.contains("\n") else {
                    continuation.resume(throwing: APIServiceError.invalidRequest)
                    return
                }
                let username = fields.count == 2 ? fields.first?.text : nil
                guard username?.contains(":") != true else {
                    continuation.resume(throwing: APIServiceError.invalidRequest)
                    return
                }
                continuation.resume(returning: APIServiceCredential(binding: authorization.binding, secret: secret, username: username))
            })
            presenter.present(alert, animated: true)
        }
    }
}
