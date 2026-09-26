import SwiftUI

struct ProviderAuthenticationView: View {
    private struct WebsiteSignIn: Identifiable {
        let id = UUID()
        let session: ServiceBrowserSession
        let dismissWhenAuthenticated: Bool
    }

    private enum AuthenticationMethod {
        case apiKey
        case subscription
    }

    private enum WebsiteAuthenticationStatus {
        case checking
        case signedIn
        case signedOut
        case unavailable
    }

    let client: any ProviderClient
    @Binding var apiKey: String
    let onChange: () -> Void
    var onAuthenticated: (() -> Void)? = nil
    @Environment(ServiceManager.self) private var serviceManager

    @State private var authenticationMethod: AuthenticationMethod
    @State private var apiKeySaved = false
    @State private var signedIn = false
    @State private var plan: String?
    @State private var accountLabel: String?
    @State private var busy = false
    @State private var showSignOutConfirm = false
    @State private var signInError: String?
    @State private var websiteSignIn: WebsiteSignIn?
    @State private var websiteAuthenticationStatus: WebsiteAuthenticationStatus = .checking
    @State private var websiteAuthenticationRevision = 0
    @State private var websiteAuthenticationCompleted = false

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
                if client.models.first.flatMap({ client.wireProtocol(for: $0) }) == .web, let website = client.website {
                    Button {
                        let session = ServiceBrowserSession(url: website, serviceManager: serviceManager)
                        websiteAuthenticationCompleted = false
                        WebsiteAuthenticationCache.invalidate(client.id)
                        websiteSignIn = WebsiteSignIn(
                            session: session,
                            dismissWhenAuthenticated: websiteAuthenticationStatus != .signedIn
                        )
                        websiteAuthenticationRevision &+= 1
                    } label: {
                        if websiteAuthenticationStatus == .signedIn {
                            websiteSignedInRow
                        } else {
                            SettingsActionButtonLabel {
                                Text("Sign in with \(client.displayName)")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11yID.Chat.modelKeySignIn(client.id))
                } else {
                    Text("Not required")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsRowPadding()
                        .settingsSurface(singleRow: true)
                        .accessibilityIdentifier(A11yID.Chat.modelAuthNone)
                }
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
        .task(id: websiteAuthenticationRevision) {
            guard client.models.first.flatMap({ client.wireProtocol(for: $0) }) == .web,
                  websiteSignIn == nil else { return }
            if let cached = WebsiteAuthenticationCache.status(for: client.id) {
                websiteAuthenticationStatus = cached ? .signedIn : .signedOut
                return
            }
            websiteAuthenticationStatus = .checking
            let revision = websiteAuthenticationRevision
            do {
                let signedIn = try await client.websiteSessionIsAuthenticated()
                guard !Task.isCancelled, websiteSignIn == nil, websiteAuthenticationRevision == revision else { return }
                if let signedIn { WebsiteAuthenticationCache.set(signedIn, for: client.id) }
                websiteAuthenticationStatus = signedIn == true ? .signedIn : .signedOut
            } catch {
                guard !Task.isCancelled, websiteSignIn == nil, websiteAuthenticationRevision == revision else { return }
                websiteAuthenticationStatus = .unavailable
                Log.ui.warning("ProviderAuthentication.websiteStatus client=\(client.id) error=\(LogPrivacy.text(error.localizedDescription))")
            }
        }
        .sheet(item: $websiteSignIn, onDismiss: {
            websiteAuthenticationRevision &+= 1
            if websiteAuthenticationCompleted {
                websiteAuthenticationCompleted = false
                onAuthenticated?()
            }
        }) { signIn in
            ServiceBrowserView(session: signIn.session, reservesWebsiteSpace: true)
                .task { await monitorWebsiteAuthentication(for: signIn) }
        }
    }

    private func monitorWebsiteAuthentication(for signIn: WebsiteSignIn) async {
        guard signIn.dismissWhenAuthenticated else { return }
        while !Task.isCancelled {
            do {
                if try await client.websiteSessionIsAuthenticated() == true {
                    guard !Task.isCancelled, websiteSignIn?.id == signIn.id else { return }
                    WebsiteAuthenticationCache.set(true, for: client.id)
                    websiteAuthenticationStatus = .signedIn
                    websiteAuthenticationCompleted = true
                    websiteSignIn = nil
                    Log.ui.info("ProviderAuthentication.websiteSignedIn client=\(client.id)")
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                Log.ui.warning("ProviderAuthentication.websiteSignInCheck client=\(client.id) error=\(LogPrivacy.text(error.localizedDescription))")
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private var websiteSignedInRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.Colors.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: client.displayName)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text("Signed in")
                    .font(Theme.Fonts.captionMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(Theme.Icons.xs)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .settingsSurface(singleRow: true)
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
        HStack {
            APIKeySecureField(
                placeholder: "\(credentialProviderName) \(client.credentialKind.name.lowercased())",
                text: Binding(
                    get: { apiKey },
                    set: {
                        apiKey = $0
                        apiKeySaved = false
                        signInError = nil
                    }
                )
            )
            .accessibilityIdentifier(A11yID.Chat.modelKeyField)

            Button {
                do {
                    try ProviderCredentialEntry.save(apiKey, for: client)
                    signInError = nil
                    apiKeySaved = true
                    onChange()
                    onAuthenticated?()
                } catch { signInError = error.localizedDescription }
            } label: {
                Group {
                    if apiKeySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                    } else {
                        Text("Save")
                            .font(Theme.Fonts.labelMd)
                    }
                }
                .foregroundStyle(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Theme.Colors.onSurfaceMuted : Theme.Colors.primary)
                .fixedSize()
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(apiKeySaved || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(apiKeySaved ? "Saved" : "Save")
            .accessibilityIdentifier("provider.authentication.save")
        }
        .padding(.horizontal, SettingsLayout.horizontalInset)
        .padding(.vertical, Theme.Spacing.xs)
        .settingsSurface(singleRow: true)

        if let website = client.website {
            Link(destination: website) {
                SettingsActionButtonLabel {
                    Text("Get API Key")
                    Image(systemName: "arrow.up.right")
                        .font(Theme.Icons.xs)
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
