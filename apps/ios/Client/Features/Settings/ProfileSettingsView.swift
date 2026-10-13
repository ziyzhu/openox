import SwiftUI

struct ProfileSettingsView: View {
    let profileID: UUID
    let initialSkillDraft: SkillDraft?

    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var operationErrorMessage: String?
    @State private var confirmingDelete = false

    private var storage: StorageRoot { .shared }

    private var profile: Profile? {
        storage.profiles.first { $0.id == profileID }
    }

    private var isSelected: Bool {
        storage.activeId == profileID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                if let profile {
                    if profile.version == ProfileSchema.current {
                        manageSection(for: profile)
                        if profile.location == .external {
                            storageSection
                        }
                        ProfileContentsView(profile: profile, initialSkillDraft: initialSkillDraft)
                            .id(profile.url.path)
                        deleteSection(for: profile)
                    } else {
                        ContentUnavailableView("Use this Profile", systemImage: "person.crop.circle")
                    }
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
                            operationErrorMessage = error.localizedDescription
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
                Text("This removes it from iCloud and all your devices — conversations, files, voice and memory. This can't be undone.")
            } else {
                Text("This removes it from this device — conversations, files, voice and memory. This can't be undone.")
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
                .foregroundStyle(Theme.Colors.conversationSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if profile.location != .external {
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.xs)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
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
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                }
                .settingsRowPadding()
                .settingsSurface(singleRow: true)

                Text("Ox uses this Profile directly from its folder. Closing it does not delete its files.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsContentInset()
                    .accessibilityIdentifier(A11yID.Settings.storeStatus)
            }
        }
    }

    private func manageSection(for profile: Profile) -> some View {
        SettingsSection("Manage", layout: .row) {
            nameRow(for: profile)
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
    let profile: Profile
    @State private var editingSkill: SkillDraft?
    @State private var openingImportedSkill: Bool

    init(profile: Profile, initialSkillDraft: SkillDraft?) {
        self.profile = profile
        _editingSkill = State(initialValue: initialSkillDraft)
        _openingImportedSkill = State(initialValue: initialSkillDraft != nil)
    }

    private var scope: ProfileScope {
        ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
    }

    var body: some View {
        SettingsSection("Profile", layout: .group) {
            VStack(spacing: 0) {
                NavigationLink {
                    ProfileFilesPage(scope: scope)
                } label: {
                    SettingsDisclosureRow(title: "Files", value: Text(""))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.artifacts)

                Divider().settingsContentInset()

                NavigationLink {
                    destination(.skills)
                } label: {
                    SettingsDisclosureRow(title: "Skills", value: Text(""))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.skills)

                Divider().settingsContentInset()

                NavigationLink {
                    destination(.character)
                } label: {
                    SettingsDisclosureRow(title: "Voice", value: Text(""))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.soul)

                Divider().settingsContentInset()

                NavigationLink {
                    destination(.memory)
                } label: {
                    SettingsDisclosureRow(title: "Memory", value: Text(""))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.memory)
            }
        }
        .navigationDestination(isPresented: $openingImportedSkill) {
            destination(.skills)
        }
    }

    private func destination(_ kind: ProfileContentDestination.Kind) -> some View {
        ProfileContentDestination(scope: scope, profileID: profile.id, kind: kind, editingSkill: $editingSkill)
    }
}

private struct ProfileContentDestination: View {
    enum Kind {
        case skills
        case character
        case memory

        var title: LocalizedStringKey {
            switch self {
            case .skills: "Skills"
            case .character: "Voice"
            case .memory: "Memory"
            }
        }
    }

    private enum Content {
        case skills(Skills)
        case character(Soul)
        case memory(UserMemory)
        case failed(String)
    }

    let scope: ProfileScope
    let profileID: UUID
    let kind: Kind
    @Binding var editingSkill: SkillDraft?
    @State private var content: Content?

    var body: some View {
        Group {
            switch content {
            case .skills(let skills):
                SkillsListView(skills: skills, editing: $editingSkill, ready: true, profileID: profileID)
            case .character(let soul):
                CharacterEditorView(soul: soul)
            case .memory(let memory):
                MemoryEditorView(memory: memory)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load Profile", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            case nil:
                ContentLoadingView(label: "Loading…")
            }
        }
        .background(Theme.Colors.background)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scope) { await load() }
    }

    private func load() async {
        content = nil
        do {
            let loaded: Content
            switch kind {
            case .skills:
                let skills = Skills(scope: scope)
                await skills.waitUntilCurrent()
                if let message = skills.errorMessage { throw RuntimeError.bridge(message) }
                loaded = .skills(skills)
            case .character:
                let soul = Soul(scope: scope)
                try await soul.waitUntilCurrent()
                loaded = .character(soul)
            case .memory:
                let memory = UserMemory(scope: scope)
                try await memory.waitUntilCurrent()
                loaded = .memory(memory)
            }
            try Task.checkCancellation()
            content = loaded
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
            Log.ui.error("ProfileSettings.content failed=\(error.localizedDescription)")
        }
    }
}
