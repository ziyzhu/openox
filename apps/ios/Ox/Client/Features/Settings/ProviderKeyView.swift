import SwiftUI

struct ProviderAuthenticationView: View {
    private enum AuthenticationMethod {
        case apiKey
        case subscription
    }

    let client: any ProviderClient
    @Binding var apiKey: String
    let onChange: () -> Void

    @State private var authenticationMethod: AuthenticationMethod
    @State private var signedIn = false
    @State private var plan: String?
    @State private var accountLabel: String?
    @State private var busy = false
    @State private var showSignOutConfirm = false
    @State private var signInError: String?

    init(
        client: any ProviderClient,
        apiKey: Binding<String>,
        onChange: @escaping () -> Void
    ) {
        self.client = client
        _apiKey = apiKey
        self.onChange = onChange
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
                    .accessibilityIdentifier(A11yID.Chat.modelKeySignInError)
            }

            if let notice = client.authNotice {
                SettingsNoticeMessage(message: notice, systemImage: "info.circle.fill")
                    .accessibilityIdentifier(A11yID.Chat.modelKeyNotice)
            }

            if client.acceptsAPIKey, client.subscriptionAccount != nil {
                authenticationMethodPicker
            }

            if client.acceptsAPIKey, authenticationMethod == .apiKey {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    apiKeyContent
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.Chat.modelAuthAPIKey)
            }

            if let account = client.subscriptionAccount, authenticationMethod == .subscription {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    subscriptionContent(account)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.Chat.modelAuthOAuth)
            }

            if !client.acceptsAPIKey, client.subscriptionAccount == nil {
                Text("Not required")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowPadding()
                    .settingsSurface(singleRow: true)
                    .accessibilityIdentifier(A11yID.Chat.modelAuthNone)
            }
        }
        .alert("Sign out of \(client.displayName)?", isPresented: $showSignOutConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                if let account = client.subscriptionAccount { signOut(account) }
            }
        } message: {
            Text("You'll need to sign in again to use your \(client.displayName) subscription.")
        }
        .onAppear {
            if let account = client.subscriptionAccount { refreshSubscription(account) }
        }
    }

    private var authenticationMethodPicker: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Button("API Key") {
                authenticationMethod = .apiKey
            }
                .buttonStyle(OxChipButton(filled: authenticationMethod == .apiKey))
            Button("Subscription (OAuth)") {
                authenticationMethod = .subscription
            }
                .buttonStyle(OxChipButton(filled: authenticationMethod == .subscription))
        }
        .settingsContentInset()
    }

    @ViewBuilder
    private var apiKeyContent: some View {
        HStack {
            APIKeySecureField(
                placeholder: "\(client.displayName) \(client.credentialKind.name.lowercased())",
                text: $apiKey
            )
            .accessibilityIdentifier(A11yID.Chat.modelKeyField)
        }
        .settingsRowPadding()
        .settingsSurface(singleRow: true)

        if let website = client.website {
            Link(destination: website) {
                SettingsActionButtonLabel {
                    Text("Get API Key")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Get API Key")
            .accessibilityIdentifier(A11yID.Chat.modelKeyWebsite)
        }

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
            .accessibilityIdentifier(A11yID.Chat.modelKeySignIn(client.id))

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
            .accessibilityIdentifier(A11yID.Chat.modelKeyRemove)
        }
        .settingsRowPadding()
        .settingsSurface(singleRow: true)
    }

    private var credentialDescription: String {
        switch client.credentialKind {
        case .apiKey:
            "Create your \(client.displayName) API key, then paste it here."
        case .subscriptionKey:
            "Paste the key issued for your \(client.displayName) subscription."
        case .bearerToken:
            "Add a bearer token if your \(client.displayName) server requires one."
        }
    }

    private func signIn(_ account: any SubscriptionAccount) {
        Task {
            busy = true
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
            if signedInSuccessfully { onChange() }
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

private struct APIKeySecureField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = EndCursorSecureTextField()
        field.delegate = context.coordinator
        field.isSecureTextEntry = true
        field.clearsOnBeginEditing = false
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = Theme.Colors.onSurface.uiColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        field.placeholder = placeholder
        if field.text != text { field.text = text }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding private var text: String
        private var beganEditing = false

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textChanged(_ field: UITextField) {
            text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ field: UITextField) {
            beganEditing = true
            DispatchQueue.main.async {
                let end = field.endOfDocument
                field.selectedTextRange = field.textRange(from: end, to: end)
            }
        }

        func textField(
            _ field: UITextField,
            shouldChangeCharactersIn _: NSRange,
            replacementString string: String
        ) -> Bool {
            defer { beganEditing = false }
            let current = field.text ?? ""
            guard beganEditing, !current.isEmpty else { return true }
            let updated = string.isEmpty ? String(current.dropLast()) : current + string
            field.text = updated
            text = updated
            let end = field.endOfDocument
            field.selectedTextRange = field.textRange(from: end, to: end)
            return false
        }
    }
}

private final class EndCursorSecureTextField: UITextField {
    private var placesCursorAtEnd = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        placesCursorAtEnd = !isFirstResponder
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        placesCursorAtEnd = false
    }

    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        placesCursorAtEnd ? endOfDocument : super.closestPosition(to: point)
    }
}
