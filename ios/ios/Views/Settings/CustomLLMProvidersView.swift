import SwiftUI

struct CustomLLMProvidersView: View {
    @State private var addingProvider = false
    private var registry: LLMRegistry { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.headerSpacing) {
                Text("Connect Ox to any server that implements the OpenAI Chat Completions protocol.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)

                if registry.customProviders.isEmpty {
                    VStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Theme.Colors.primary)
                        Text("No custom providers")
                            .font(Theme.Fonts.title)
                            .foregroundStyle(Theme.Colors.onSurface)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.xl)
                    .settingsSurface()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(registry.customProviders.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 { Divider().settingsContentInset() }
                            NavigationLink {
                                CustomLLMProviderEditor(provider: provider)
                            } label: {
                                providerRow(provider)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.customProvider(provider.id.uuidString))
                        }
                    }
                    .settingsSurface()
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Model Providers")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $addingProvider) {
            CustomLLMProviderEditor(provider: nil)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add provider", systemImage: "plus") {
                    addingProvider = true
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier(A11yID.Settings.customProviderAdd)
            }
        }
    }

    private func providerRow(_ provider: CustomLLMProvider) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "server.rack")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: provider.name)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(verbatim: "\(provider.models.count) \(provider.models.count == 1 ? "model" : "models") · \(provider.baseURL.host ?? provider.baseURL.absoluteString)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }
}

struct CustomLLMProviderEditor: View {
    let provider: CustomLLMProvider?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var apiKey = ""
    @State private var models: [CustomLLMModel]
    @State private var saving = false
    @State private var saveError: String?
    @State private var confirmingDelete = false

    init(provider: CustomLLMProvider?) {
        self.provider = provider
        _name = State(initialValue: provider?.name ?? "")
        _baseURL = State(initialValue: provider?.baseURL.absoluteString ?? "")
        _models = State(initialValue: provider?.models ?? [])
    }

    private var normalizedBaseURL: URL? {
        CustomLLMProviderDiscovery.normalizedBaseURL(baseURL)
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = models.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
        return !trimmedName.isEmpty
            && normalizedBaseURL != nil
            && ids.allSatisfy { !$0.isEmpty }
            && Set(ids).count == ids.count
            && models.allSatisfy { $0.maxTokens > 0 && $0.maxContext >= $0.maxTokens }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                providerFields
                modelsSection
                if provider != nil {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text("Remove Provider")
                            .font(Theme.Fonts.labelMd)
                            .foregroundStyle(Theme.Colors.error)
                            .settingsRowPadding()
                            .frame(maxWidth: .infinity)
                            .settingsSurface(singleRow: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11yID.Settings.customProviderDelete)
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(provider == nil ? "Add Provider" : "Edit Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { save() } label: {
                    if saving {
                        CellularAutomatonLoader.small
                    } else {
                        Text("Save")
                            .font(Theme.Fonts.labelMd)
                    }
                }
                .disabled(!canSave || saving)
                .accessibilityLabel("Save")
                .accessibilityIdentifier(A11yID.Settings.customProviderSave)
            }
        }
        .confirmationDialog(
            "Remove \(provider?.name ?? "this provider")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its endpoint and saved API key will be removed from this device.")
        }
    }

    private var providerFields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Provider")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()
            VStack(spacing: 0) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .font(Theme.Fonts.bodyMd)
                    .settingsRowPadding()
                    .accessibilityIdentifier(A11yID.Settings.customProviderName)
                Divider().settingsContentInset()
                TextField("Server URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .settingsRowPadding()
                    .accessibilityIdentifier(A11yID.Settings.customProviderURL)
                Divider().settingsContentInset()
                SecureField(provider == nil ? "API key (optional)" : "New API key (optional)", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.Fonts.bodyMd)
                    .settingsRowPadding()
                    .accessibilityIdentifier(A11yID.Settings.customProviderKey)
            }
            .settingsSurface()
            Text("Addresses without a path use /v1. On a physical iPhone, use the server computer's local hostname or IP address, not localhost.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsContentInset()
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Models")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsSectionHeaderInset()

            if let saveError {
                Text(saveError)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.error)
                    .settingsContentInset()
            }

            if models.isEmpty {
                Text("Empty")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsRowPadding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsSurface(singleRow: true)
            } else {
                ForEach($models) { $model in
                    modelCard($model)
                }
            }
        }
    }

    private func modelCard(_ model: Binding<CustomLLMModel>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                TextField("Model ID", text: model.id)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.Fonts.bodyMd.monospaced())
                Button(role: .destructive) {
                    models.removeAll { $0.id == model.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.Colors.error)
                }
                .accessibilityLabel("Remove \(model.wrappedValue.id)")
            }

            TextField("Display name", text: model.displayName)
                .font(Theme.Fonts.bodyMd)

            HStack(spacing: Theme.Spacing.md) {
                numericField("Context", value: model.maxContext)
                numericField("Maximum output", value: model.maxTokens)
            }

            Toggle("Agent tools", isOn: model.supportsTools)
                .font(Theme.Fonts.bodyMd)
                .tint(Theme.Colors.primary)
            Text("Enable tools only when this model and server are configured for OpenAI function calling.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .padding(Theme.Spacing.md)
        .settingsSurface()
        .accessibilityIdentifier(A11yID.Settings.customProviderModel(model.wrappedValue.id))
    }

    private func numericField(_ label: LocalizedStringKey, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .font(Theme.Fonts.bodyMd.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard canSave, let url = normalizedBaseURL else { return }
        saving = true
        saveError = nil
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedKey = provider.flatMap { Credentials.key(for: $0.clientID) }
        let discoveryKey = trimmedKey.isEmpty ? storedKey : trimmedKey
        Task {
            defer { saving = false }
            do {
                let discovered = try await CustomLLMProviderDiscovery.models(baseURL: url, apiKey: discoveryKey)
                let existing = models.reduce(into: [String: CustomLLMModel]()) { result, model in
                    result[model.id] = model
                }
                let refreshedModels = discovered.map { discoveredModel in
                    var model = existing[discoveredModel.id] ?? discoveredModel
                    model.id = discoveredModel.id
                    if discoveredModel.supportsTools { model.supportsTools = true }
                    model.displayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.displayName.isEmpty { model.displayName = discoveredModel.id }
                    return model
                }
                let saved = CustomLLMProvider(
                    id: provider?.id ?? UUID(),
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    baseURL: url,
                    models: refreshedModels
                )
                models = refreshedModels
                LLMRegistry.shared.upsert(saved)
                if !trimmedKey.isEmpty { Credentials.set(trimmedKey, for: saved.clientID) }
                Haptics.success(.settingsSaved)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func remove() {
        guard let provider else { return }
        LLMRegistry.shared.remove(provider)
        dismiss()
    }
}
