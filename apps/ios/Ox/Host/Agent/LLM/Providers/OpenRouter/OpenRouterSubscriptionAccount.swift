import Foundation

nonisolated final class OpenRouterSubscriptionAccount: SubscriptionAccount, @unchecked Sendable {
    static let shared = OpenRouterSubscriptionAccount()

    private let store = SubscriptionTokenStore<OpenRouterCredential>(key: "oauth:openrouter")

    let providerName = "OpenRouter"

    var isSignedIn: Bool { store.current() != nil }
    var planLabel: String? { nil }

    func apiKey() throws -> String {
        guard let credential = store.current() else {
            throw OpenRouterError(message: "Not signed in to OpenRouter")
        }
        return credential.apiKey
    }

    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool {
        let generation = store.beginSignIn()
        let pkce = OAuthSupport.makePKCE()
        let authorizeURL = OpenRouterOAuth.authorizeURL(pkce: pkce)
        guard let callback = await presenter.oauth(authorizeURL, OpenRouterOAuth.redirectURI) else {
            Log.network.info("OpenRouterAccount.signIn cancelled")
            return false
        }
        if let message = OAuthSupport.queryValue("error_description", in: callback)
            ?? OAuthSupport.queryValue("error", in: callback) {
            Log.network.error("OpenRouterAccount.signIn rejected error=\(LogPrivacy.text(message, limit: 2_048))")
            throw OpenRouterError(message: message)
        }
        guard let code = OAuthSupport.queryValue("code", in: callback), !code.isEmpty else {
            Log.network.error("OpenRouterAccount.signIn missing code")
            throw OpenRouterError(message: "OpenRouter returned an invalid sign-in response")
        }
        do {
            let credential = try await OpenRouterOAuth.exchangeCode(code, verifier: pkce.verifier)
            guard store.persist(credential, expectedGeneration: generation) else { return false }
            Log.network.info("OpenRouterAccount.signIn success")
            return true
        } catch {
            Log.network.error("OpenRouterAccount.signIn failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signOut() {
        store.persist(nil)
        Log.network.info("OpenRouterAccount.signOut")
    }
}
