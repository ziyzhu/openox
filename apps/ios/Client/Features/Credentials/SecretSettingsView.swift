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
            SecretCreationView(onSaved: {
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
                        else if let type = entry.type {
                            HStack(spacing: 0) {
                                Text(type.title)
                                if let serviceID = entry.serviceID { Text(verbatim: " · \(serviceID)") }
                            }
                        }
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
    private enum Mode: Equatable {
        case concealed
        case revealed
        case editing([String: String])
    }

    let key: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var entry: SecretEntry?
    @State private var fields: [SecretFieldDraft]?
    @State private var mode = Mode.concealed
    @State private var confirmingDelete = false
    @State private var error: String?

    private var draft: [String: String]? {
        if case .editing(let draft) = mode { draft } else { nil }
    }

    private var draftValues: Binding<[String: String]> {
        Binding(get: { draft ?? [:] }, set: { mode = .editing($0) })
    }

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
        .navigationBarBackButtonHidden(draft != nil)
        .toolbar {
            if let draft {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { mode = .concealed }
                        .accessibilityIdentifier("secret-detail-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(draft) }
                        .disabled(entry?.type?.isComplete(draft) != true)
                        .accessibilityIdentifier("secret-detail-save")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { mode = .editing((try? Secret.fields(key: key)) ?? [:]) }
                        .disabled(entry?.type == nil)
                        .accessibilityIdentifier("secret-detail-edit")
                }
            }
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
                mode = .concealed
            }
        }
        .onDisappear {
            fields = nil
            mode = .concealed
        }
    }

    private var valuesSection: some View {
        SettingsSection(layout: .group) {
            VStack(spacing: 0) {
                if let type = entry?.type, draft != nil {
                    ForEach(Array(type.fields.enumerated()), id: \.element) { index, field in
                        if index > 0 { Divider().settingsContentInset() }
                        fieldRow(field) {
                            SecretFieldInput(type: type, field: field, values: draftValues)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                } else if let fields {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { Divider().settingsContentInset() }
                        fieldRow(field.name) {
                            ScrollView(.horizontal) {
                                Text(verbatim: mode == .revealed || field.name == "username" ? field.value : "••••••••")
                                    .font(.system(.body, design: .monospaced))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .textSelection(.enabled)
                                    .privacySensitive()
                            }
                            .scrollIndicators(.hidden)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        }
                    }
                } else {
                    Text("Unavailable")
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .settingsRowPadding()
                }
            }
        }
    }

    private func fieldRow(_ name: String, @ViewBuilder value: () -> some View) -> some View {
        SecretFieldLayout(spacing: Theme.Spacing.md) {
            Text(verbatim: name)
                .font(Theme.Fonts.bodyMd)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            value()
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .settingsRowPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsSection: some View {
        VStack(spacing: 0) {
            if fields != nil {
                Button {
                    mode = mode == .revealed ? .concealed : .revealed
                } label: {
                    Group {
                        if mode == .revealed { Text("Hide") }
                        else { Text("Show") }
                    }
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(draft == nil ? Theme.Colors.primary : Theme.Colors.onSurfaceMuted)
                    .settingsRowPadding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .disabled(draft != nil)
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

    private func conceal() {
        if mode == .revealed { mode = .concealed }
    }

    private func save(_ values: [String: String]) {
        guard let entry, let type = entry.type else { return }
        do {
            try Secret.setTyped(key: key, displayName: entry.displayName, type: type, serviceID: entry.serviceID,
                                values: values, origin: entry.origin, usePolicy: entry.usePolicy)
            mode = .concealed
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func reload() {
        do {
            conceal()
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

private struct SecretCreationView: View {
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
            .navigationTitle("Add Secret")
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
            .onChange(of: type) { _, _ in values = [:] }
        }
    }

    private var serviceID: String? {
        let host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        return "\(type == .account ? "web" : "api"):\(host)"
    }

    private func save() {
        do {
            let spec = SecretEntrySpec(key: key, type: type, serviceID: serviceID)
            try Secret.setTyped(key: key, displayName: spec.displayName(values: values),
                                type: type, serviceID: serviceID, values: values)
            onSaved()
        } catch { self.error = error.localizedDescription }
    }
}
