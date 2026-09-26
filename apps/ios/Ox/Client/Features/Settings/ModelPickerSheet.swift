import SwiftUI
import UniformTypeIdentifiers

struct ModelPickerSheet: View {
    let chat: Chat
    @Environment(\.dismiss) private var dismiss
    private var registry: ProviderRegistry { .shared }
    private var isChoosingInitialDefault: Bool { registry.defaultModel == nil }

    var body: some View {
        NavigationStack {
            ModelPickerContent(
                title: isChoosingInitialDefault ? "Choose default model" : "Model for this chat",
                activeSelection: chat.modelSelection,
                scopeDescription: isChoosingInitialDefault
                    ? "Your choice will be used for this chat and future chats."
                    : "Changes apply immediately and stay with this chat.",
                onClose: { dismiss() }
            ) { client, model, selection in
                Log.ui.info("ModelPicker.select chat=\(chat.id) client=\(client.id) model=\(model.id) region=\(selection.region.rawValue)")
                if registry.defaultModel == nil {
                    registry.select(model, in: client.id, region: selection.region)
                }
                chat.switchModel(to: client, model: model, selection: selection)
            }
        }
    }
}

struct SettingsSheet: View {
    let ready: Bool
    let artifactRefreshEpoch: Int
    let onRenameArtifact: (Artifact, String, ProfileScope) async throws -> Artifact
    let onDeleteArtifact: (Artifact, ProfileScope) async throws -> Void
    let onSelectService: (Service) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serviceManager
    @State private var profilePath: [UUID]
    @State private var pendingSkillDraft: SkillDraft?
    @State private var showOnboarding = false
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

    init(
        initialProfileID: UUID?,
        initialSkillDraft: SkillDraft?,
        ready: Bool,
        artifactRefreshEpoch: Int,
        onRenameArtifact: @escaping (Artifact, String, ProfileScope) async throws -> Artifact,
        onDeleteArtifact: @escaping (Artifact, ProfileScope) async throws -> Void,
        onSelectService: @escaping (Service) -> Void
    ) {
        self.ready = ready
        self.artifactRefreshEpoch = artifactRefreshEpoch
        self.onRenameArtifact = onRenameArtifact
        self.onDeleteArtifact = onDeleteArtifact
        self.onSelectService = onSelectService
        _profilePath = State(initialValue: initialProfileID.map { [$0] } ?? [])
        _pendingSkillDraft = State(initialValue: initialSkillDraft)
    }

    private var languageBinding: Binding<AppLocale.Language> {
        Binding(get: { appLocale.language }, set: { appLocale.language = $0 })
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { theme.theme }, set: { theme.theme = $0 })
    }

    private var logsSummary: Text {
        let count = LogStore.shared.count
        return count == 0 ? Text("Empty") : Text(verbatim: "\(count)")
    }

    private var defaultModelValue: Text {
        guard let selection = registry.defaultModel else { return Text("Not configured") }
        let client = registry.client(for: selection)
        let model = registry.model(for: selection, client: client)
        return Text(verbatim: "\(client.displayName) · \(model.displayName)")
    }

    var body: some View {
        NavigationStack(path: $profilePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        "Profiles",
                        footer: "Profiles hold chats, artifacts, character, and memory. Keep several, switch anytime, and store locally or sync with iCloud.",
                        layout: .group
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(storage.profiles.enumerated()), id: \.element.id) { index, profile in
                                if index > 0 {
                                    Divider().settingsContentInset()
                                }
                                NavigationLink(value: profile.id) {
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
                        footer: "Used for new chats. Existing chats keep their model.",
                        layout: .group
                    ) {
                        NavigationLink {
                            ModelPickerContent(
                                title: "Default model",
                                activeSelection: registry.sessionModel,
                                scopeDescription: "Changes apply immediately to new chats. Existing chats keep their model."
                            ) { client, model, selection in
                                Log.ui.info("Settings.defaultModel client=\(client.id) model=\(model.id) region=\(selection.region.rawValue)")
                                registry.select(model, in: client.id, region: selection.region)
                            }
                        } label: {
                            SettingsDisclosureRow(
                                title: "Default model",
                                value: defaultModelValue
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.defaultModel)
                    }

                    capabilitiesSettingsSection

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

                    SettingsSection("App", layout: .group) {
                        VStack(spacing: 0) {
                            NavigationLink {
                                NotificationSetupView()
                            } label: {
                                SettingsDisclosureRow(title: "Notifications", value: Text("Set Up"))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.notifications)

                            Divider().settingsContentInset()

                            Button { showOnboarding = true } label: {
                                SettingsDisclosureRow(title: "Take the tour", value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.howItWorks)
                        }
                    }

                    SettingsSection("Community", layout: .group) {
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
                        layout: .group
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
            .navigationDestination(for: UUID.self) { profileID in
                ProfileSettingsView(
                    profileID: profileID,
                    initialSkillDraft: pendingSkillDraft,
                    artifactRefreshEpoch: artifactRefreshEpoch,
                    onRenameArtifact: onRenameArtifact,
                    onDeleteArtifact: onDeleteArtifact
                )
            }
        }
        .onChange(of: profilePath) { _, path in
            if path.isEmpty { pendingSkillDraft = nil }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
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

    private var capabilitiesSettingsSection: some View {
        SettingsSection("Capabilities", layout: .group) {
            VStack(spacing: 0) {
                NavigationLink {
                    ActionSettingsView()
                } label: {
                    SettingsDisclosureRow(
                        title: "Permissions",
                        value: Text(serviceManager.defaultActionPolicy?.title ?? "Default")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.actions)

                Divider().settingsContentInset()

                NavigationLink {
                    ServiceExploreContent(
                        onClose: nil,
                        ready: ready,
                        primaryAction: .startChat,
                        browserSessionID: nil,
                        isAttached: { _ in false },
                        onSelect: onSelectService
                    )
                } label: {
                    SettingsDisclosureRow(
                        title: "Services",
                        value: Text(verbatim: "\(serviceManager.services.count)")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.services)

                Divider().settingsContentInset()

                NavigationLink {
                    RepositoriesView()
                } label: {
                    SettingsDisclosureRow(
                        title: "Repositories",
                        value: Text("\(serviceManager.repositories.count(where: \.isEnabled)) enabled")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.server)

                Divider().settingsContentInset()

                NavigationLink {
                    SecretSettingsView()
                } label: {
                    SettingsDisclosureRow(title: "Secrets", value: Text(""))
                }
                .buttonStyle(.plain)
            }
        }
    }

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
                .font(Theme.Icons.xs)
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
                        SheetDismissToolbarButton(action: onClose)
                            .accessibilityIdentifier(A11yID.Chat.modelClose)
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
                    if !isAuthenticating {
                        selectionSection("Region") { regionMenu }
                            .id("model-configuration-top")
                    }
                    selectionSection("Provider") {
                        if case .authentication(let session) = mode {
                            selectionRow(session.client.displayName, indicator: nil)
                        } else {
                            providerMenu
                        }
                    }
                    if providerSelection == .custom && !isAuthenticating {
                        customConnectionSection
                        customAuthenticationSection
                        selectionSection("Model") { customModelControl }
                    } else if let selectedClient {
                        authenticationSection(selectedClient)
                        if !isAuthenticating {
                            selectionSection("Model") {
                                VStack(spacing: Theme.Spacing.sm) {
                                    modelMenu
                                    if selectedClient.canLoadModels {
                                        Button { loadProviderModels(selectedClient) } label: {
                                            HStack(spacing: Theme.Spacing.sm) {
                                                if providerModelsLoading { CellularAutomatonLoader.small }
                                                Text(providerModelsLoading ? "Loading models…" : "Load models")
                                                    .font(Theme.Fonts.bodyMd)
                                                Spacer(minLength: 0)
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .foregroundStyle(Theme.Colors.onSurface)
                                            .settingsRowPadding()
                                            .settingsSurface(singleRow: true)
                                        }
                                        .disabled(providerModelsLoading)
                                    }
                                    if let providerModelsError {
                                        SettingsErrorMessage(message: providerModelsError, systemImage: "exclamationmark.circle.fill")
                                    }
                                }
                            }
                            if !reasoningEfforts.isEmpty {
                                selectionSection("Thinking level") { reasoningEffortMenu }
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
            selectionRow(selectedRegion.displayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Region")
        .accessibilityValue(selectedRegion.displayName)
        .accessibilityIdentifier(A11yID.Chat.modelRegion)
    }

    private var providerMenu: some View {
        Button { choosingProvider = true } label: {
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
                        accessibilityIdentifier: A11yID.Chat.modelOption(model.id)
                    )
                },
                selection: Binding(
                    get: { selectedModelID },
                    set: { modelID in
                        selectedModelID = modelID
                        selectDefaultReasoningEffort()
                        applySelection()
                    }
                )
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
                title: "Thinking level",
                options: reasoningEfforts.map { effort in
                    SettingsSelectionOption(
                        id: effort,
                        value: effort,
                        title: reasoningEffortName(effort),
                        accessibilityIdentifier: A11yID.Chat.modelThinkingLevelOption(effort)
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
                        .font(.caption.weight(.semibold))
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

    private func selectionRow(_ value: String, indicator: String? = "chevron.up.chevron.down") -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(verbatim: value)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let indicator {
                Image(systemName: indicator)
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
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
        guard client.canLoadModels, !providerModelsLoading else { return }
        providerModelsLoading = true
        providerModelsError = nil
        Task {
            defer { providerModelsLoading = false }
            do {
                let models = try await client.loadModels()
                try registry.updateDiscoveredModels(models, for: client.id)
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
        Log.ui.info("ModelPicker.select client=\(selectedClient.id) model=\(selectedModel.id) reasoning=\(selectedModel.selectedReasoningEffort ?? "unavailable") region=\(selectedRegion.rawValue)")
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
        Haptics.success(.settingsSaved)
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
        Log.ui.info("ModelPicker.select custom client=\(provider.clientID) model=\(model.id)")
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
        providerSelection = .client(provider.clientID)
        selectedModelID = model.id
        loadCredentialDraft()
        selectDefaultReasoningEffort()
        Haptics.success(.settingsSaved)
    }

    private func authenticationDidComplete(for client: any ProviderClient) {
        if case .selection = mode {
            applySelection()
            return
        }
        guard case .authentication(let session) = mode else { return }
        let website = client.models.first.flatMap { client.wireProtocol(for: $0) } == .web
        let signedIn = client.subscriptionAccount?.isSignedIn == true || website
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
        let directClients = clients.filter { $0.subscriptionAccount != nil && !$0.acceptsAPIKey && !isWebsite($0) }
            + clients.filter(isWebsite)
        let directIDs = Set(directClients.map(\.id))
        let apiClients = clients.filter { !directIDs.contains($0.id) }
            .sorted { ($0.gettingStartedOffer?.priority ?? .max) < ($1.gettingStartedOffer?.priority ?? .max) }
        let visibleClients = directClients + apiClients.filter { $0.id == selectedClientID }
        let apiOption = SettingsSelectionOption<String?>(
            id: "api",
            value: nil,
            title: L10n.string("API provider"),
            systemImage: "plus",
            accessibilityIdentifier: A11yID.Chat.modelAPIProviders,
            children: apiClients.map { providerOption($0, showsSubtitle: true) }
        )
        let customOption = SettingsSelectionOption<String?>(
            id: "custom",
            value: nil,
            title: L10n.string("Custom provider"),
            systemImage: "plus",
            accessibilityIdentifier: A11yID.Chat.modelCustomProviders
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

    private func isWebsite(_ client: any ProviderClient) -> Bool {
        client.models.first.flatMap { client.wireProtocol(for: $0) } == .web
    }

    private func providerOption(_ client: any ProviderClient, showsSubtitle: Bool = false) -> SettingsSelectionOption<String?> {
        SettingsSelectionOption(
            id: client.id,
            value: client.id,
            title: client.displayName,
            faviconDomain: client.website?.host,
            faviconURL: ProviderIcon.url(id: client.id, website: client.website),
            serviceDomain: (client as? WebServiceModelProvider)?.domain,
            subtitle: showsSubtitle ? subtitle(for: client) : nil,
            accessibilityIdentifier: A11yID.Chat.modelProviderOption(client.id)
        )
    }

    private func subtitle(for client: any ProviderClient) -> String {
        if let offer = client.gettingStartedOffer { return offer.summary }
        if !client.acceptsAPIKey { return "Not required" }
        return client.credentialKind == .subscriptionKey ? "Subscription key" : "API key"
    }
}

private struct SettingsSelectionOption<Value: Hashable>: Identifiable {
    let id: String
    let value: Value
    let title: String
    var systemImage: String? = nil
    var faviconDomain: String? = nil
    var faviconURL: URL? = nil
    var serviceDomain: String? = nil
    var subtitle: String? = nil
    let accessibilityIdentifier: String
    var children: [SettingsSelectionOption<Value>] = []
}

private struct SettingsSelectionPickerView<Value: Hashable>: View {
    let title: LocalizedStringKey
    let options: [SettingsSelectionOption<Value>]
    @Binding var selection: Value
    var onSelect: ((Value) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serviceManager

    var body: some View {
        ScrollView {
            optionGroup(options)
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

    private func select(_ value: Value) {
        if let onSelect {
            onSelect(value)
        } else {
            selection = value
            dismiss()
        }
    }

    @ViewBuilder
    private func optionRow(_ option: SettingsSelectionOption<Value>) -> some View {
        if option.children.isEmpty {
            Button { select(option.value) } label: {
                optionLabel(option)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(option.accessibilityIdentifier)
            .accessibilityValue(selection == option.value ? L10n.string("Selected") : "")
        } else {
            NavigationLink {
                SettingsSelectionPickerView(
                    title: LocalizedStringKey(option.title),
                    options: option.children,
                    selection: $selection,
                    onSelect: select
                )
            } label: {
                optionLabel(option)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(option.accessibilityIdentifier)
        }
    }

    private func optionLabel(_ option: SettingsSelectionOption<Value>) -> some View {
        HStack(spacing: SettingsLayout.horizontalInset) {
            if let domain = option.serviceDomain, let service = serviceManager.service(domain: domain) {
                ServiceAvatar(service: service, size: 24, shape: .roundedRect(3))
            } else if let faviconDomain = option.faviconDomain {
                DomainFavicon(domain: faviconDomain, size: 24, overrideURL: option.faviconURL)
            }
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
            if !option.children.isEmpty {
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            } else if selection == option.value {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
        }
        .padding(.horizontal, SettingsLayout.horizontalInset)
        .padding(.vertical, SettingsLayout.rowVerticalInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
