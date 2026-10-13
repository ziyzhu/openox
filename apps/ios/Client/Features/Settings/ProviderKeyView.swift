import SwiftUI

struct ProviderAuthenticationView: View {
    private enum AuthenticationMethod {
        case apiKey
        case subscription
    }

    let client: any ProviderClient
    @Binding var apiKey: String
    let onChange: () -> Void
    var onAuthenticated: (() -> Void)? = nil

    @State private var authenticationMethod: AuthenticationMethod
    @State private var signedIn = false
    @State private var plan: String?
    @State private var accountLabel: String?
    @State private var busy = false
    @State private var showSignOutConfirm = false
    @State private var signInError: String?
    @State private var presentations = AppPresentationCoordinator()

    init(
        client: any ProviderClient,
        apiKey: Binding<String>,
        onChange: @escaping () -> Void,
        onAuthenticated: (() -> Void)? = nil
    ) {
        self.client = client
        _apiKey = apiKey
        self.onChange = onChange
        self.onAuthenticated = onAuthenticated
        let method: AuthenticationMethod = if client.acceptsAPIKey, client.subscriptionAccount != nil {
            !apiKey.wrappedValue.isEmpty ? .apiKey : .subscription
        } else if client.acceptsAPIKey {
            .apiKey
        } else {
            .subscription
        }
        _authenticationMethod = State(initialValue: method)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let signInError {
                SettingsErrorMessage(message: signInError, systemImage: "exclamationmark.circle.fill")
                    .accessibilityIdentifier(A11yID.ConversationControls.modelKeySignInError)
            }

            if let notice = client.authNotice {
                SettingsNoticeMessage(message: notice, systemImage: "info.circle.fill")
                    .accessibilityIdentifier(A11yID.ConversationControls.modelKeyNotice)
            }

            if client.acceptsAPIKey, client.subscriptionAccount != nil {
                authenticationMethodPicker
            }

            if client.acceptsAPIKey, authenticationMethod == .apiKey {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    apiKeyContent
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.ConversationControls.modelAuthAPIKey)
            }

            if let account = client.subscriptionAccount, authenticationMethod == .subscription {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    subscriptionContent(account)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.ConversationControls.modelAuthOAuth)
            }

            if !client.acceptsAPIKey, client.subscriptionAccount == nil {
                Text("Not required")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowPadding()
                    .settingsSurface(singleRow: true)
                    .accessibilityIdentifier(A11yID.ConversationControls.modelAuthNone)
            }
        }
        .alert("Sign out of \(client.displayName)?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                if let account = client.subscriptionAccount { signOut(account) }
            }
        } message: {
            Text("You'll need to sign in again to use \(client.displayName).")
        }
        .onAppear {
            if let account = client.subscriptionAccount { refreshSubscription(account) }
        }
        .appPresentations(presentations)
    }

    private var authenticationMethodPicker: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button("API Key") {
                authenticationMethod = .apiKey
            }
                .buttonStyle(OxChipButton(filled: authenticationMethod == .apiKey))
            Button("Account (OAuth)") {
                authenticationMethod = .subscription
            }
                .buttonStyle(OxChipButton(filled: authenticationMethod == .subscription))
        }
        .settingsContentInset()
    }

    @ViewBuilder
    private var apiKeyContent: some View {
        Button {
            enterAPIKey()
        } label: {
            SettingsActionButtonLabel {
                Text(apiKey.isEmpty ? "Add credential" : "Edit credential")
                Spacer()
                if !apiKey.isEmpty { Image(systemName: "checkmark.circle.fill") }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("provider.authentication.enter")

        Text(credentialDescription)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
            .settingsContentInset()
    }

    @ViewBuilder
    private func subscriptionContent(_ account: any SubscriptionAccount) -> some View {
        if let policyNotice = account.policyNotice {
            Text(policyNotice)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.error)
                .settingsContentInset()
        }

        if signedIn {
            membershipCard(account)
        } else {
            Button {
                signIn(account)
            } label: {
                SettingsActionButtonLabel {
                    if busy {
                        CellularAutomatonLoader.small
                    }
                    Text(busy ? "Signing in…" : "Sign in with \(account.providerName)")
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityIdentifier(A11yID.ConversationControls.modelKeySignIn(client.id))

        }
    }

    private func membershipCard(_ account: any SubscriptionAccount) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Colors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: plan.map { "\(account.providerName) \($0)" } ?? "Signed in to \(account.providerName)")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                if let accountLabel {
                    Text(verbatim: accountLabel)
                        .font(Theme.Fonts.captionMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
            Spacer()
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                showSignOutConfirm = true
            }
            .labelStyle(.iconOnly)
            .font(.system(.body, weight: .medium))
            .accessibilityIdentifier(A11yID.ConversationControls.modelKeyRemove)
        }
        .settingsRowPadding()
        .settingsSurface(singleRow: true)
    }

    private var credentialDescription: String {
        switch client.credentialKind {
        case .apiKey:
            "Create your \(credentialProviderName) API key, then paste it here."
        case .subscriptionKey:
            "Paste the key issued for your \(client.displayName) subscription."
        case .bearerToken:
            "Add a bearer token if your \(client.displayName) server requires one."
        }
    }

    private var credentialProviderName: String {
        if client.displayName.hasSuffix(" API") { return String(client.displayName.dropLast(4)) }
        return client.displayName.replacingOccurrences(of: " API ·", with: " ·")
    }

    private func enterAPIKey() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            let website = client.website.map {
                CredentialEntryPrompt.Website(url: $0, label: String(localized: "Get API Key"), accessibilityIdentifier: A11yID.ConversationControls.modelKeyWebsite)
            }
            do {
                let values = try await CredentialEntryPrompt.enter(
                    title: client.displayName,
                    fields: [.init(label: "\(credentialProviderName) \(client.credentialKind.name.lowercased())", value: apiKey, secure: true, contentType: nil, accessibilityIdentifier: A11yID.ConversationControls.modelKeyField)],
                    website: website,
                    accessibilityIdentifier: "provider.authentication",
                    validate: { values in
                        !values[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !values[0].contains("\r") && !values[0].contains("\n")
                    }
                )
                try ProviderCredentialEntry.save(values[0], for: client)
                apiKey = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
                signInError = nil
                onChange()
                onAuthenticated?()
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    private func signIn(_ account: any SubscriptionAccount) {
        guard !busy else { return }
        busy = true
        Task {
            signInError = nil
            let signedInSuccessfully: Bool
            do {
                signedInSuccessfully = try await account.signIn(using: SubscriptionAuthorizationPresenter(
                    oauth: { authorizeURL, redirectPrefix in
                        await OAuthWebLogin.present(authorizeURL: authorizeURL, redirectPrefix: redirectPrefix)
                    },
                    device: { authorizeURL, userCode, poll in
                        await OAuthWebLogin.presentDevice(
                            authorizeURL: authorizeURL,
                            userCode: userCode,
                            poll: poll
                        )
                    }
                ))
            } catch {
                signedInSuccessfully = false
                signInError = (error as? ProviderClientError)?.message ?? error.localizedDescription
                Log.ui.error("ProviderAuthentication.signIn client=\(client.id) error=\(signInError ?? "unknown")")
            }
            busy = false
            refreshSubscription(account)
            if signedInSuccessfully {
                onChange()
                onAuthenticated?()
            }
        }
    }

    private func refreshSubscription(_ account: any SubscriptionAccount) {
        signedIn = account.isSignedIn
        plan = account.planLabel
        accountLabel = account.accountLabel
    }

    private func signOut(_ account: any SubscriptionAccount) {
        Log.ui.info("ProviderAuthentication.signOut client=\(client.id)")
        signInError = nil
        account.signOut()
        refreshSubscription(account)
        onChange()
    }
}
