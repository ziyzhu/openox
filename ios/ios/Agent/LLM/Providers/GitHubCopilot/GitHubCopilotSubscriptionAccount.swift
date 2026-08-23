import Foundation

nonisolated final class GitHubCopilotSubscriptionAccount: SubscriptionAccount, @unchecked Sendable {
    static let shared = GitHubCopilotSubscriptionAccount()

    let providerName = "GitHub Copilot"
    private let store = SubscriptionTokenStore<GitHubCopilotTokens>(key: "oauth:github-copilot")

    var isSignedIn: Bool { store.current() != nil }
    var planLabel: String? { isSignedIn ? "Subscription" : nil }
    var accountLabel: String? { store.current()?.accountLabel }

    var cachedAvailableModelIDs: Set<String>? {
        store.current()?.availableModelIDs.map(Set.init)
    }

    func accessToken() throws -> String {
        guard let token = store.current()?.accessToken, !token.isEmpty else {
            throw GitHubCopilotError(message: "Not signed in to GitHub Copilot")
        }
        return token
    }

    func availableModelIDs() async throws -> Set<String> {
        guard let tokens = store.current() else {
            throw GitHubCopilotError(message: "Not signed in to GitHub Copilot")
        }
        if let ids = tokens.availableModelIDs, !ids.isEmpty { return Set(ids) }
        let refresh = store.refreshTask(source: tokens.accessToken) {
            let ids = try await GitHubCopilotOAuth.availableModelIDs(accessToken: tokens.accessToken)
            return tokens.withAvailableModelIDs(ids)
        }
        Log.network.info("GitHubCopilotAccount models refreshing refresh=\(refresh.id.uuidString.prefix(8))")
        do {
            let refreshed = try await refresh.task.value
            let installed = store.install(refreshed, from: refresh)
            try Task.checkCancellation()
            if installed { return Set(refreshed.availableModelIDs ?? []) }
            guard let latest = store.current() else {
                throw GitHubCopilotError(message: "Not signed in to GitHub Copilot")
            }
            return Set(latest.availableModelIDs ?? [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            store.clear(refresh)
            Log.network.error("GitHubCopilotAccount models refresh failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signIn(using presenter: SubscriptionAuthorizationPresenter) async throws -> Bool {
        let generation = store.beginSignIn()
        do {
            let grant = try await GitHubCopilotOAuth.requestDeviceGrant()
            let accepted = await presenter.device(
                grant.verificationURL,
                grant.userCode
            ) {
                let tokens = try await GitHubCopilotOAuth.poll(grant)
                return self.store.persist(tokens, expectedGeneration: generation)
            }
            Log.network.info("GitHubCopilotAccount.signIn \(accepted ? "success" : "cancelled")")
            return accepted && isSignedIn
        } catch {
            Log.network.error("GitHubCopilotAccount.signIn failed: \(LogPrivacy.text(error.localizedDescription, limit: 2_048))")
            throw error
        }
    }

    @MainActor func signOut() {
        store.persist(nil)
        Log.network.info("GitHubCopilotAccount.signOut")
    }
}
