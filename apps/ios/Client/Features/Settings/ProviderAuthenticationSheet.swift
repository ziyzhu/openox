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

    var body: some View {
        NavigationStack {
            ModelPickerContent(authenticationSession: session)
        }
        .presentationDetents([.medium, .large])
        .onDisappear { session.complete(.cancelled) }
    }
}
