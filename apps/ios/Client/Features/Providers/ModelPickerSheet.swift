import SwiftUI

struct ModelPickerSheet: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    private var registry: ProviderRegistry { .shared }
    private var isChoosingInitialDefault: Bool { registry.defaultModel == nil }

    var body: some View {
        NavigationStack {
            ModelPickerContent(
                title: isChoosingInitialDefault ? "Choose default model" : "Model for this conversation",
                activeSelection: conversation.modelSelection,
                scopeDescription: isChoosingInitialDefault
                    ? "Your choice will be used for this conversation and future conversations."
                    : "Changes apply immediately and stay with this conversation.",
                onClose: { dismiss() }
            ) { client, model, selection in
                Log.ui.info("ModelPicker.select conversation=\(conversation.id) client=\(client.id) model=\(model.id) region=\(selection.region.rawValue)")
                if registry.defaultModel == nil {
                    registry.select(model, in: client.id, region: selection.region)
                }
                conversation.switchModel(to: client, model: model, selection: selection)
            }
        }
    }
}

struct ModelPickerContent: View {
    private enum ProviderSelection: Hashable {
        case client(String)
        case custom
    }

    private enum Mode {
        case selection((any ProviderClient, ProviderModel, ModelSelection) -> Void)
        case authentication(ProviderAuthenticationSession)
    }

    let title: LocalizedStringKey
    let activeSelection: ModelSelection
    let scopeDescription: LocalizedStringKey?
    var onClose: (() -> Void)?
    private let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var choosingProvider = false
    @State private var authRevision = 0
    @State private var selectedRegion: LLMRegion
    @State private var providerSelection: ProviderSelection
    @State private var selectedModelID: String
    @State private var selectedReasoningEffort: String
    @State private var apiKeyDraft = ""
    @State private var customName = ""
    @State private var customURL = ""
    @State private var customAPIKey = ""
    @State private var customModels: [CustomLLMModel] = []
    @State private var customModelID = ""
    @State private var customModelsLoading = false
    @State private var customError: String?
    @State private var providerCredentialError: String?
    @State private var providerModelsLoading = false
    @State private var providerModelsError: String?

    private var registry: ProviderRegistry { ProviderRegistry.shared }

    init(
        title: LocalizedStringKey,
        activeSelection: ModelSelection,
        scopeDescription: LocalizedStringKey? = nil,
        onClose: (() -> Void)? = nil,
        onSelect: @escaping (any ProviderClient, ProviderModel, ModelSelection) -> Void
    ) {
        self.title = title
        self.activeSelection = activeSelection
        self.scopeDescription = scopeDescription
        self.onClose = onClose
        mode = .selection(onSelect)
        _selectedRegion = State(initialValue: activeSelection.region)
        _providerSelection = State(initialValue: .client(activeSelection.providerID))
        _selectedModelID = State(initialValue: activeSelection.modelID)
        _selectedReasoningEffort = State(initialValue: activeSelection.reasoningEffort ?? "")
    }

    init(authenticationSession: ProviderAuthenticationSession) {
        let client = authenticationSession.client
        let selection = ModelSelection(providerID: client.id, modelID: client.models.first?.id ?? "", reasoningEffort: nil)
        title = "Model"
        activeSelection = selection
        scopeDescription = nil
        onClose = nil
        mode = .authentication(authenticationSession)
        _selectedRegion = State(initialValue: selection.region)
        _providerSelection = State(initialValue: .client(client.id))
        _selectedModelID = State(initialValue: selection.modelID)
        _selectedReasoningEffort = State(initialValue: "")
    }

    private var isAuthenticating: Bool {
        if case .authentication = mode { return true }
        return false
    }

    private var selectedClientID: String? {
        guard case .client(let clientID) = providerSelection else { return nil }
        return clientID
    }

    private var displayedClients: [any ProviderClient] {
        var list = registry.clients(in: selectedRegion)
        if !list.contains(where: { $0.id == activeSelection.providerID }),
           let active = registry.client(id: activeSelection.providerID, in: selectedRegion) {
            list.append(active)
        }
        return list
    }

    private var selectedClient: (any ProviderClient)? {
        if case .authentication(let session) = mode { return session.client }
        guard let selectedClientID else { return nil }
        return displayedClients.first { $0.id == selectedClientID }
    }

    private var selectedModel: ProviderModel? {
        guard var model = selectedClient?.models.first(where: { $0.id == selectedModelID }) else { return nil }
        model.reasoningEffort = selectedReasoningEffort
        return model
    }

    private var reasoningEfforts: [String] {
        selectedModel?.reasoningEfforts ?? []
    }

    private var isAuthenticated: Bool {
        guard let selectedClient else { return false }
        let hasKey = selectedClient.usesAPIKey
            && !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let signedIn = selectedClient.subscriptionAccount?.isSignedIn == true
        let needsAuthentication = selectedClient.usesAPIKey || selectedClient.subscriptionAccount != nil
        return !needsAuthentication || hasKey || signedIn
    }

    private var canSelect: Bool {
        switch providerSelection {
        case .client:
            selectedClient != nil && selectedModel != nil && isAuthenticated
        case .custom:
            !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && CustomLLMProviderDiscovery.normalizedBaseURL(customURL) != nil
                && customModels.contains { $0.id == customModelID }
                && !customModelsLoading
        }
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !isAuthenticating else { return }
                selectAvailableClient()
                if !reasoningEfforts.contains(selectedReasoningEffort) {
                    selectDefaultReasoningEffort()
                }
            }
            .onChange(of: authRevision) { _, _ in selectAvailableModel() }
            .task(id: "\(selectedClientID ?? "")#\(authRevision)") {
                guard let selectedClientID, isAuthenticated else { return }
                await registry.refreshModelsIfStale(id: selectedClientID)
            }
            .onChange(of: registry.customProviders) { _, _ in selectAvailableClient() }
            .toolbar {
                if case .authentication(let session) = mode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            session.complete(.cancelled)
                            dismiss()
                        }
                        .accessibilityIdentifier("provider.authentication.cancel")
                    }
                } else if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetDismissToolbarButton(accessibilityIdentifier: A11yID.ConversationControls.modelClose, action: onClose)
                    }
                }
            }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    if let scopeDescription {
                        Text(scopeDescription)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .settingsContentInset()
                    }
                    selectionGroup {
                        if !isAuthenticating {
                            regionMenu
                            Divider().settingsContentInset()
                        }
                        if case .authentication(let session) = mode {
                            selectionRow("Provider", session.client.displayName, indicator: nil)
                        } else {
                            providerMenu
                        }
                    }
                    .id("model-configuration-top")
                    if providerSelection == .custom && !isAuthenticating {
                        customConnectionSection
                        customAuthenticationSection
                        selectionGroup { customModelControl }
                    } else if let selectedClient {
                        authenticationSection(selectedClient)
                        if !isAuthenticating, isAuthenticated {
                            selectionGroup {
                                modelMenu
                                if !reasoningEfforts.isEmpty {
                                    Divider().settingsContentInset()
                                    reasoningEffortMenu
                                }
                            }
                        }
                    }
                }
                .settingsPagePadding()
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: selectedClientID) { _, _ in
                providerModelsError = nil
                proxy.scrollTo("model-configuration-top", anchor: .top)
            }
        }
        .background {
            Rectangle()
                .fill(Theme.Colors.background)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
        }
    }

    private var regionMenu: some View {
        Menu {
            Picker("Region", selection: Binding(
                get: { selectedRegion },
                set: { region in
                    selectedRegion = region
                    dismissKeyboard()
                    selectAvailableClient()
                    selectDefaultReasoningEffort()
                    applySelection()
                }
            )) {
                ForEach(LLMRegion.allCases, id: \.self) { region in
                    Text(region.displayName).tag(region)
                }
            }
        } label: {
            selectionRow("Region", selectedRegion.displayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Region")
        .accessibilityValue(selectedRegion.displayName)
        .accessibilityIdentifier(A11yID.ConversationControls.modelRegion)
    }

    private var providerMenu: some View {
        Button { choosingProvider = true } label: {
            selectionRow("Provider", providerSelection == .custom
                ? "Custom provider"
                : selectedClient?.displayName ?? "Choose a provider",
                indicator: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Provider")
        .accessibilityValue(providerSelection == .custom
            ? "Custom provider"
            : selectedClient?.displayName ?? "")
        .accessibilityIdentifier(A11yID.ConversationControls.modelProvider)
        .navigationDestination(isPresented: $choosingProvider) {
            ProviderPickerView(
                clients: displayedClients,
                selectedClientID: Binding(
                    get: { selectedClientID },
                    set: {
                        providerSelection = $0.map(ProviderSelection.client) ?? .custom
                        providerDidChange()
                        applySelection()
                    }
                ),
                onSelect: { choosingProvider = false }
            )
        }
    }

    private var modelMenu: some View {
        NavigationLink {
            SettingsSelectionPickerView(
                title: "Model",
                options: (selectedClient?.models ?? []).map { model in
                    SettingsSelectionOption(
                        id: model.id,
                        value: model.id,
                        title: model.displayName,
                        accessibilityIdentifier: A11yID.ConversationControls.modelOption(model.id)
                    )
                },
                selection: Binding(
                    get: { selectedModelID },
                    set: { modelID in
                        selectedModelID = modelID
                        selectDefaultReasoningEffort()
                        applySelection()
                    }
                ),
                searchAccessibilityIdentifier: A11yID.ConversationControls.modelSearch
            )
            .toolbar {
                if let selectedClient, registry.canDiscoverModels(id: selectedClient.id) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { loadProviderModels(selectedClient) } label: {
                            if providerModelsLoading {
                                CellularAutomatonLoader.small
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(providerModelsLoading)
                        .accessibilityLabel(providerModelsLoading ? "Loading models…" : "Load models")
                    }
                }
            }
            .alert("Load models", isPresented: Binding(
                get: { providerModelsError != nil },
                set: { if !$0 { providerModelsError = nil } }
            )) {
                Button("OK", role: .cancel) { providerModelsError = nil }
            } message: {
                Text(verbatim: providerModelsError ?? "")
            }
        } label: {
            selectionRow("Model", selectedModel?.displayName ?? "No models available", indicator: "chevron.right")
        }
        .buttonStyle(.plain)
        .disabled(selectedClient?.models.isEmpty != false)
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel?.displayName ?? "")
        .accessibilityIdentifier(A11yID.ConversationControls.modelSelection)
    }

    private var reasoningEffortMenu: some View {
        NavigationLink {
            SettingsSelectionPickerView(
                title: "Thinking level",
                options: reasoningEfforts.map { effort in
                    SettingsSelectionOption(
                        id: effort,
                        value: effort,
                        title: reasoningEffortName(effort),
                        accessibilityIdentifier: A11yID.ConversationControls.modelThinkingLevelOption(effort)
                    )
                },
                selection: Binding(
                    get: { selectedReasoningEffort },
                    set: { effort in
                        selectedReasoningEffort = effort
                        applySelection()
                    }
                )
            )
        } label: {
            selectionRow("Thinking level", reasoningEffortName(selectedReasoningEffort), indicator: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking level")
        .accessibilityValue(reasoningEffortName(selectedReasoningEffort))
        .accessibilityIdentifier(A11yID.ConversationControls.modelThinkingLevel)
    }

    private var customConnectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(spacing: 0) {
                TextField("Provider name", text: $customName)
                    .textInputAutocapitalization(.words)
                    .font(Theme.Fonts.bodyMd)
                    .settingsRowPadding()
                    .accessibilityIdentifier(A11yID.Settings.customProviderName)
                Divider().settingsContentInset()
                TextField("Server URL", text: $customURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Theme.Fonts.bodyMd)
                    .settingsRowPadding()
                    .accessibilityIdentifier(A11yID.Settings.customProviderURL)
            }
            .settingsSurface()
            Text("Addresses without a path use /v1.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsContentInset()
        }
    }

    private var customAuthenticationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Authentication")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
            if let customError {
                SettingsErrorMessage(message: customError, systemImage: "exclamationmark.circle.fill")
            }
            SecureField("API key (optional)", text: $customAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(Theme.Fonts.bodyMd)
                .settingsRowPadding()
                .settingsSurface(singleRow: true)
                .accessibilityIdentifier(A11yID.Settings.customProviderKey)
        }
    }

    @ViewBuilder
    private var customModelControl: some View {
        if customModels.isEmpty {
            Button { discoverCustomModels() } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if customModelsLoading {
                        CellularAutomatonLoader.small
                    }
                    Text(customModelsLoading ? "Loading models…" : "Load models")
                        .font(Theme.Fonts.bodyMd)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(customModelsCanLoad ? Theme.Colors.onSurface : Theme.Colors.onSurfaceMuted)
                .settingsRowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!customModelsCanLoad)
            .accessibilityIdentifier(A11yID.ConversationControls.modelSelection)
        } else {
            NavigationLink {
                SettingsSelectionPickerView(
                    title: "Model",
                    options: customModels.map { model in
                        SettingsSelectionOption(
                            id: model.id,
                            value: model.id,
                            title: model.displayName,
                            accessibilityIdentifier: A11yID.ConversationControls.modelOption(model.id)
                        )
                    },
                    selection: Binding(
                        get: { customModelID },
                        set: { modelID in
                            customModelID = modelID
                            applySelection()
                        }
                    )
                )
            } label: {
                selectionRow(
                    "Model",
                    customModels.first { $0.id == customModelID }?.displayName ?? "Choose a model",
                    indicator: "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model")
            .accessibilityValue(customModels.first { $0.id == customModelID }?.displayName ?? "")
            .accessibilityIdentifier(A11yID.ConversationControls.modelSelection)
        }

    }

    private var customModelsCanLoad: Bool {
        CustomLLMProviderDiscovery.normalizedBaseURL(customURL) != nil && !customModelsLoading
    }

    private func selectionGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .settingsSurface()
    }

    private func selectionRow(
        _ title: LocalizedStringKey,
        _ value: String,
        indicator: String? = "chevron.up.chevron.down"
    ) -> some View {
        SettingsDisclosureRow(title: title, value: Text(verbatim: value), indicator: indicator)
    }

    private func authenticationSection(_ client: any ProviderClient) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Authentication")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }

            ProviderAuthenticationView(
                client: client,
                apiKey: $apiKeyDraft,
                onChange: { authRevision &+= 1 },
                onAuthenticated: { authenticationDidComplete(for: client) }
            )
            .id(client.id)
            if let providerCredentialError {
                SettingsErrorMessage(message: providerCredentialError, systemImage: "exclamationmark.circle.fill")
            }
        }
    }

    private func selectAvailableClient() {
        guard !isAuthenticating else { return }
        let clients = registry.clients(in: selectedRegion)
        guard !clients.isEmpty else { return }
        if providerSelection == .custom { return }
        if let selectedClientID, registry.isCustomProviderPending(clientID: selectedClientID) { return }
        if !clients.contains(where: { $0.id == selectedClientID }) {
            providerSelection = .client(clients[0].id)
        }
        loadCredentialDraft()
        selectAvailableModel()
    }

    private func providerDidChange() {
        dismissKeyboard()
        customError = nil
        providerCredentialError = nil
        loadCredentialDraft()
        selectAvailableModel()
        selectDefaultReasoningEffort()
    }

    private func loadCredentialDraft() {
        let key = selectedClient.flatMap { Credentials.key(for: $0.credentialID) } ?? ""
        apiKeyDraft = key
    }

    private func selectAvailableModel() {
        guard let selectedClient else { return }
        if selectedClient.models.contains(where: { $0.id == selectedModelID }) { return }
        let preferredID = registry.selected(for: selectedClient.id, in: selectedRegion).id
        selectedModelID = selectedClient.models.first(where: { $0.id == preferredID })?.id
            ?? selectedClient.models.first?.id ?? ""
    }

    private func selectDefaultReasoningEffort() {
        guard let selectedClient, let selectedModel else {
            selectedReasoningEffort = ""
            return
        }
        selectedReasoningEffort = registry.reasoningEffort(
            for: selectedModel,
            in: selectedClient.id,
            region: selectedRegion
        ) ?? ""
    }

    private func reasoningEffortName(_ effort: String) -> String {
        switch effort {
        case "none": L10n.string("None")
        case "minimal": L10n.string("Minimal")
        case "low": L10n.string("Low")
        case "medium": L10n.string("Medium")
        case "high": L10n.string("High")
        case "xhigh": L10n.string("Extra high")
        case "max": L10n.string("Maximum")
        case "default": L10n.string("Provider default")
        default: effort.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func discoverCustomModels() {
        guard let baseURL = CustomLLMProviderDiscovery.normalizedBaseURL(customURL), customModelsCanLoad else { return }
        dismissKeyboard()
        customModelsLoading = true
        customError = nil
        let key = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let discovered = try await CustomLLMProviderDiscovery.models(
                    baseURL: baseURL,
                    apiKey: key.isEmpty ? nil : key
                )
                customModels = discovered
                customModelID = discovered[0].id
                customModelsLoading = false
                applySelection()
            } catch {
                customModelsLoading = false
                customError = error.localizedDescription
            }
        }
    }

    private func loadProviderModels(_ client: any ProviderClient) {
        guard registry.canDiscoverModels(id: client.id), !providerModelsLoading else { return }
        providerModelsLoading = true
        providerModelsError = nil
        Task {
            defer { providerModelsLoading = false }
            do {
                try await registry.refreshModels(id: client.id)
                if selectedClientID == client.id { selectAvailableModel() }
            } catch {
                if selectedClientID == client.id { providerModelsError = error.localizedDescription }
            }
        }
    }

    private func applySelection() {
        guard canSelect, case .selection(let onSelect) = mode else { return }
        dismissKeyboard()
        if providerSelection == .custom {
            selectCustomProvider(onSelect: onSelect)
            return
        }
        guard let selectedClient, let selectedModel else { return }
        if selectedClient.acceptsAPIKey {
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                do {
                    let definition = try registry.definition(id: selectedClient.id)
                    try Secret.saveProviderKey(key, definition: definition)
                } catch {
                    providerCredentialError = error.localizedDescription
                    return
                }
            }
        }
        do {
            let selected = try registry.resolveSelection(ModelSelection(
                providerID: selectedClient.id,
                modelID: selectedModel.id,
                reasoningEffort: selectedModel.selectedReasoningEffort
            ))
            Log.ui.info("ModelPicker.select client=\(selected.client.id) model=\(selected.model.id) reasoning=\(selected.model.selectedReasoningEffort ?? "unavailable") region=\(selectedRegion.rawValue)")
            onSelect(selected.client, selected.model, selected.selection)
            Haptics.selection(.modelSelected)
        } catch {
            providerCredentialError = error.localizedDescription
        }
    }

    private func selectCustomProvider(onSelect: (any ProviderClient, ProviderModel, ModelSelection) -> Void) {
        guard let baseURL = CustomLLMProviderDiscovery.normalizedBaseURL(customURL),
              let model = customModels.first(where: { $0.id == customModelID }) else { return }
        let provider = CustomLLMProvider(
            name: customName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL,
            models: customModels
        )
        registry.upsert(provider)
        let key = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                let definition = try registry.definition(id: provider.clientID)
                try Secret.saveProviderKey(key, definition: definition)
            } catch {
                customError = error.localizedDescription
                return
            }
        }
        do {
            let selected = try registry.resolveSelection(ModelSelection(
                providerID: provider.clientID,
                modelID: model.id,
                reasoningEffort: model.modelInfo.selectedReasoningEffort
            ))
            Log.ui.info("ModelPicker.select custom client=\(selected.client.id) model=\(selected.model.id)")
            onSelect(selected.client, selected.model, selected.selection)
        } catch {
            customError = error.localizedDescription
            return
        }
        providerSelection = .client(provider.clientID)
        selectedModelID = model.id
        loadCredentialDraft()
        selectDefaultReasoningEffort()
        Haptics.selection(.modelSelected)
    }

    private func authenticationDidComplete(for client: any ProviderClient) {
        if case .selection = mode {
            applySelection()
            return
        }
        guard case .authentication(let session) = mode else { return }
        let signedIn = client.subscriptionAccount?.isSignedIn == true
        session.complete(signedIn ? .authenticated : .credentialStored)
        dismiss()
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct ProviderPickerView: View {
    let clients: [any ProviderClient]
    @Binding var selectedClientID: String?
    let onSelect: () -> Void

    var body: some View {
        let directClients = clients.filter { $0.inferenceLocation == .onDevice }
            + clients.filter { $0.subscriptionAccount != nil && !$0.acceptsAPIKey }
        let directIDs = Set(directClients.map(\.id))
        let apiClients = clients.filter { !directIDs.contains($0.id) }
            .sorted { ($0.gettingStartedOffer?.priority ?? .max) < ($1.gettingStartedOffer?.priority ?? .max) }
        let visibleClients = directClients + apiClients.filter { $0.id == selectedClientID }
        let apiOption = SettingsSelectionOption<String?>(
            id: "api",
            value: nil,
            title: L10n.string("API provider"),
            systemImage: "plus",
            accessibilityIdentifier: A11yID.ConversationControls.modelAPIProviders,
            children: apiClients.map { providerOption($0, showsSubtitle: true) }
        )
        let customOption = SettingsSelectionOption<String?>(
            id: "custom",
            value: nil,
            title: L10n.string("Custom provider"),
            systemImage: "plus",
            accessibilityIdentifier: A11yID.ConversationControls.modelCustomProviders
        )

        SettingsSelectionPickerView(
            title: "Provider",
            options: visibleClients.map { providerOption($0) }
                + (apiClients.isEmpty ? [] : [apiOption]) + [customOption],
            selection: $selectedClientID,
            onSelect: {
                selectedClientID = $0
                onSelect()
            }
        )
    }

    private func providerOption(_ client: any ProviderClient, showsSubtitle: Bool = false) -> SettingsSelectionOption<String?> {
        SettingsSelectionOption(
            id: client.id,
            value: client.id,
            title: client.displayName,
            faviconDomain: client.website?.host,
            faviconURL: client.iconURL,
            subtitle: showsSubtitle ? subtitle(for: client) : nil,
            accessibilityIdentifier: A11yID.ConversationControls.modelProviderOption(client.id)
        )
    }

    private func subtitle(for client: any ProviderClient) -> String {
        if let offer = client.gettingStartedOffer { return offer.summary }
        if !client.acceptsAPIKey { return "Not required" }
        return client.credentialKind == .subscriptionKey ? "Subscription key" : "API key"
    }
}
