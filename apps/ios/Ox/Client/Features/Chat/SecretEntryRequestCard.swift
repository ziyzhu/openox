import SwiftUI

struct SecretEntryRequestCard: View {
    let key: String
    let isEditing: Bool
    let onSave: (String, String) -> String?
    let onCancel: () -> Void

    @State private var displayName = ""
    @StateObject private var fieldModel: SecretFieldsModel
    @State private var error: String?

    init(key: String, onSave: @escaping (String, String) -> String?, onCancel: @escaping () -> Void) {
        self.key = key
        self.isEditing = (try? Secret.entry(key: key)) != nil
        self.onSave = onSave
        self.onCancel = onCancel
        let savedValue = try? Secret.value(key: key)
        let fields = savedValue.flatMap { try? SecretFieldCodec.decode($0) }
        _fieldModel = StateObject(wrappedValue: SecretFieldsModel(fields: fields ?? [SecretFieldDraft(name: "", value: "")]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Group {
                if isEditing { Text("Edit Secret") }
                else { Text("Add Secret") }
            }
            .font(Theme.Fonts.labelMd)
            Text(verbatim: key)
                .font(Theme.Fonts.caption.monospaced())
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            TextField("Display name", text: $displayName)
                .textInputAutocapitalization(.sentences)
            SecretFieldsEditor(model: fieldModel)
            if let error {
                Text(error)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error.dynamic)
            }
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save", action: save)
                .disabled(displayName.isEmpty || fieldModel.fields.isEmpty)
            }
        }
        .padding(Theme.Spacing.md)
        .settingsSurface()
        .onAppear {
            displayName = (try? Secret.entry(key: key))?.displayName ?? key
        }
    }

    private func save() {
        do {
            let value = try SecretFieldCodec.encode(fieldModel.fields)
            error = onSave(displayName, value)
        } catch { self.error = error.localizedDescription }
    }
}
