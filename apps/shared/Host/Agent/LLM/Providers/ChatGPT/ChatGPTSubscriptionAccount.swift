import Foundation

final class ChatGPTSubscriptionAccount: SubscriptionAccount, @unchecked Sendable {
    static let shared = ChatGPTSubscriptionAccount()

    let providerName = "ChatGPT"

    private let store = SubscriptionTokenStore<ChatGPTTokens>(key: ManagedOAuthAccount.modelProvider("chatgpt:siwc"))
    @MainActor private var signingIn = false

    private init() {}

    var isSignedIn: Bool { store.current()?.canInvoke == true }
    var planLabel: String? { nil }
    var accountLabel: String? { store.current()?.email }

    func validToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = store.current(), tokens.canInvoke else { throw ChatGPTAuthError(message: "Sign in to ChatGPT and allow OpenOx to use your plan.") }
        guard forceRefresh || tokens.expiresAt <= Date().addingTimeInterval(300) else { return tokens.accessToken }
        guard !tokens.refreshToken.isEmpty else { throw ChatGPTAuthError(message: "ChatGPT session expired. Sign in again.", sessionExpired: true) }
        let refresh = store.refreshTask(source: tokens.refreshToken) { try await ChatGPTOAuth.refresh(tokens) }
        Log.network.info("ChatGPTAccount.refresh started force=\(forceRefresh)")
        do {
            let refreshed = try await refresh.task.value
            let installed = store.install(refreshed, from: refresh)
            try Task.checkCancellation()
            if installed {
                guard refreshed.canInvoke else { throw ChatGPTAuthError(message: "Allow OpenOx to use your ChatGPT plan, then sign in again.") }
                return refreshed.accessToken
            }
            guard let latest = store.current(), latest.canInvoke else { throw ChatGPTAuthError(message: "Not signed in to ChatGPT") }
            return latest.accessToken
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let authError = error as? ChatGPTAuthError, authError.sessionExpired {
                store.persist(Self.signedOut(tokens), expectedGeneration: refresh.generation)
            } else {
                store.clear(refresh)
            }
            Log.network.error("ChatGPTAccount.refresh failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool {
        guard !signingIn else { return false }
        signingIn = true
        defer { signingIn = false }
        let generation = store.beginSignIn()
        defer { store.cancelSignIn(expectedGeneration: generation) }
        let registration = store.current()
        let pkce = OAuthSupport.makePKCE()
        let state = UUID().uuidString
        let nonce = UUID().uuidString
        let hostKey = "chatgpt.agentHostID"
        let hostID = UserDefaults.standard.string(forKey: hostKey) ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(hostID, forKey: hostKey)
        let url = ChatGPTOAuth.authorizeURL(pkce: pkce, state: state, nonce: nonce, hostID: hostID, registration: registration)
        Log.network.info("ChatGPTAccount.signIn started registration=\(registration == nil ? "new" : "existing")")
        guard let callback = await presenter.oauth(url, ChatGPTOAuth.redirectURI) else {
            Log.network.info("ChatGPTAccount.signIn cancelled")
            return false
        }
        guard callback.scheme == "http", callback.host == "127.0.0.1", callback.port == 1455,
              callback.path == "/auth/callback", OAuthSupport.queryValue("state", in: callback) == state else {
            throw ChatGPTAuthError(message: "ChatGPT returned an invalid sign-in callback")
        }
        if OAuthSupport.queryValue("error", in: callback) != nil {
            throw ChatGPTAuthError(message: "ChatGPT sign-in was declined. Allow OpenOx to use your ChatGPT plan to connect.")
        }
        let returnedClient = OAuthSupport.queryValue("client_id", in: callback)
        guard let code = OAuthSupport.queryValue("code", in: callback), !code.isEmpty,
              let clientID = returnedClient ?? registration?.clientID, !clientID.isEmpty, clientID != "dynamic_agent_client",
              registration == nil || returnedClient == nil || returnedClient == registration?.clientID else {
            throw ChatGPTAuthError(message: "ChatGPT did not return the expected OpenOx registration")
        }
        do {
            let tokens = try await ChatGPTOAuth.exchangeCode(code, clientID: clientID, verifier: pkce.verifier, nonce: nonce, registration: registration)
            try Task.checkCancellation()
            guard store.persist(tokens, expectedGeneration: generation) else { return false }
            guard tokens.canInvoke else { throw ChatGPTAuthError(message: "Allow OpenOx to use your ChatGPT plan, then continue with ChatGPT again, or choose another provider.") }
            Log.network.info("ChatGPTAccount.signIn success")
            return true
        } catch {
            Log.network.error("ChatGPTAccount.signIn failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signOut() {
        guard let tokens = store.current() else { return }
        store.persist(Self.signedOut(tokens))
        Task {
            for attempt in 1...3 {
                do {
                    try await ChatGPTOAuth.revoke(tokens)
                    Log.network.info("ChatGPTAccount.signOut revoked")
                    return
                } catch {
                    Log.network.warning("ChatGPTAccount.signOut revocation unconfirmed attempt=\(attempt)")
                    if attempt < 3 { try? await Task.sleep(for: .seconds(attempt * 2)) }
                }
            }
        }
    }

    private static func signedOut(_ tokens: ChatGPTTokens) -> ChatGPTTokens {
        var registration = tokens
        registration.accessToken = ""
        registration.refreshToken = ""
        registration.idToken = ""
        registration.scopes = []
        return registration
    }
}
