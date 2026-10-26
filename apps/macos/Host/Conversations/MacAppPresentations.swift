import Foundation
import SwiftUI
import WebKit

@MainActor
final class MacAppPresentations: ServiceAuthPresenting, ServiceHandoffPresenting, ProviderAuthenticating {
    private let windows = MacServiceWindows()

    var presentations: AppPresentations {
        AppPresentations(
            serviceSignIn: self,
            serviceHandoff: self,
            messages: AppPresentations.unavailable.messages,
            providerAuthentication: self,
            browser: { [windows] service, page in windows.open(.init(service: service, session: page)) },
            secretEntry: { key in
                do {
                    let entry = try await MacCredentialPrompt.enter(
                        title: "Save secret: \(key)",
                        message: "Enter a JSON object with string fields, such as {\"apiKey\":\"value\"}. The secret stays in this Host's Keychain, outside the conversation."
                    )
                    try Task.checkCancellation()
                    try Secret.set(key: key, displayName: key, value: entry.secret)
                    return true
                } catch is CancellationError { return false }
            }
        )
    }

    func present(session: ServiceAuthSession) async -> ServiceAuthSession.Outcome {
        if let result = await session.preflight(for: .seconds(1)) { return result }
        let owner = MacInteractionWindow(
            title: "Sign in — Ox Host",
            view: WebView(session.page).accessibilityIdentifier("mac-host-service-auth-page")
        ) { session.cancel() }
        defer { owner.dismiss() }
        Log.service.info("MacPresentation.auth domain=\(session.serviceDomain)")
        return await session.run()
    }

    func present(session: ServiceHandoffSession) async -> ServiceHandoffSession.Outcome {
        if let result = await session.preflight(for: .seconds(1)) { return result }
        let owner = MacInteractionWindow(
            title: "\(session.navigationTitle) — Ox Host",
            view: WebView(session.page).accessibilityIdentifier("mac-host-service-handoff-page")
        ) { session.dismissPresentation() }
        defer { owner.dismiss() }
        Log.service.info("MacPresentation.handoff domain=\(session.serviceDomain)")
        return await session.run()
    }

    func present(session: ProviderAuthenticationSession) async -> ProviderAuthenticationSession.Outcome {
        do {
            let client = session.client
            var useAccount = client.subscriptionAccount != nil
            if useAccount && client.acceptsAPIKey {
                let choice = try await MacCredentialPrompt.choose(
                    title: client.displayName, message: "Choose how to authenticate on this Host.",
                    buttons: ["Sign in", "Enter credential", "Cancel"]
                )
                guard choice != 2 else { throw CancellationError() }
                useAccount = choice == 0
            }
            if useAccount, let account = client.subscriptionAccount {
                let authorized = try await account.signIn(using: SubscriptionAuthorizationPresenter(
                    oauth: { await OAuthWebLogin.present(authorizeURL: $0, redirectPrefix: $1) },
                    device: { await OAuthWebLogin.presentDevice(authorizeURL: $0, userCode: $1, poll: $2) }
                ))
                try Task.checkCancellation()
                session.complete(authorized ? .authenticated : .cancelled)
            } else if client.acceptsAPIKey {
                let entry = try await MacCredentialPrompt.enter(title: client.displayName)
                try Task.checkCancellation()
                try Secret.saveProviderKey(entry.secret.trimmingCharacters(in: .whitespacesAndNewlines), definition: session.definition)
                session.complete(.credentialStored)
            } else {
                session.complete(.failed)
            }
        } catch is CancellationError {
            session.complete(.cancelled)
        } catch {
            Log.service.error("MacPresentation.provider failed provider=\(session.definition.id) error=\(error.localizedDescription)")
            session.complete(.failed)
        }
        return await session.run()
    }
}
