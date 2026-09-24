import SwiftUI

struct SecretSettingsView: View {
    @State private var entries: [SecretEntry] = []
    @State private var showingEditor = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                if let error {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error.dynamic)
                        .settingsContentInset()
                }
                VStack(spacing: 0) {
                    if entries.isEmpty {
                        Text("No secrets saved")
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .settingsRowPadding()
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 { Divider().settingsContentInset() }
                        entryRow(entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsSurface()
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Secrets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                showingEditor = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add Secret")
        }
        .sheet(isPresented: $showingEditor, onDismiss: reload) {
            SecretEntryEditorView(entry: nil, onSaved: {
                showingEditor = false
                reload()
            })
        }
        .onAppear(perform: reload)
    }

    private func entryRow(_ entry: SecretEntry) -> some View {
        let available = (try? Secret.value(key: entry.key)) != nil
        return NavigationLink {
            SecretEntryDetailView(key: entry.key)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(verbatim: entry.displayName)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .lineLimit(1)
                    if !available {
                        Text("Unavailable")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .settingsRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        do {
            entries = try Secret.entries().sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct SecretEntryDetailView: View {
    let key: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var entry: SecretEntry?
    @State private var fields: [SecretFieldDraft]?
    @State private var showsValues = false
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                if entry != nil {
                    SettingsSection("Fields", insetContent: false) {
                        VStack(spacing: 0) {
                            if let fields {
                                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                                    if index > 0 { Divider().settingsContentInset() }
                                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                        Text(verbatim: field.name)
                                            .font(Theme.Fonts.bodyMd)
                                        ScrollView(.horizontal) {
                                            if showsValues {
                                                Text(verbatim: field.value)
                                                    .font(.system(.body, design: .monospaced))
                                                    .fixedSize(horizontal: true, vertical: false)
                                                    .textSelection(.enabled)
                                                    .privacySensitive()
                                            } else {
                                                Text(verbatim: "••••••••")
                                                    .font(.system(.body, design: .monospaced))
                                                    .privacySensitive()
                                            }
                                        }
                                        .scrollIndicators(.hidden)
                                    }
                                    .settingsRowPadding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                Text("Unavailable")
                                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                                    .settingsRowPadding()
                            }
                        }
                    }
                    VStack(spacing: 0) {
                        if fields != nil {
                            Button {
                                showsValues.toggle()
                            } label: {
                                Group {
                                    if showsValues { Text("Hide") }
                                    else { Text("Show") }
                                }
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.primary)
                                .settingsRowPadding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            Divider().settingsContentInset()
                        }
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Text("Delete secret")
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.error)
                                .settingsRowPadding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                    .settingsSurface()
                    .buttonStyle(.plain)
                }
                if let error {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error.dynamic)
                        .settingsContentInset()
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(entry.map { Text(verbatim: $0.displayName) } ?? Text("Secrets"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { showingEditor = true }
                .disabled(entry == nil)
        }
        .sheet(isPresented: $showingEditor, onDismiss: reload) {
            SecretEntryEditorView(entry: entry, onSaved: {
                showingEditor = false
                reload()
            })
        }
        .alert("Delete this secret?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                do {
                    try Secret.delete(key: key)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("This secret will be permanently deleted.")
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
            else {
                fields = nil
                showsValues = false
            }
        }
        .onDisappear {
            fields = nil
            showsValues = false
        }
    }

    private func reload() {
        do {
            showsValues = false
            entry = try Secret.entry(key: key)
            fields = try Secret.value(key: key).map(SecretFieldCodec.decode)
            error = nil
        } catch {
            fields = nil
            self.error = error.localizedDescription
        }
    }
}

private struct SecretEntryEditorView: View {
    let entry: SecretEntry?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var displayName = ""
    @StateObject private var fieldModel: SecretFieldsModel
    @State private var error: String?

    init(entry: SecretEntry?, onSaved: @escaping () -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        let savedValue = entry.flatMap { try? Secret.value(key: $0.key) }
        let fields = savedValue.flatMap { try? SecretFieldCodec.decode($0) }
        _fieldModel = StateObject(wrappedValue: SecretFieldsModel(fields: fields ?? [SecretFieldDraft(name: "", value: "")]))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection("Entry", insetContent: false) {
                        VStack(spacing: 0) {
                            if entry == nil {
                                TextField("Key", text: $key)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .settingsRowPadding()
                                Divider().settingsContentInset()
                            } else {
                                Text(verbatim: key)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .settingsRowPadding()
                                Divider().settingsContentInset()
                            }
                            TextField("Display name", text: $displayName)
                                .settingsRowPadding()
                        }
                    }
                    SettingsSection("Fields", insetContent: false) {
                        SecretFieldsEditor(model: fieldModel)
                            .settingsRowPadding()
                    }
                    if let error {
                        Text(error)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.error.dynamic)
                            .settingsContentInset()
                    }
                }
                .settingsPagePadding()
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle(entry == nil ? "Add Secret" : "Edit Secret")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(key.isEmpty || displayName.isEmpty || fieldModel.fields.isEmpty)
                }
            }
            .onAppear {
                key = entry?.key ?? ""
                displayName = entry?.displayName ?? ""
            }
        }
    }

    private func save() {
        do {
            let value = try SecretFieldCodec.encode(fieldModel.fields)
            try Secret.set(key: key, displayName: displayName, value: value,
                          origin: entry?.origin ?? .named, usePolicy: entry?.usePolicy ?? .reusable)
            onSaved()
        } catch { self.error = error.localizedDescription }
    }
}
