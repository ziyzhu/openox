import SwiftUI
import UniformTypeIdentifiers

private struct ProfileFolderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    let folder: FileWrapper

    init(data: Data) throws { folder = try ProfilePackage.folder(data) }

    init(configuration: ReadConfiguration) throws { folder = configuration.file }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { folder }


}

struct ProfileSettingsView: View {
    let profileID: UUID
    let initialSkillDraft: SkillDraft?

    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var operationErrorMessage: String?
    @State private var confirmingDelete = false
    @State private var exportDocument: ProfileFolderDocument?
    @State private var presentingExport = false
    @State private var showingFiles = false
    @State private var choosingMoveLocation = false
    @State private var movedSource: (profile: Profile, inventory: [String: String])?

    private var storage: StorageRoot { .shared }

    private var profile: Profile? {
        storage.profiles.first { $0.id == profileID }
    }

    private var isSelected: Bool {
        storage.activeId == profileID
    }

    var body: some View {
        profilePage
        .profileFilesBrowser(scope: profile.map { ProfileScope(profileID: $0.id, root: $0.url, location: $0.location) }, isPresented: $showingFiles)
        .fileImporter(isPresented: $choosingMoveLocation, allowedContentTypes: [.folder]) { result in
            guard let profile else { return }
            do {
                let parent = try result.get()
                Task {
                    do {
                        let inventory = try await storage.moveProfile(profile, to: parent)
                        movedSource = (profile, inventory)
                    } catch { operationErrorMessage = error.localizedDescription }
                }
            } catch { operationErrorMessage = error.localizedDescription }
        }
        .alert("Remove the original folder?", isPresented: Binding(get: { movedSource != nil }, set: { if !$0 { movedSource = nil } })) {
            if let source = movedSource {
                Button("Remove Original", role: .destructive) {
                    Task {
                        do { try await storage.removeMovedSource(source.profile, inventory: source.inventory) }
                        catch { operationErrorMessage = "The Profile is at its new location, but the original folder was kept. " + error.localizedDescription }
                    }
                }
                .accessibilityIdentifier("settings.profileMove.removeOriginal")
                Button("Keep Both Copies", role: .cancel) { movedSource = nil }
                    .accessibilityIdentifier("settings.profileMove.keepBoth")
            }
        } message: {
            Text("Ox is now using the verified copy. Remove the original folder from \(movedSource?.profile.url.deletingLastPathComponent().lastPathComponent ?? "") to finish the move, or keep both copies.")
        }
    }

    private var profilePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                if let profile {
                    if profile.version == ProfileSchema.current {
                        ProfileContentsView(profile: profile, initialSkillDraft: initialSkillDraft)
                            .id(profile.url.path)
                        detailsSection(for: profile)
                        exportSection(for: profile)
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
        .fileExporter(isPresented: $presentingExport, document: exportDocument, contentType: .folder,
            defaultFilename: "\(profile?.name ?? "Profile")-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
            if case .failure(let error) = result { operationErrorMessage = error.localizedDescription }
            if case .success(let url) = result,
               url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: ProfileRepository.localDocuments().standardizedFileURL.resolvingSymlinksInPath().pathComponents) {
                operationErrorMessage = String(localized: "This backup is saved inside Ox and will be removed if you delete the app. Export another copy to iCloud Drive or a location outside Ox.")
            }
            exportDocument = nil
        }
        .onChange(of: presentingExport) { _, presented in
            if !presented { exportDocument = nil }
        }
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

    private func detailsSection(for profile: Profile) -> some View {
        SettingsSection(layout: .group) {
            VStack(spacing: 0) {
                nameRow(for: profile)
                Divider().settingsContentInset()
                Button { showingFiles = true } label: {
                    SettingsDisclosureRow(
                        title: "Location",
                        value: Text(verbatim: "\(profile.url.deletingLastPathComponent().lastPathComponent) / \(profile.name)")
                    )
                }
                .buttonStyle(.plain)
                .disabled(storage.isBusy)
                .accessibilityIdentifier(A11yID.Settings.profileDetail)
                .accessibilityHint("Show in Files")
                Divider().settingsContentInset()
                Button { choosingMoveLocation = true } label: {
                    SettingsDisclosureRow(title: "Move Profile…", value: Text(""))
                }
                .buttonStyle(.plain)
                .disabled(storage.isBusy)
                .accessibilityIdentifier(A11yID.Settings.profileMove(profile.id.uuidString))
            }
        }
    }

    private func exportSection(for profile: Profile) -> some View {
        SettingsSection(footer: "Export to iCloud Drive or another location outside Ox to keep a copy after deleting the app. Credentials and device permissions aren't included.", layout: .row) {
            Button {
                Task {
                    do {
                        exportDocument = try ProfileFolderDocument(data: try await storage.exportProfile(profile))
                        presentingExport = true
                    } catch {
                        operationErrorMessage = error.localizedDescription
                    }
                }
            } label: {
                SettingsDisclosureRow(title: "Export Copy…", value: Text(storage.exportProgress.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? ""), indicator: nil)
            }
            .buttonStyle(.plain)
            .disabled(storage.isBusy)
            .accessibilityIdentifier(A11yID.Settings.profileExport(profile.id.uuidString))
            .overlay(alignment: .bottomLeading) {
                if let progress = storage.exportProgress {
                    Rectangle()
                        .fill(Theme.Colors.primary.dynamic)
                        .frame(height: 2)
                        .scaleEffect(x: progress, y: 1, anchor: .leading)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(DefaultGlassEffectShape())
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
        SettingsSection(layout: .group) {
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
