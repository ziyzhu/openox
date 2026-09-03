import SwiftUI
import UniformTypeIdentifiers

struct ModelPickerSheet: View {
    let chat: Chat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ModelPickerContent(
                title: "Model",
                activeSelection: chat.modelSelection,
                onClose: { dismiss() }
            ) { client, model, selection in
                Log.ui.info("ModelPicker.select chat=\(chat.id) client=\(client.id) model=\(model.id) region=\(selection.region.rawValue)")
                chat.switchModel(to: client, model: model, selection: selection)
            }
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serverManager
    @State private var showOnboarding = false
    @State private var confirmingAlwaysApprove = false
    @State private var creatingProfile = false
    @State private var openingProfile = false
    @State private var profileNameDraft = ""
    @State private var profileCreationErrorMessage: String?
    @State private var profileOpenErrorMessage: String?
    private var registry: ProviderRegistry { ProviderRegistry.shared }
    private var appLocale: AppLocale { AppLocale.shared }
    private var speechVoice: SpeechVoiceSettings { .shared }
    private var storage: StorageRoot { .shared }

    private var theme: ThemeManager { .shared }

    private var languageBinding: Binding<AppLocale.Language> {
        Binding(get: { appLocale.language }, set: { appLocale.language = $0 })
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { theme.theme }, set: { theme.theme = $0 })
    }

    private var alwaysApproveBinding: Binding<Bool> {
        Binding(get: { serverManager.autoApproveAll }, set: { enabled in
            if enabled {
                confirmingAlwaysApprove = true
            } else {
                serverManager.autoApproveAll = false
            }
        })
    }

    private var logsSummary: Text {
        let count = LogStore.shared.count
        return count == 0 ? Text("Empty") : Text(verbatim: "\(count)")
    }

    private var defaultModel: ProviderModel {
        registry.selected(for: registry.defaultClient)
    }

    private var defaultProviderName: String {
        registry.client(id: registry.defaultClient)?.displayName ?? registry.defaultClient
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        "Profiles",
                        footer: "Profiles hold chats, artifacts, character, and memory. Keep several, switch anytime, and store locally or sync with iCloud.",
                        insetContent: false
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(storage.profiles.enumerated()), id: \.element.id) { index, profile in
                                if index > 0 {
                                    Divider().settingsContentInset()
                                }
                                NavigationLink {
                                    ProfileSettingsView(profileID: profile.id)
                                } label: {
                                    profileRow(profile)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(
                                    profile.id == storage.activeId
                                        ? A11yID.Settings.activeProfile
                                        : A11yID.Settings.profileRow(profile.id.uuidString)
                                )
                                .accessibilityValue(
                                    profile.id == storage.activeId
                                        ? L10n.string("Selected")
                                        : ""
                                )
                            }

                            if !storage.profiles.isEmpty {
                                Divider().settingsContentInset()
                            }

                            Menu {
                                Button {
                                    profileNameDraft = ""
                                    creatingProfile = true
                                } label: {
                                    Label("Create New Profile", systemImage: "plus")
                                }
                                .accessibilityIdentifier(A11yID.Settings.profileCreate)

                                Button {
                                    openingProfile = true
                                } label: {
                                    Label("Open Existing Profile", systemImage: "folder")
                                }
                                .accessibilityIdentifier(A11yID.Settings.profileOpen)
                            } label: {
                                profileActionRow("Add Profile", systemImage: "plus")
                            }
                            .buttonStyle(.plain)
                            .disabled(storage.isBusy)
                            .accessibilityIdentifier(A11yID.Settings.profileAdd)
                        }
                    }

                    SettingsSection(
                        "Models",
                        insetContent: false
                    ) {
                        NavigationLink {
                            ModelPickerContent(
                                title: "Model",
                                activeSelection: registry.defaultModel
                            ) { client, model, selection in
                                Log.ui.info("Settings.defaultModel client=\(client.id) model=\(model.id) region=\(selection.region.rawValue)")
                                registry.select(model, in: client.id, region: selection.region)
                            }
                        } label: {
                            SettingsDisclosureRow(
                                title: "Model",
                                value: Text(verbatim: "\(defaultProviderName) · \(defaultModel.displayName)")
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.defaultModel)
                    }

                    SettingsSection(
                        "Permissions",
                        footer: "Give agents permission to use all available actions without asking in any chat. Mistakes may cause data loss or unwanted charges."
                    ) {
                        Toggle("Always approve", isOn: alwaysApproveBinding)
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                            .tint(Theme.Colors.primary)
                            .accessibilityIdentifier(A11yID.Settings.autoApproveAll)
                    }

                    SettingsSection("Language") {
                        Menu {
                            Picker(selection: languageBinding) {
                                ForEach(AppLocale.Language.allCases, id: \.self) { language in
                                    Text(language.displayName).tag(language)
                                }
                            } label: {
                                EmptyView()
                            }
                        } label: {
                            SettingsValueRow(
                                value: Text(verbatim: appLocale.language.displayName),
                                indicator: "chevron.up.chevron.down"
                            )
                        }
                        .accessibilityIdentifier(A11yID.Settings.language)
                    }

                    SettingsSection(
                        "Voice",
                        footer: "Used to read agent responses aloud. For higher quality, go to Settings › Accessibility › Read & Speak › Voices and download an Enhanced or Premium voice."
                    ) {
                        NavigationLink {
                            SpeechVoicePickerView()
                        } label: {
                            SettingsValueRow(
                                value: Text(verbatim: speechVoice.selectedVoiceName(for: appLocale.locale))
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.voice)
                    }

                    SettingsSection("Theme") {
                        Menu {
                            Picker(selection: themeBinding) {
                                ForEach(AppTheme.allCases) { theme in
                                    Text(theme.displayName).tag(theme)
                                }
                            } label: {
                                EmptyView()
                            }
                        } label: {
                            SettingsValueRow(
                                value: Text(theme.theme.displayName),
                                indicator: "chevron.up.chevron.down"
                            )
                        }
                        .accessibilityIdentifier(A11yID.Settings.theme)
                    }

                    SettingsSection("Features", insetContent: false) {
                        VStack(spacing: 0) {
                            NavigationLink {
                                SiriSetupView()
                            } label: {
                                SettingsDisclosureRow(title: "Siri", value: Text("Set Up"))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.siri)

                            Divider().settingsContentInset()

                            NavigationLink {
                                NotificationSetupView()
                            } label: {
                                SettingsDisclosureRow(title: "Notifications", value: Text("Set Up"))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.notifications)

                            Divider().settingsContentInset()

                            NavigationLink {
                                OxServerView()
                            } label: {
                                SettingsDisclosureRow(
                                    title: "Service Repositories",
                                    value: Text("\(serverManager.repositories.count(where: \.isEnabled)) enabled")
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.server)

                            Divider().settingsContentInset()

                            Button { showOnboarding = true } label: {
                                SettingsDisclosureRow(title: "Take the tour", value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.howItWorks)
                        }
                    }

                    SettingsSection("Community", insetContent: false) {
                        VStack(spacing: 0) {
                            Link(destination: OxLinks.discord) {
                                SettingsDisclosureRow(
                                    title: "Discord",
                                    value: Text("Join"),
                                    indicator: "arrow.up.right"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.discord)

                            Divider().settingsContentInset()

                            Link(destination: OxLinks.github) {
                                SettingsDisclosureRow(
                                    title: "GitHub",
                                    value: Text("Source"),
                                    indicator: "arrow.up.right"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.github)
                        }
                    }

                    SettingsSection(
                        "Developer",
                        footer: "Recent on-device activity for troubleshooting. Logs are held in memory and never leave your device.",
                        insetContent: false
                    ) {
                        VStack(spacing: 0) {
                            NavigationLink {
                                LogsView()
                            } label: {
                                SettingsDisclosureRow(title: "Logs", value: logsSummary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.logs)
                        }
                    }
                }
                .settingsPagePadding()
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { SheetCloseButton { dismiss() } }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
        .alert("Always approve all actions?", isPresented: $confirmingAlwaysApprove) {
            Button("Cancel", role: .cancel) {}
            Button("Always approve", role: .destructive) {
                serverManager.autoApproveAll = true
            }
            .accessibilityIdentifier(A11yID.Settings.autoApproveConfirm)
        } message: {
            Text("Agents can access signed-in data, send messages, delete data, and spend money without asking. Mistakes may cause permanent data loss or unwanted charges. This approves pending and future actions in all chats and profiles until turned off. System permissions and private-data consent still apply.")
        }
        .task {
            await storage.refreshAvailability()
        }
        .fileImporter(
            isPresented: $openingProfile,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                Task {
                    do {
                        _ = try await storage.openProfile(at: url)
                    } catch {
                        Log.ui.error("Settings.openProfile name=\(url.lastPathComponent) error=\(error.localizedDescription)")
                        profileOpenErrorMessage = error.localizedDescription
                    }
                }
            } catch {
                Log.ui.error("Settings.openProfile picker error=\(error.localizedDescription)")
                profileOpenErrorMessage = error.localizedDescription
            }
        }
        .alert("New Profile", isPresented: $creatingProfile) {
            TextField("Name", text: $profileNameDraft)
            Button("Cancel", role: .cancel) {}
            if storage.iCloudAvailable {
                Button("Create in iCloud") { createProfile(in: .iCloud) }.disabled(profileNameUnavailable)
                Button("Create on This Device") { createProfile(in: .local) }.disabled(profileNameUnavailable)
            } else {
                Button("Create") { createProfile(in: .local) }.disabled(profileNameUnavailable)
            }
        } message: {
            if profileNameTaken {
                Text("A Profile named “\(StorageRoot.cleanName(profileNameDraft))” already exists. Choose a different name.")
            } else if storage.iCloudAvailable {
                Text("iCloud syncs this Profile across your devices. On-device keeps it here only. You can move it either way later.")
            }
        }
        .alert("New Profile", isPresented: Binding(
            get: { profileCreationErrorMessage != nil },
            set: { if !$0 { profileCreationErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { profileCreationErrorMessage = nil }
        } message: {
            Text(profileCreationErrorMessage ?? "")
        }
        .alert("Open Profile", isPresented: Binding(
            get: { profileOpenErrorMessage != nil },
            set: { if !$0 { profileOpenErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { profileOpenErrorMessage = nil }
        } message: {
            Text(profileOpenErrorMessage ?? "")
        }
    }

    private var profileNameIsEmpty: Bool {
        profileNameDraft.allSatisfy(\.isWhitespace)
    }

    private var profileNameTaken: Bool {
        !profileNameIsEmpty && storage.nameTaken(profileNameDraft)
    }

    private var profileNameUnavailable: Bool { profileNameIsEmpty || profileNameTaken }

    private func profileActionRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 24)
            Text(title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }

    private func createProfile(in location: Profile.Location) {
        let name = profileNameDraft
        Task {
            do {
                try await storage.createProfile(name: name, location: location)
            } catch {
                Log.ui.error("Settings.createProfile name=\(StorageRoot.cleanName(name)) location=\(location.rawValue) error=\(error.localizedDescription)")
                profileCreationErrorMessage = error.localizedDescription
            }
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: profileIcon(profile.location))
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: profile.name)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(profileLocation(profile.location))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            Spacer(minLength: 0)
            if profile.id == storage.activeId {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }

    private func profileIcon(_ location: Profile.Location) -> String {
        switch location {
        case .local: "iphone"
        case .iCloud: "icloud"
        case .external: "folder"
        }
    }

    private func profileLocation(_ location: Profile.Location) -> LocalizedStringKey {
        switch location {
        case .local: "On this device"
        case .iCloud: "In iCloud"
        case .external: "Opened from Files"
        }
    }

}

struct SheetCloseButton: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            SheetDismissToolbarButton(action: action)
                .accessibilityIdentifier(A11yID.Settings.close)
        }
    }
}

struct ModelPickerContent: View {
    private enum ProviderSelection: Hashable {
        case client(String)
        case custom
    }

    let title: String
    let activeSelection: ModelSelection
    var onClose: (() -> Void)?
    let onSelect: (any ProviderClient, ProviderModel, ModelSelection) -> Void

    @Environment(\.dismiss) private var dismiss
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

    private var registry: ProviderRegistry { ProviderRegistry.shared }

    init(
        title: String,
        activeSelection: ModelSelection,
        onClose: (() -> Void)? = nil,
        onSelect: @escaping (any ProviderClient, ProviderModel, ModelSelection) -> Void
    ) {
        self.title = title
        self.activeSelection = activeSelection
        self.onClose = onClose
        self.onSelect = onSelect
        _selectedRegion = State(initialValue: activeSelection.region)
        _providerSelection = State(initialValue: .client(activeSelection.providerID))
        _selectedModelID = State(initialValue: activeSelection.modelID)
        _selectedReasoningEffort = State(initialValue: activeSelection.reasoningEffort ?? "")
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

    private var canSave: Bool {
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
                selectAvailableClient()
                if !reasoningEfforts.contains(selectedReasoningEffort) {
                    selectDefaultReasoningEffort()
                }
            }
            .onChange(of: selectedRegion) { _, _ in
                dismissKeyboard()
                selectAvailableClient()
            }
            .onChange(of: providerSelection) { _, _ in providerDidChange() }
            .onChange(of: selectedModelID) { _, _ in selectDefaultReasoningEffort() }
            .onChange(of: authRevision) { _, _ in selectAvailableModel() }
            .onChange(of: registry.customProviders) { _, _ in selectAvailableClient() }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetDismissToolbarButton(action: onClose)
                            .accessibilityIdentifier(A11yID.Chat.modelClose)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier(A11yID.Chat.modelSave)
                }
            }
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    selectionSection("Region") { regionMenu }
                        .id("model-configuration-top")
                    selectionSection("Provider") { providerMenu }
                    if providerSelection == .custom {
                        customConnectionSection
                        customAuthenticationSection
                        selectionSection("Model") { customModelControl }
                    } else if let selectedClient {
                        authenticationSection(selectedClient)
                        selectionSection("Model") { modelMenu }
                        if !reasoningEfforts.isEmpty {
                            selectionSection("Thinking level") { reasoningEffortMenu }
                        }
                    }
                }
                .settingsPagePadding()
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: selectedClientID) { _, _ in
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
            Picker("Region", selection: $selectedRegion) {
                ForEach(LLMRegion.allCases, id: \.self) { region in
                    Text(region.displayName).tag(region)
                }
            }
        } label: {
            selectionRow(selectedRegion.displayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Region")
        .accessibilityValue(selectedRegion.displayName)
        .accessibilityIdentifier(A11yID.Chat.modelRegion)
    }

    private var providerMenu: some View {
        NavigationLink {
            ProviderPickerView(
                clients: displayedClients,
                selectedClientID: Binding(
                    get: { selectedClientID },
                    set: { providerSelection = $0.map(ProviderSelection.client) ?? .custom }
                )
            )
        } label: {
            selectionRow(providerSelection == .custom
                ? "Custom provider"
                : selectedClient?.displayName ?? "Choose a provider",
                indicator: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Provider")
        .accessibilityValue(providerSelection == .custom
            ? "Custom provider"
            : selectedClient?.displayName ?? "")
        .accessibilityIdentifier(A11yID.Chat.modelProvider)
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
                        accessibilityIdentifier: A11yID.Chat.modelOption(model.id)
                    )
                },
                selection: $selectedModelID
            )
        } label: {
            selectionRow(selectedModel?.displayName ?? "No models available", indicator: "chevron.right")
        }
        .buttonStyle(.plain)
        .disabled(selectedClient?.models.isEmpty != false)
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel?.displayName ?? "")
        .accessibilityIdentifier(A11yID.Chat.modelSelection)
    }

    private var reasoningEffortMenu: some View {
        NavigationLink {
            SettingsSelectionPickerView(
                title: L10n.string("Thinking level"),
                options: reasoningEfforts.map { effort in
                    SettingsSelectionOption(
                        id: effort,
                        value: effort,
                        title: reasoningEffortName(effort),
                        accessibilityIdentifier: A11yID.Chat.modelThinkingLevelOption(effort)
                    )
                },
                selection: $selectedReasoningEffort
            )
        } label: {
            selectionRow(reasoningEffortName(selectedReasoningEffort), indicator: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking level")
        .accessibilityValue(reasoningEffortName(selectedReasoningEffort))
        .accessibilityIdentifier(A11yID.Chat.modelThinkingLevel)
    }

    private var customConnectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Connection")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
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
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(customModelsCanLoad ? Theme.Colors.onSurface : Theme.Colors.onSurfaceMuted)
                .settingsRowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!customModelsCanLoad)
            .accessibilityIdentifier(A11yID.Chat.modelSelection)
        } else {
            NavigationLink {
                SettingsSelectionPickerView(
                    title: "Model",
                    options: customModels.map { model in
                        SettingsSelectionOption(
                            id: model.id,
                            value: model.id,
                            title: model.displayName,
                            accessibilityIdentifier: A11yID.Chat.modelOption(model.id)
                        )
                    },
                    selection: $customModelID
                )
            } label: {
                selectionRow(
                    customModels.first { $0.id == customModelID }?.displayName ?? "Choose a model",
                    indicator: "chevron.right"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model")
            .accessibilityValue(customModels.first { $0.id == customModelID }?.displayName ?? "")
            .accessibilityIdentifier(A11yID.Chat.modelSelection)
        }

    }

    private var customModelsCanLoad: Bool {
        CustomLLMProviderDiscovery.normalizedBaseURL(customURL) != nil && !customModelsLoading
    }

    private func selectionSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { dismissKeyboard() }
            content()
                .settingsSurface(singleRow: true)
        }
    }

    private func selectionRow(_ value: String, indicator: String = "chevron.up.chevron.down") -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(verbatim: value)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: indicator)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
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
                onChange: { authRevision &+= 1 }
            )
            .id(client.id)
        }
    }

    private func selectAvailableClient() {
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
        selectedModelID = registry.selected(for: selectedClient.id, in: selectedRegion).id
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
            defer { customModelsLoading = false }
            do {
                let discovered = try await CustomLLMProviderDiscovery.models(
                    baseURL: baseURL,
                    apiKey: key.isEmpty ? nil : key
                )
                customModels = discovered
                customModelID = discovered[0].id
            } catch {
                customError = error.localizedDescription
            }
        }
    }

    private func save() {
        guard canSave else { return }
        dismissKeyboard()
        if providerSelection == .custom {
            saveCustomProvider()
            return
        }
        guard let selectedClient, let selectedModel else { return }
        if selectedClient.acceptsAPIKey {
            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Credentials.set(key, for: selectedClient.credentialID) }
        }
        Log.ui.info("ModelPicker.save client=\(selectedClient.id) model=\(selectedModel.id) reasoning=\(selectedModel.selectedReasoningEffort ?? "unavailable") region=\(selectedRegion.rawValue)")
        onSelect(
            selectedClient,
            selectedModel,
            ModelSelection(
                region: selectedRegion,
                providerID: selectedClient.id,
                modelID: selectedModel.id,
                reasoningEffort: selectedModel.selectedReasoningEffort
            )
        )
        finishSaving()
    }

    private func saveCustomProvider() {
        guard let baseURL = CustomLLMProviderDiscovery.normalizedBaseURL(customURL),
              let model = customModels.first(where: { $0.id == customModelID }) else { return }
        let provider = CustomLLMProvider(
            name: customName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL,
            models: customModels
        )
        registry.upsert(provider)
        let key = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Credentials.set(key, for: provider.clientID) }
        Log.ui.info("ModelPicker.save custom client=\(provider.clientID) model=\(model.id)")
        onSelect(
            provider.client,
            model.modelInfo,
            ModelSelection(
                region: selectedRegion,
                providerID: provider.clientID,
                modelID: model.id,
                reasoningEffort: model.modelInfo.selectedReasoningEffort
            )
        )
        finishSaving()
    }

    private func finishSaving() {
        Haptics.success(.settingsSaved)
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct ProviderPickerView: View {
    let clients: [any ProviderClient]
    @Binding var selectedClientID: String?

    var body: some View {
        let featuredClients = clients
            .filter { $0.gettingStartedOffer != nil }
            .sorted {
                ($0.gettingStartedOffer?.priority ?? .max) < ($1.gettingStartedOffer?.priority ?? .max)
            }
        let featuredIDs = Set(featuredClients.map(\.id))
        let customOption = SettingsSelectionOption<String?>(
            id: "custom",
            value: nil,
            title: "Custom provider",
            systemImage: "plus",
            accessibilityIdentifier: A11yID.Chat.modelCustomProviders
        )
        let providerOption = { (client: any ProviderClient) in
            SettingsSelectionOption<String?>(
                id: client.id,
                value: client.id,
                title: client.displayName,
                subtitle: client.gettingStartedOffer?.summary,
                accessibilityIdentifier: A11yID.Chat.modelProviderOption(client.id)
            )
        }
        let showsFeatured = !featuredClients.isEmpty
        let options = showsFeatured
            ? featuredClients.map(providerOption)
                + [customOption]
                + clients.filter { !featuredIDs.contains($0.id) }.map(providerOption)
            : [customOption] + clients.map(providerOption)

        SettingsSelectionPickerView(
            title: "Provider",
            options: options,
            selection: $selectedClientID,
            separatesFirstOption: !showsFeatured,
            promotedOptionCount: showsFeatured ? featuredClients.count : 0,
            promotedTitle: "Free options",
            remainingTitle: "More providers"
        )
    }
}

private struct SettingsSelectionOption<Value: Hashable>: Identifiable {
    let id: String
    let value: Value
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    let accessibilityIdentifier: String
}

private struct SettingsSelectionPickerView<Value: Hashable>: View {
    let title: String
    let options: [SettingsSelectionOption<Value>]
    @Binding var selection: Value
    var separatesFirstOption = false
    var promotedOptionCount = 0
    var promotedTitle: LocalizedStringKey?
    var remainingTitle: LocalizedStringKey?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                if promotedOptionCount > 0, promotedOptionCount < options.count {
                    titledOptionGroup(promotedTitle, Array(options.prefix(promotedOptionCount)))
                    titledOptionGroup(remainingTitle, Array(options.dropFirst(promotedOptionCount)))
                } else if separatesFirstOption, let first = options.first {
                    optionRow(first, horizontalInset: SettingsLayout.rowVerticalInset)
                        .settingsSurface(singleRow: true)
                    optionGroup(Array(options.dropFirst()))
                } else {
                    optionGroup(options)
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionGroup(_ options: [SettingsSelectionOption<Value>]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { Divider().settingsContentInset() }
                optionRow(option)
            }
        }
        .settingsSurface()
    }

    private func titledOptionGroup(
        _ title: LocalizedStringKey?,
        _ options: [SettingsSelectionOption<Value>]
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsSectionHeaderInset()
            }
            optionGroup(options)
        }
    }

    private func optionRow(
        _ option: SettingsSelectionOption<Value>,
        horizontalInset: CGFloat = SettingsLayout.horizontalInset
    ) -> some View {
        Button {
            selection = option.value
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Theme.Colors.primary)
                        .frame(width: 24, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.title)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    if let subtitle = option.subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                }
                Spacer(minLength: 0)
                if selection == option.value {
                    Image(systemName: "checkmark")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Theme.Colors.primary)
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, SettingsLayout.rowVerticalInset)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(option.accessibilityIdentifier)
        .accessibilityValue(selection == option.value ? L10n.string("Selected") : "")
    }
}
