import SwiftUI

struct SecretEntryRequestCard: View {
    let request: SecretEntryRequest
    let onSaved: () -> Void
    let onCancel: () -> Void

    @Environment(\.appTheme) private var appTheme
    @State private var displayName: String
    @State private var token = ""
    @StateObject private var fieldModel: SecretFieldsModel
    @State private var error: String?
    private let isEditing: Bool

    init(request: SecretEntryRequest, onSaved: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSaved = onSaved
        self.onCancel = onCancel
        switch request.form {
        case .named(let key):
            let entry = try? Secret.entry(key: key)
            isEditing = entry != nil
            _displayName = State(initialValue: entry?.displayName ?? key)
            let savedValue = try? Secret.value(key: key)
            let fields = savedValue.flatMap { try? SecretFieldCodec.decode($0) }
            _fieldModel = StateObject(wrappedValue: SecretFieldsModel(fields: fields ?? [SecretFieldDraft(name: "", value: "")]))
        case .githubPublication:
            isEditing = false
            _displayName = State(initialValue: "")
            _fieldModel = StateObject(wrappedValue: SecretFieldsModel())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Group {
                switch request.form {
                case .named:
                    if isEditing { Text("Edit Secret") }
                    else { Text("Add Secret") }
                case .githubPublication:
                    Text("GitHub personal access token")
                }
            }
            .font(Theme.Fonts.title)
            .foregroundStyle(Theme.Colors.onSurface)
            Group {
                switch request.form {
                case .named:
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.sentences)
                    SecretFieldsEditor(model: fieldModel)
                case .githubPublication:
                    Text("Use a classic token with public_repo access. It is saved in Secrets and never sent to the model. After creating a token, return to Ox and paste it here.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    Link("Create token", destination: URL(string: "https://github.com/settings/tokens/new?scopes=public_repo&description=OpenOx")!)
                    SecureField("GitHub token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityIdentifier("repository.github.token")
                }
            }
            .disabled(request.state != .editing)
            if let message = request.error ?? error {
                Text(message)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error.dynamic)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Spacer(minLength: 0)
                RequestPillButton(title: String(localized: "Cancel"), isPrimary: false) {
                    request.cancel()
                    onCancel()
                }
                RequestPillButton(
                    title: saveTitle,
                    isPrimary: true,
                    isLoading: request.state == .saving,
                    action: save
                )
                .disabled(!canSave || request.state != .editing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .id(appTheme)
        }
        .accessibilityElement(children: .contain)
    }

    private var saveTitle: String {
        switch request.form {
        case .named: String(localized: "Save")
        case .githubPublication: String(localized: "Save and continue")
        }
    }

    private var canSave: Bool {
        switch request.form {
        case .named: !displayName.isEmpty && !fieldModel.fields.isEmpty
        case .githubPublication: !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() {
        error = nil
        do {
            let value = switch request.form {
            case .named: try SecretFieldCodec.encode(fieldModel.fields)
            case .githubPublication: token
            }
            request.submit(displayName: displayName, value: value) {
                token = ""
                fieldModel.fields.removeAll()
                onSaved()
            }
        } catch { self.error = error.localizedDescription }
    }
}
