import SwiftUI
import UniformTypeIdentifiers

struct SettingsSheet: View {
    let ready: Bool
    let onSelectService: (Service) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serviceManager
    @State private var profilePath: [UUID]
    @State private var pendingSkillDraft: SkillDraft?
    @State private var showOnboarding = false
    @State private var creatingProfile = false
    @State private var openingProfile = false
    @State private var locatingProfileID: UUID?
    @State private var profileOpenErrorMessage: String?
    private var registry: ProviderRegistry { ProviderRegistry.shared }
    private var appLocale: AppLocale { AppLocale.shared }
    private var storage: StorageRoot { .shared }

    private var theme: ThemeManager { .shared }

    init(
        initialProfileID: UUID?,
        initialSkillDraft: SkillDraft?,
        ready: Bool,
        onSelectService: @escaping (Service) -> Void
    ) {
        self.ready = ready
        self.onSelectService = onSelectService
        _profilePath = State(initialValue: initialProfileID.map { [$0] } ?? [])
        _pendingSkillDraft = State(initialValue: initialSkillDraft)
    }

    private var languageBinding: Binding<AppLocale.Language> {
        Binding(get: { appLocale.language }, set: { appLocale.language = $0 })
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(get: { theme.theme == .dark ? .dark : .light }, set: { theme.theme = $0 })
    }

    private var defaultModelValue: Text {
        guard let selection = registry.defaultModel else { return Text("Not configured") }
        let client = registry.client(for: selection)
        let model = registry.model(for: selection, client: client)
        return Text(verbatim: model.displayName)
    }

    var body: some View {
        NavigationStack(path: $profilePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        "Profiles",
                        footer: "Profiles hold conversations, files, voice, and memory. Export a backup to keep a copy outside this device.",
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

                            ForEach(storage.unavailableProfiles, id: \.id) { missing in
                                Button {
                                    locatingProfileID = missing.id
                                    openingProfile = true
                                } label: {
                                    HStack {
                                        Text(verbatim: missing.name ?? String(localized: "Profile"))
                                        Spacer()
                                        Text("Locate folder…")
                                    }.settingsRowPadding()
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("settings.profileLocate.\(missing.id)")
                            }

                            if !storage.profiles.isEmpty {
                                Divider().settingsContentInset()
                            }

                            Menu {
                                Button {
                                    creatingProfile = true
                                } label: {
                                    Label("Create new", systemImage: "plus")
                                }
                                .accessibilityIdentifier(A11yID.Settings.profileCreate)

                                Button {
                                    locatingProfileID = nil
                                    openingProfile = true
                                } label: {
                                    Label("Open existing", systemImage: "folder")
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
                        footer: "Used for new conversations. Existing conversations keep their model.",
                        layout: .group
                    ) {
                        NavigationLink {
                            ModelPickerContent(
                                title: "Default model",
                                activeSelection: registry.sessionModel,
                                scopeDescription: "Changes apply immediately to new conversations. Existing conversations keep their model."
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

                    HostSettingsSection()

                    SettingsSection(layout: .group) {
                        VStack(spacing: 0) {
                            Menu {
                                Picker(selection: languageBinding) {
                                    ForEach(AppLocale.Language.allCases, id: \.self) { language in
                                        Text(language.displayName).tag(language)
                                    }
                                } label: {
                                    EmptyView()
                                }
                            } label: {
                                SettingsDisclosureRow(
                                    title: "Language",
                                    value: Text(verbatim: appLocale.language.displayName),
                                    indicator: "chevron.up.chevron.down"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.language)

                            Divider().settingsContentInset()

                            Menu {
                                Picker(selection: themeBinding) {
                                    ForEach(AppTheme.allCases) { theme in
                                        Text(theme.displayName).tag(theme)
                                    }
                                } label: {
                                    EmptyView()
                                }
                            } label: {
                                SettingsDisclosureRow(
                                    title: "Theme",
                                    value: Text(theme.theme.displayName),
                                    indicator: "chevron.up.chevron.down"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.theme)

                            Divider().settingsContentInset()

                            NavigationLink {
                                NotificationSetupView()
                            } label: {
                                SettingsDisclosureRow(title: "Notifications", value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.notifications)
                        }
                    }

                    SettingsSection(layout: .group) {
                        VStack(spacing: 0) {
                            Button { showOnboarding = true } label: {
                                SettingsDisclosureRow(title: "Take the tour", value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.howItWorks)

                            Divider().settingsContentInset()

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
                    initialSkillDraft: pendingSkillDraft
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = storage.migrationProgress {
                ProfileMigrationProgressView(stage: progress,
                                             automationID: "settings.profileMigration")
                    .frame(maxWidth: .infinity)
                    .background(Theme.Colors.background)
            }
        }
        .interactiveDismissDisabled(storage.migrationProgress != nil)
        .onChange(of: profilePath) { _, path in
            if path.isEmpty { pendingSkillDraft = nil }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
        }
        .task(id: profilePath.isEmpty) {
            guard profilePath.isEmpty else { return }
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
                        _ = try await storage.openProfile(at: url, expectedID: locatingProfileID)
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
        .sheet(isPresented: $creatingProfile) {
            ProfileCreationSheet()
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

    private var capabilitiesSettingsSection: some View {
        SettingsSection(layout: .group) {
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
                        primaryAction: .startConversation,
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
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 24)
            Text(title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }

    private func profileRow(_ profile: Profile) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: profileIcon(profile.location))
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Theme.Colors.conversationSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: profile.name)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(profileLocation(profile.location))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
            }
            Spacer(minLength: 0)
            if profile.id == storage.activeId {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
            Image(systemName: "chevron.right")
                .font(Theme.Icons.xs)
                .foregroundStyle(Theme.Colors.conversationSecondary)
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
            SheetDismissToolbarButton(accessibilityIdentifier: A11yID.Settings.close, action: action)
        }
    }
}
