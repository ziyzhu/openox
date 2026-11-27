import SwiftUI
import UniformTypeIdentifiers

struct SettingsSheet: View {
    let ready: Bool
    let onSelectService: (Service) -> Void

    @AppStorage(Theme.Appearance.storageKey) private var appearance = Theme.Appearance.system
    @Environment(\.dismiss) private var dismiss
    @State private var profilePath: [UUID]
    @State private var pendingSkillDraft: SkillDraft?
    @State private var showOnboarding = false
    @State private var creatingProfile = false
    @State private var openingProfile = false
    @State private var speechLocales: [Locale] = []
    @AppStorage(SpeechLanguage.storageKey) private var speechLanguage = ""
    @State private var locatingProfileID: UUID?
    @State private var profileOpenErrorMessage: String?
    @State private var profileAgentNames: [UUID: String?] = [:]
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    private let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private var appLocale: AppLocale { AppLocale.shared }
    private var storage: StorageRoot { .shared }

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

    private func speechLanguageName(_ identifier: String) -> String {
        appLocale.locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    private var speechLanguageValue: Text {
        speechLanguage.isEmpty ? Text("App language") : Text(verbatim: speechLanguageName(speechLanguage))
    }

    var body: some View {
        NavigationStack(path: $profilePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        "Profiles",
                        footer: "Profiles hold conversations, files, and memory. Export a backup to keep a copy outside this device.",
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
                                        Text("Locate Folder…")
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
                                    Label("Create New", systemImage: "plus")
                                }
                                .accessibilityIdentifier(A11yID.Settings.profileCreate)

                                Button {
                                    locatingProfileID = nil
                                    openingProfile = true
                                } label: {
                                    Label("Open Existing", systemImage: "folder")
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
                                Picker(selection: $speechLanguage) {
                                    Text("App language").tag("")
                                    ForEach(speechLocales, id: \.identifier) { locale in
                                        Text(verbatim: speechLanguageName(locale.identifier(.bcp47)))
                                            .tag(locale.identifier(.bcp47))
                                    }
                                } label: {
                                    EmptyView()
                                }
                            } label: {
                                SettingsDisclosureRow(
                                    title: "Voice input",
                                    value: speechLanguageValue,
                                    indicator: "chevron.up.chevron.down"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.speechLanguage)
                            .task {
                                let names = await SpeechLanguage.supported()
                                speechLocales = names.sorted {
                                    speechLanguageName($0.identifier(.bcp47)) < speechLanguageName($1.identifier(.bcp47))
                                }
                            }

                            Divider().settingsContentInset()

                            Menu {
                                Picker("Appearance", selection: $appearance) {
                                    ForEach(Theme.Appearance.allCases, id: \.self) { option in
                                        Text(option.title)
                                            .tag(option)
                                            .accessibilityIdentifier("settings.appearance.\(option.rawValue)")
                                    }
                                }
                            } label: {
                                SettingsDisclosureRow(
                                    title: "Appearance",
                                    value: Text(appearance.title),
                                    indicator: "chevron.up.chevron.down"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.appearance")

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
                            NavigationLink {
                                WhatsNewListView()
                            } label: {
                                SettingsDisclosureRow(title: "What's New", value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.whatsNew)

                            Divider().settingsContentInset()

                            Button { showOnboarding = true } label: {
                                SettingsDisclosureRow(title: "Take the tour", value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(A11yID.Settings.howItWorks)

                            Divider().settingsContentInset()

                            Link(destination: OxLinks.discord) {
                                SettingsDisclosureRow(
                                    title: "Support / Community",
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

                    VStack(spacing: Theme.Spacing.sm) {
                        Text(verbatim: "Ox")
                            .font(Theme.Fonts.bodyMd)
                        Text("Version \(appVersion) (\(appBuild))")
                            .font(Theme.Fonts.caption)
                    }
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.appVersion")
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
                    ready: ready,
                    onSelectService: onSelectService
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
            var names: [UUID: String?] = [:]
            for profile in storage.profiles {
                names[profile.id] = await RemoteAgentConfiguration.defaultAgentName(in: ProfileScope(profileID: profile.id, root: profile.url, location: profile.location))
            }
            profileAgentNames = names
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
        .errorAlert("Open Profile", message: $profileOpenErrorMessage)
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
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 24)
                .accessibilityLabel(Text(verbatim: profileLocation(profile.location)))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: profile.name)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(verbatim: agentName(profile))
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

    private func profileLocation(_ location: Profile.Location) -> String {
        switch location {
        case .local: L10n.string("On this device")
        case .iCloud: L10n.string("In iCloud")
        case .external: L10n.string("Opened from Files")
        }
    }

    private func agentName(_ profile: Profile) -> String {
        let directory = RemoteAgentDirectory.shared
        let name = profile.id == storage.activeId
            ? directory.defaultEndpoint.map(directory.displayName(for:))
            : profileAgentNames[profile.id] ?? nil
        return name ?? Device.localAgentName
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

struct ProfileCapabilitiesSection: View {
    let ready: Bool
    let onSelectService: (Service) -> Void
    @Environment(ServiceManager.self) private var serviceManager

    var body: some View {
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
                    .animation(Theme.Animation.standard, value: serviceManager.services.count)
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
                    .animation(Theme.Animation.standard, value: serviceManager.repositories.count(where: \.isEnabled))
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
                .accessibilityIdentifier(A11yID.Settings.secrets)
            }
        }
    }
}
