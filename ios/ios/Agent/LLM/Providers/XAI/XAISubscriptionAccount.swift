import Foundation

nonisolated final class XAISubscriptionAccount: SubscriptionAccount, @unchecked Sendable {
    static let shared = XAISubscriptionAccount()

    private static let refreshSkew: TimeInterval = 2 * 60
    private let store = SubscriptionTokenStore<XAITokens>(key: "oauth:xai")

    let providerName = "xAI"

    var isSignedIn: Bool { store.current() != nil }
    var planLabel: String? { isSignedIn ? "SuperGrok" : nil }
    var accountLabel: String? { store.current().flatMap(XAIOAuth.email(from:)) }

    func validToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = store.current() else { throw XAIError(message: "Not signed in to xAI") }
        if (forceRefresh || tokens.expiresAt <= Date().addingTimeInterval(Self.refreshSkew)),
           !tokens.refreshToken.isEmpty {
            return try await refresh(tokens, forceRefresh: forceRefresh)
        }
        return tokens.accessToken
    }

    private func refresh(_ tokens: XAITokens, forceRefresh: Bool) async throws -> String {
        let refresh = store.refreshTask(source: tokens.refreshToken) { try await XAIOAuth.refresh(tokens) }
        Log.network.info("XAIAccount.validToken refreshing force=\(forceRefresh) refresh=\(refresh.id.uuidString.prefix(8))")
        do {
            let refreshed = try await refresh.task.value
            let installed = store.install(refreshed, from: refresh)
            try Task.checkCancellation()
            if installed { return refreshed.accessToken }
            guard let latest = store.current() else { throw XAIError(message: "Not signed in to xAI") }
            return latest.accessToken
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            store.clear(refresh)
            Log.network.error("XAIAccount.validToken refresh failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            if forceRefresh { throw error }
            guard let latest = store.current() else { throw XAIError(message: "Not signed in to xAI") }
            return latest.accessToken
        }
    }

    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool {
        let generation = store.beginSignIn()
        let pkce = OAuthSupport.makePKCE()
        let state = UUID().uuidString
        let authorizeURL = XAIOAuth.authorizeURL(pkce: pkce, state: state, nonce: UUID().uuidString)
        guard let callback = await presenter.oauth(authorizeURL, XAIOAuth.redirectURI) else {
            Log.network.info("XAIAccount.signIn cancelled")
            return false
        }
        let code = OAuthSupport.queryValue("code", in: callback)
        let returnedState = OAuthSupport.queryValue("state", in: callback)
        guard let code, returnedState == state else {
            let callbackError = OAuthSupport.queryValue("error_description", in: callback)
                ?? OAuthSupport.queryValue("error", in: callback)
                ?? "xAI returned an invalid sign-in response"
            Log.network.error("XAIAccount.signIn invalid callback stateMatch=\(returnedState == state) hasCode=\(code != nil) error=\(LogPrivacy.text(callbackError, limit: 2_048))")
            throw XAIError(message: callbackError)
        }
        do {
            let tokens = try await XAIOAuth.exchangeCode(code, verifier: pkce.verifier)
            guard store.persist(tokens, expectedGeneration: generation) else { return false }
            Log.network.info("XAIAccount.signIn success")
            return true
        } catch {
            Log.network.error("XAIAccount.signIn failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signOut() {
        store.persist(nil)
        Log.network.info("XAIAccount.signOut")
    }
}
