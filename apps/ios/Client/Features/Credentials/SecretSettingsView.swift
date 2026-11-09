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
            .accessibilityIdentifier("secret-settings-add")
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
                    Group {
                        if !available { Text("Unavailable") }
                        else if let type = entry.type { Text(type.title) + Text(verbatim: entry.serviceID.map { " · \($0)" } ?? "") }
                        else { Text("Needs setup") }
                    }
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .settingsRowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("secret-settings-row-\(entry.key)")
    }

    private func reload() {
        do {
            try Secret.inferMissingTypes()
            entries = try Secret.userManagedEntries().sorted {
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
                if let entry {
                    if entry.type == nil, let fields {
                        SecretFieldMappingView(key: key, storedFields: fields.map(\.name), onMapped: reload)
                    }
                    valuesSection
                    if entry.type != nil, entry.usePolicy == .reusable {
                        SecretAccessRulesView(entry: entry, onChange: reload)
                    }
                    actionsSection
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
                .disabled(entry?.type == nil)
                .accessibilityIdentifier("secret-detail-edit")
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

    private var valuesSection: some View {
        SettingsSection(layout: .group) {
            VStack(spacing: 0) {
                if let fields {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { Divider().settingsContentInset() }
                        SecretFieldLayout(spacing: Theme.Spacing.md) {
                            Text(verbatim: field.name)
                                .font(Theme.Fonts.bodyMd)
                                .lineLimit(1)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            ScrollView(.horizontal) {
                                Text(verbatim: showsValues || field.name == "username" ? field.value : "••••••••")
                                    .font(.system(.body, design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled)
                                    .privacySensitive()
                            }
                            .scrollIndicators(.hidden)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .frame(minWidth: 0, maxWidth: .infinity)
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
    }

    private var actionsSection: some View {
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
                .accessibilityIdentifier("secret-detail-show")
                Divider().settingsContentInset()
            }
            Button(role: .destructive) { confirmingDelete = true } label: {
                Text("Delete Secret")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.error)
                    .settingsRowPadding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("secret-detail-delete")
        }
        .settingsSurface()
        .buttonStyle(.plain)
    }

    private func reload() {
        do {
            showsValues = false
            try Secret.inferMissingTypes()
            entry = try Secret.entry(key: key)
            let order = entry?.type?.fields ?? []
            fields = try Secret.value(key: key).map(SecretFieldCodec.decode)?.sorted {
                (order.firstIndex(of: $0.name) ?? order.count, $0.name) < (order.firstIndex(of: $1.name) ?? order.count, $1.name)
            }
            error = nil
        } catch {
            fields = nil
            self.error = error.localizedDescription
        }
    }
}

private struct SecretFieldMappingView: View {
    let key: String
    let storedFields: [String]
    let onMapped: () -> Void

    @State private var type = SecretType.account
    @State private var mapping: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        SettingsSection("Needs setup", layout: .group) {
            VStack(spacing: 0) {
                Picker("Type", selection: $type) {
                    ForEach(SecretType.allCases) { Text($0.title).tag($0) }
                }
                .settingsRowPadding()
                .accessibilityIdentifier("secret-mapping-type")
                ForEach(type.fields, id: \.self) { field in
                    Divider().settingsContentInset()
                    Picker(type.fieldTitle(field), selection: Binding(get: { mapping[field] ?? "" }, set: { mapping[field] = $0 })) {
                        Text("Choose").tag("")
                        ForEach(storedFields, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .settingsRowPadding()
                    .accessibilityIdentifier("secret-mapping-\(field)")
                }
                Divider().settingsContentInset()
                Button("Save Type", action: save)
                    .font(Theme.Fonts.bodyMd)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowPadding()
                    .disabled(!type.fields.allSatisfy { !(mapping[$0] ?? "").isEmpty })
                    .accessibilityIdentifier("secret-mapping-save")
                if let error {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error.dynamic)
                        .settingsRowPadding()
                }
            }
        }
        .onChange(of: type) { _, _ in mapping = [:] }
    }

    private func save() {
        do {
            try Secret.mapFields(key: key, type: type, from: mapping)
            onMapped()
        } catch { self.error = error.localizedDescription }
    }
}

private struct SecretAccessRulesView: View {
    let entry: SecretEntry
    let onChange: () -> Void

    @State private var error: String?

    var body: some View {
        SettingsSection("Allowed actions", layout: .group) {
            VStack(spacing: 0) {
                let rules = entry.access ?? []
                if rules.isEmpty {
                    Text("Ox asks before any action uses this secret.")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsRowPadding()
                }
                ForEach(Array(rules.enumerated()), id: \.element.consumer) { index, rule in
                    if index > 0 { Divider().settingsContentInset() }
                    ActionPolicyPicker(
                        title: LocalizedStringKey(rule.consumer),
                        selection: rule.policy,
                        resolved: rule.policy,
                        inheritLabel: "Remove Rule"
                    ) { policy in
                        do {
                            try Secret.setAccess(key: entry.key, consumer: rule.consumer, policy: policy)
                            onChange()
                        } catch { self.error = error.localizedDescription }
                    }
                    .settingsRowPadding()
                    .accessibilityIdentifier("secret-rule-\(rule.consumer)")
                }
                if let error {
                    Text(error)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.error.dynamic)
                        .settingsRowPadding()
                }
            }
        }
    }
}

private struct SecretEntryEditorView: View {
    let entry: SecretEntry?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var type = SecretType.account
    @State private var domain = ""
    @State private var values: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(layout: .group) {
                        VStack(spacing: 0) {
                            if entry == nil {
                                Picker("Type", selection: $type) {
                                    ForEach(SecretType.allCases) { Text($0.title).tag($0) }
                                }
                                .settingsRowPadding()
                                .accessibilityIdentifier("secret-editor-type")
                                Divider().settingsContentInset()
                                TextField("Key", text: $key)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .settingsRowPadding()
                                    .accessibilityIdentifier("secret-editor-key")
                                Divider().settingsContentInset()
                                TextField("Website or service domain", text: $domain)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .keyboardType(.URL)
                                    .settingsRowPadding()
                                    .accessibilityIdentifier("secret-editor-domain")
                            } else {
                                Text(verbatim: key)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .settingsRowPadding()
                            }
                        }
                    }
                    SettingsSection(type.title, layout: .group) {
                        SecretTypedFieldsEditor(type: type, values: $values)
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
                        .disabled(key.isEmpty || !type.isComplete(values))
                        .accessibilityIdentifier("secret-editor-save")
                }
            }
            .onAppear {
                key = entry?.key ?? ""
                type = entry?.type ?? .account
                values = entry.flatMap { try? Secret.fields(key: $0.key) } ?? [:]
            }
            .onChange(of: type) { _, _ in if entry == nil { values = [:] } }
        }
    }

    private var serviceID: String? {
        if let entry { return entry.serviceID }
        let host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        return "\(type == .account ? "web" : "api"):\(host)"
    }

    private func save() {
        do {
            let spec = SecretEntrySpec(key: key, type: type, serviceID: serviceID)
            try Secret.setTyped(key: key, displayName: entry?.displayName ?? spec.displayName(values: values),
                                type: type, serviceID: serviceID, values: values,
                                origin: entry?.origin ?? .named, usePolicy: entry?.usePolicy ?? .reusable)
            onSaved()
        } catch { self.error = error.localizedDescription }
    }
}
