import SwiftUI

struct ProfileSettingsView: View {
    let profileID: UUID
    let initialSkillDraft: SkillDraft?
    let artifactRefreshEpoch: Int
    let onRenameArtifact: (Artifact, String, ProfileScope) async throws -> Artifact
    let onDeleteArtifact: (Artifact, ProfileScope) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var operationErrorMessage: String?
    @State private var confirmingDelete = false

    private var storage: StorageRoot { .shared }

    init(
        profileID: UUID,
        initialSkillDraft: SkillDraft?,
        artifactRefreshEpoch: Int,
        onRenameArtifact: @escaping (Artifact, String, ProfileScope) async throws -> Artifact,
        onDeleteArtifact: @escaping (Artifact, ProfileScope) async throws -> Void
    ) {
        self.profileID = profileID
        self.initialSkillDraft = initialSkillDraft
        self.artifactRefreshEpoch = artifactRefreshEpoch
        self.onRenameArtifact = onRenameArtifact
        self.onDeleteArtifact = onDeleteArtifact
    }

    private var profile: Profile? {
        storage.profiles.first { $0.id == profileID }
    }

    private var isSelected: Bool {
        storage.activeId == profileID
    }

    private var iCloudBinding: Binding<Bool> {
        Binding(
            get: { profile?.location == .iCloud },
            set: { enabled in
                guard let profile else { return }
                move(profile, to: enabled ? .iCloud : .local)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                if let profile {
                    manageSection(for: profile)
                    storageSection
                    ProfileContentsView(
                        profile: profile,
                        initialSkillDraft: initialSkillDraft,
                        artifactRefreshEpoch: artifactRefreshEpoch,
                        onRenameArtifact: onRenameArtifact,
                        onDeleteArtifact: onDeleteArtifact
                    )
                        .id(profile.url.path)
                    deleteSection(for: profile)
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(Text(verbatim: profile?.name ?? "Profile"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelected ? "✓" : String(localized: "Use")) {
                    guard !isSelected, let profile else { return }
                    Log.ui.info("ProfileSettings.select id=\(profile.id) name=\(profile.name)")
                    Task {
                        do {
                            try await storage.switchTo(profile)
                        } catch {
                            Log.ui.error("ProfileSettings.select id=\(profile.id) failed: \(error.localizedDescription)")
                        }
                    }
                }
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.primary)
                .disabled(storage.isBusy)
                .accessibilityLabel(Text(
                    isSelected
                        ? String(localized: "Current Profile")
                        : String(localized: "Use this Profile")
                ))
                .accessibilityIdentifier(A11yID.Settings.profileSelection)
                .accessibilityValue(isSelected ? String(localized: "Selected") : "")
            }
        }
        .task(id: profileID) {
            await storage.refreshAvailability()
        }
        .alert("Rename Profile", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                guard let profile else { return }
                let name = nameDraft
                rename(profile, to: name)
            }
            .disabled(profile.map {
                StorageRoot.cleanName(nameDraft) == $0.name || storage.nameTaken(nameDraft, excluding: $0.id)
            } ?? true)
        } message: {
            if let profile, storage.nameTaken(nameDraft, excluding: profile.id) {
                Text("A Profile named “\(StorageRoot.cleanName(nameDraft))” already exists. Choose a different name.")
            }
        }
        .alert("Profile", isPresented: Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { operationErrorMessage = nil }
        } message: {
            Text(operationErrorMessage ?? "")
        }
        .alert(
            "\(profile?.location == .external ? "Close" : "Delete") \(profile?.name ?? "")?",
            isPresented: $confirmingDelete
        ) {
            Button(profile?.location == .external ? "Close Profile" : "Delete Profile", role: .destructive) {
                guard let profile else { return }
                Task {
                    await storage.remove(profile)
                    guard !storage.profiles.contains(where: { $0.id == profile.id }) else { return }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if profile?.location == .external {
                Text("This closes the Profile in Ox. Its folder and contents stay in Files.")
            } else if profile?.location == .iCloud {
                Text("This removes it from iCloud and all your devices — chats, artifacts, character and memory. This can't be undone.")
            } else {
                Text("This removes it from this device — chats, artifacts, character and memory. This can't be undone.")
            }
        }
    }

    private func rename(_ profile: Profile, to name: String) {
        Task {
            do {
                try await storage.rename(profile, to: name)
            } catch {
                Log.ui.error("ProfileSettings.rename id=\(profile.id) error=\(error.localizedDescription)")
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    private func move(_ profile: Profile, to location: Profile.Location) {
        Task {
            do {
                try await storage.move(profile, to: location)
            } catch {
                Log.ui.error("ProfileSettings.move id=\(profile.id) location=\(location.rawValue) error=\(error.localizedDescription)")
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    private func nameRow(for profile: Profile) -> some View {
        Group {
            if profile.location == .external {
                nameRowContent(for: profile)
            } else {
                Button {
                    nameDraft = profile.name
                    renaming = true
                } label: {
                    nameRowContent(for: profile)
                }
                .buttonStyle(.plain)
                .disabled(storage.isBusy)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Name"))
        .accessibilityValue(Text(verbatim: profile.name))
        .accessibilityIdentifier(A11yID.Settings.profileRename(profile.id.uuidString))
    }

    private func nameRowContent(for profile: Profile) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("Name")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            Text(verbatim: profile.name)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            if profile.location != .external {
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
        }
        .settingsRowPadding()
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.headerSpacing) {
            Text("Storage")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()
                .accessibilityIdentifier(A11yID.Settings.profileDetail)

            if profile?.location == .external {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("Files")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Spacer(minLength: 0)
                    Text("Opened in place")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                .settingsRowPadding()
                .settingsSurface(singleRow: true)

                Text("Ox uses this Profile directly from its folder. Closing it does not delete its files.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsContentInset()
                    .accessibilityIdentifier(A11yID.Settings.storeStatus)
            } else if storage.iCloudAvailable {
                Toggle("iCloud", isOn: iCloudBinding)
                    .font(Theme.Fonts.bodyMd)
                    .tint(Theme.Colors.primary)
                    .foregroundStyle(storage.isBusy ? Theme.Colors.onSurfaceMuted : Theme.Colors.onSurface)
                    .settingsRowPadding()
                    .settingsSurface(singleRow: true)
                    .disabled(storage.isBusy)
                    .accessibilityIdentifier(A11yID.Settings.storeICloud)

                Text("iCloud syncs this Profile across your devices. On-device keeps it here only. You can move it either way later.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsContentInset()
                .accessibilityIdentifier(A11yID.Settings.storeStatus)
            } else {
                ICloudUnavailableNotice()
                    .accessibilityIdentifier(A11yID.Settings.storeStatus)
            }
        }
    }

    private func manageSection(for profile: Profile) -> some View {
        SettingsSection("Manage", insetContent: false) {
            VStack(spacing: 0) {
                nameRow(for: profile)
            }
        }
    }

    private func deleteSection(for profile: Profile) -> some View {
        Button(role: .destructive) {
            confirmingDelete = true
        } label: {
            Text(profile.location == .external ? "Close Profile" : "Delete Profile")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.error)
                .settingsRowPadding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .settingsSurface(singleRow: true)
        .buttonStyle(.plain)
        .disabled(storage.isBusy)
        .accessibilityIdentifier(A11yID.Settings.profileDelete(profile.id.uuidString))
    }

}

private struct ProfileContentsView: View {
    private struct Context {
        let scope: ProfileScope
        let memory: UserMemory
        let soul: Soul
        let skills: Skills
        var artifactCount: Int

        func waitUntilCurrent() async {
            await memory.waitUntilCurrent()
            await soul.waitUntilCurrent()
            await skills.waitUntilCurrent()
        }
    }

    let profile: Profile
    let artifactRefreshEpoch: Int
    let onRenameArtifact: (Artifact, String, ProfileScope) async throws -> Artifact
    let onDeleteArtifact: (Artifact, ProfileScope) async throws -> Void
    @State private var context: Context?
    @State private var editingSkill: SkillDraft?
    @State private var openingImportedSkill: Bool

    init(
        profile: Profile,
        initialSkillDraft: SkillDraft?,
        artifactRefreshEpoch: Int,
        onRenameArtifact: @escaping (Artifact, String, ProfileScope) async throws -> Artifact,
        onDeleteArtifact: @escaping (Artifact, ProfileScope) async throws -> Void
    ) {
        self.profile = profile
        self.artifactRefreshEpoch = artifactRefreshEpoch
        self.onRenameArtifact = onRenameArtifact
        self.onDeleteArtifact = onDeleteArtifact
        _editingSkill = State(initialValue: initialSkillDraft)
        _openingImportedSkill = State(initialValue: initialSkillDraft != nil)
    }

    private var memorySummary: Text {
        let trimmed = context?.memory.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = trimmed.split(whereSeparator: \.isNewline).first else {
            return Text("Empty")
        }
        return Text(verbatim: String(first))
    }

    private var soulSummary: Text {
        context?.soul.text == Soul.defaultText ? Text("Default") : Text("Custom")
    }

    private var artifactsSummary: Text {
        guard let count = context?.artifactCount, count > 0 else { return Text("None") }
        return Text(verbatim: "\(count)")
    }

    private var skillsSummary: Text {
        guard let count = context?.skills.all.count, count > 0 else { return Text("None") }
        return Text(verbatim: "\(count)")
    }

    var body: some View {
        SettingsSection(
            "Profile",
            insetContent: false
        ) {
            VStack(spacing: 0) {
                NavigationLink {
                    if let context { artifactsView(context) }
                } label: {
                    SettingsDisclosureRow(
                        title: "Artifacts",
                        value: artifactsSummary,
                        isLoading: context == nil
                    )
                }
                .buttonStyle(.plain)
                .disabled(context == nil)
                .accessibilityIdentifier(A11yID.Settings.artifacts)

                Divider().settingsContentInset()

                NavigationLink {
                    if let context { skillsView(context) }
                } label: {
                    SettingsDisclosureRow(
                        title: "Skills",
                        value: skillsSummary,
                        isLoading: context?.skills.isLoaded != true
                    )
                }
                .buttonStyle(.plain)
                .disabled(context?.skills.isLoaded != true)
                .accessibilityIdentifier(A11yID.Settings.skills)

                Divider().settingsContentInset()

                NavigationLink {
                    if let context { CharacterEditorView(soul: context.soul) }
                } label: {
                    SettingsDisclosureRow(
                        title: "Character",
                        value: soulSummary,
                        isLoading: context?.soul.isLoaded != true
                    )
                }
                .buttonStyle(.plain)
                .disabled(context?.soul.isLoaded != true)
                .accessibilityIdentifier(A11yID.Settings.soul)

                Divider().settingsContentInset()

                NavigationLink {
                    if let context { MemoryEditorView(memory: context.memory) }
                } label: {
                    SettingsDisclosureRow(
                        title: "Memory",
                        value: memorySummary,
                        isLoading: context?.memory.isLoaded != true
                    )
                }
                .buttonStyle(.plain)
                .disabled(context?.memory.isLoaded != true)
                .accessibilityIdentifier(A11yID.Settings.memory)
            }
        }
        .task(id: profile.url.path) {
            await load()
        }
        .task(id: artifactRefreshEpoch) {
            await refreshArtifactCount()
        }
        .onAppear {
            Task { await refreshArtifactCount() }
        }
        .navigationDestination(isPresented: $openingImportedSkill) {
            if let context { skillsView(context) }
        }
    }

    private func artifactsView(_ context: Context) -> some View {
        ArtifactsView(
            scope: context.scope,
            emptyStateReady: true,
            refreshEpoch: artifactRefreshEpoch,
            onRename: { artifact, newFilename in
                try await onRenameArtifact(artifact, newFilename, context.scope)
            },
            onDelete: { artifact in
                try await onDeleteArtifact(artifact, context.scope)
            }
        )
    }

    private func skillsView(_ context: Context) -> some View {
        SkillsListView(
            skills: context.skills,
            editing: $editingSkill,
            ready: true,
            profileID: profile.id
        )
    }

    private func load() async {
        context = nil
        let scope = ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
        let loaded = Context(
            scope: scope,
            memory: UserMemory(scope: scope),
            soul: Soul(scope: scope),
            skills: Skills(scope: scope),
            artifactCount: 0
        )
        await loaded.waitUntilCurrent()
        let artifacts = await ProfileRepository.shared.artifacts(in: scope)
        guard !Task.isCancelled else { return }
        var complete = loaded
        complete.artifactCount = artifacts.count
        context = complete
    }

    private func refreshArtifactCount() async {
        guard var current = context else { return }
        let artifacts = await ProfileRepository.shared.artifacts(in: current.scope)
        guard !Task.isCancelled, context?.scope == current.scope else { return }
        current.artifactCount = artifacts.count
        context = current
    }

}
