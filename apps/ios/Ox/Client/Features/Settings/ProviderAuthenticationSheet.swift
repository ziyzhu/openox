import SwiftUI

@MainActor enum ProviderCredentialEntry {
    static func save(_ value: String, for client: any ProviderClient) throws {
        let credential = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { throw RuntimeError.bridge("A credential is required") }
        let definition = try ProviderRegistry.shared.definition(id: client.id)
        try Secret.saveProviderKey(credential, definition: definition)
    }
}

struct ProviderAuthenticationSheet: View {
    let session: ProviderAuthenticationSession
    @State private var credential = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(verbatim: session.definition.url.absoluteString)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .textSelection(.enabled)
                    ProviderAuthenticationView(
                        client: session.client,
                        apiKey: $credential,
                        onChange: {},
                        onAuthenticated: {
                            session.complete(session.client.subscriptionAccount?.isSignedIn == true ? .authenticated : .credentialStored)
                            dismiss()
                        }
                    )
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle(session.definition.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.complete(.cancelled)
                        dismiss()
                    }
                    .accessibilityIdentifier("provider.authentication.cancel")
                }
                if session.client.subscriptionAccount?.isSignedIn == true {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            session.complete(.authenticated)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { session.complete(.cancelled) }
    }
}
