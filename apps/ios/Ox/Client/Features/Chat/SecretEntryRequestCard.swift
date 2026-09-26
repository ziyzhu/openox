import SwiftUI

struct SecretEntryRequestCard: View {
    let request: SecretEntryRequest
    let onSaved: () -> Void
    let onCancel: () -> Void

    @Environment(\.appTheme) private var appTheme
    @State private var displayName: String
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
            _displayName = State(initialValue: "OpenOx GitHub publication token")
            _fieldModel = StateObject(wrappedValue: SecretFieldsModel(fields: [SecretFieldDraft(name: "token", value: "")]))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Group {
                if isEditing { Text("Edit Secret") }
                else { Text("Add Secret") }
            }
            .font(Theme.Fonts.title)
            .foregroundStyle(Theme.Colors.onSurface)
            Group {
                if case .githubPublication = request.form {
                    Text("Use a classic token with public_repo access. [Create token](https://github.com/settings/tokens/new?scopes=public_repo&description=OpenOx), then return to Ox and paste it below. It is saved in Secrets and never sent to the model.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                TextField("Display name", text: $displayName)
                    .textInputAutocapitalization(.sentences)
                SecretFieldsEditor(model: fieldModel)
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
                    title: String(localized: "Save"),
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

    private var canSave: Bool {
        !displayName.isEmpty && !fieldModel.fields.isEmpty
    }

    private func save() {
        error = nil
        do {
            let value = try SecretFieldCodec.encode(fieldModel.fields)
            request.submit(displayName: displayName, value: value) {
                fieldModel.fields.removeAll()
                onSaved()
            }
        } catch { self.error = error.localizedDescription }
    }
}
