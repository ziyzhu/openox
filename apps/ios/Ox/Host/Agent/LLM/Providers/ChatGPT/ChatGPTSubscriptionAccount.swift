import Foundation

// Owns the ChatGPT subscription token bundle: persisted in the Keychain via
// Credentials, refreshed transparently when the access token is near expiry,
// and shared between the off-main streaming client and the on-main sign-in UI.
final class ChatGPTSubscriptionAccount: SubscriptionAccount, @unchecked Sendable {
    static let shared = ChatGPTSubscriptionAccount()

    private static let refreshSkew: TimeInterval = 5 * 60

    let providerName = "ChatGPT"

    private let store = SubscriptionTokenStore<ChatGPTTokens>(key: "oauth:chatgpt")

    private init() {}

    private func current() -> ChatGPTTokens? { store.current() }

    var isSignedIn: Bool { current() != nil }

    var planLabel: String? {
        guard let tokens = current() else { return nil }
        return ChatGPTOAuth.planType(fromAccessToken: tokens.accessToken)?.capitalized
    }

    var accountLabel: String? {
        guard let tokens = current() else { return nil }
        return ChatGPTOAuth.email(fromIDToken: tokens.idToken)
    }

    func validToken(forceRefresh: Bool = false) async throws -> (access: String, accountID: String) {
        guard let tokens = current() else { throw ChatGPTAuthError(message: "Not signed in to ChatGPT") }

        if (forceRefresh || Self.isExpiring(tokens.accessToken)), !tokens.refreshToken.isEmpty {
            return try await refresh(tokens, forceRefresh: forceRefresh)
        }

        return Self.credentials(tokens)
    }

    private func refresh(_ tokens: ChatGPTTokens, forceRefresh: Bool) async throws -> (access: String, accountID: String) {
        let refresh = store.refreshTask(source: tokens.refreshToken) {
            try await ChatGPTOAuth.refresh(tokens.refreshToken)
        }
        Log.network.info("ChatGPTAccount.validToken refreshing force=\(forceRefresh) refresh=\(refresh.id.uuidString.prefix(8))")
        do {
            var refreshed = try await refresh.task.value
            if refreshed.accountID.isEmpty { refreshed.accountID = tokens.accountID }
            let installed = store.install(refreshed, from: refresh)
            try Task.checkCancellation()
            if installed { return Self.credentials(refreshed) }
            guard let latest = current() else { throw ChatGPTAuthError(message: "Not signed in to ChatGPT") }
            return Self.credentials(latest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            store.clear(refresh)
            Log.network.error("ChatGPTAccount.validToken refresh failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            if forceRefresh { throw error }
            guard let latest = current() else { throw ChatGPTAuthError(message: "Not signed in to ChatGPT") }
            return Self.credentials(latest)
        }
    }

    private static func credentials(_ tokens: ChatGPTTokens) -> (access: String, accountID: String) {
        let accountID = tokens.accountID.isEmpty
            ? ChatGPTOAuth.accountID(fromIDToken: tokens.idToken)
            : tokens.accountID
        return (tokens.accessToken, accountID)
    }

    private static func isExpiring(_ accessToken: String) -> Bool {
        guard let exp = ChatGPTOAuth.expiry(ofJWT: accessToken) else { return true }
        return exp <= Date().addingTimeInterval(refreshSkew)
    }

    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool {
        let generation = store.beginSignIn()
        let pkce = OAuthSupport.makePKCE()
        let state = UUID().uuidString
        let authorizeURL = ChatGPTOAuth.authorizeURL(pkce: pkce, state: state)

        guard let callback = await presenter.oauth(authorizeURL, ChatGPTOAuth.redirectURI) else {
            Log.network.info("ChatGPTAccount.signIn cancelled")
            return false
        }

        let code = OAuthSupport.queryValue("code", in: callback)
        let returnedState = OAuthSupport.queryValue("state", in: callback)
        guard let code, returnedState == state else {
            let callbackError = OAuthSupport.queryValue("error_description", in: callback)
                ?? OAuthSupport.queryValue("error", in: callback)
                ?? "ChatGPT returned an invalid sign-in response"
            Log.network.error("ChatGPTAccount.signIn bad callback stateMatch=\(returnedState == state) hasCode=\(code != nil) error=\(LogPrivacy.text(callbackError, limit: 2_048))")
            throw ChatGPTAuthError(message: callbackError)
        }

        do {
            let tokens = try await ChatGPTOAuth.exchangeCode(code, verifier: pkce.verifier)
            guard store.persist(tokens, expectedGeneration: generation) else {
                Log.network.info("ChatGPTAccount.signIn superseded")
                return false
            }
            let plan = ChatGPTOAuth.planType(fromAccessToken: tokens.accessToken) ?? "?"
            Log.network.info("ChatGPTAccount.signIn success account=\(tokens.accountID.isEmpty ? "missing" : "set") plan=\(plan)")
            return true
        } catch {
            Log.network.error("ChatGPTAccount.signIn exchange failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signOut() {
        Log.network.info("ChatGPTAccount.signOut")
        store.persist(nil)
    }
}
