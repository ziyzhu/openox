import SwiftUI

struct OxServerView: View {
    @Environment(ServiceManager.self) private var manager
    @State private var addingRepository = false

    private var locale: String? {
        AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
    }

    private var isBusy: Bool {
        manager.repositoryState == .syncing
    }

    private var errorMessage: String? {
        var underlyingMessages = Set<String>()
        var messages = manager.repositories.compactMap { repository -> String? in
            guard repository.isEnabled,
                  case .failed(let message) = repository.state
            else { return nil }
            underlyingMessages.insert(message)
            return "\(repository.name): \(message)"
        }
        if case .failed(let message) = manager.repositoryState,
           !underlyingMessages.contains(message) {
            messages.append(message)
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                repositoriesSection
                if !manager.repositoryConflicts.isEmpty { conflictsSection }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Plugin Repositories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingRepository = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(isBusy)
                .accessibilityLabel("Add repository")
                .accessibilityIdentifier(A11yID.Settings.repositoryAdd)
            }
        }
        .sheet(isPresented: $addingRepository) {
            AddServiceRepositoryView()
        }
    }

    private var repositoriesSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.headerSpacing) {
            Text("Repositories")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()

            if let message = errorMessage {
                SettingsErrorMessage(message: message, systemImage: "exclamationmark.circle.fill")
                    .accessibilityIdentifier(A11yID.Settings.repositoryStatus)
            }

            VStack(spacing: 0) {
                ForEach(Array(manager.repositories.enumerated()), id: \.element.id) { index, repository in
                    if index > 0 { Divider().settingsContentInset() }
                    repositoryRow(repository)
                }
                if manager.repositories.isEmpty {
                    HStack {
                        CellularAutomatonLoader.mini
                        Text("Loading repositories…")
                            .font(Theme.Fonts.bodySm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                    .settingsRowPadding()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsSurface()

            Text("Repositories are collections of plugins that let Ox work with websites, apps, and other tools. Add your own repository to extend Ox with more plugins. Local is always available. Other enabled repositories are read-only.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsContentInset()
        }
    }

    private func repositoryRow(_ repository: ServiceRepository.Repository) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if repository.provenance == .local {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Theme.Colors.primary)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(Text(verbatim: repository.name))
                    .accessibilityValue("Always enabled")
                    .accessibilityIdentifier(A11yID.Settings.repositoryEnabled(repository.id))
            } else {
                Button {
                    Task {
                        await manager.setRepositoryEnabled(repository.id, enabled: !repository.isEnabled, locale: locale)
                    }
                } label: {
                    Image(systemName: repository.isEnabled ? "checkmark.square.fill" : "square")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(repository.isEnabled ? Theme.Colors.primary : Theme.Colors.onSurfaceMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel(Text(verbatim: repository.name))
                .accessibilityValue(repository.isEnabled ? "Enabled" : "Disabled")
                .accessibilityIdentifier(A11yID.Settings.repositoryEnabled(repository.id))
            }

            NavigationLink {
                ServiceRepositoryDetailView(repositoryID: repository.id)
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: repository.name)
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                            .lineLimit(1)
                        Text(verbatim: repositorySubtitle(repository))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .padding(.trailing, Theme.Spacing.lg)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Settings.repository(repository.id))
        }
        .padding(5)
    }

    private func repositorySubtitle(_ repository: ServiceRepository.Repository) -> String {
        let source = switch repository.provenance {
        case .bundled: String(localized: "Included with Ox")
        case .local: String(localized: "Editable on this device")
        case .development: String(localized: "Development Server")
        case .remote: repository.origin?.host ?? String(localized: "Repository")
        }
        return "\(repository.serviceCount) plugins · \(source)"
    }

    private var conflictsSection: some View {
        SettingsSection(
            "Conflicts",
            footer: "Choose which repository provides each plugin. Ox never combines implementations.",
            insetContent: false
        ) {
            VStack(spacing: 0) {
                ForEach(Array(manager.repositoryConflicts.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 { Divider().settingsContentInset() }
                    conflictRow(conflict)
                }
            }
        }
    }

    private func conflictRow(_ conflict: ServiceRepository.Conflict) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(verbatim: conflict.serviceID)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, Theme.Spacing.sm)
            Spacer(minLength: 0)
            conflictPicker(conflict)
        }
        .padding(Theme.Spacing.md)
    }

    private func conflictPicker(_ conflict: ServiceRepository.Conflict) -> some View {
        let selectedName = conflict.candidates.first {
            $0.repositoryID == conflict.selectedRepositoryID
        }?.repositoryName ?? "Choose"
        return Picker(
            "Repository",
            selection: Binding(
                get: { conflict.selectedRepositoryID },
                set: { repositoryID in
                    guard let candidate = conflict.candidates.first(where: {
                        $0.repositoryID == repositoryID
                    }) else { return }
                    resolve(conflict, with: candidate)
                }
            )
        ) {
            if conflict.selectedRepositoryID == nil {
                Text("Choose").tag(String?.none)
            }
            ForEach(conflict.candidates) { candidate in
                Text(verbatim: candidate.repositoryName)
                    .tag(Optional(candidate.repositoryID))
                .accessibilityIdentifier(A11yID.Settings.conflictCandidate(conflict.id, candidate.repositoryID))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.Colors.onSurface)
        .disabled(isBusy)
        .accessibilityLabel(Text(verbatim: conflict.serviceID))
        .accessibilityValue(Text(verbatim: selectedName))
        .accessibilityIdentifier(A11yID.Settings.conflict(conflict.id))
    }

    private func resolve(
        _ conflict: ServiceRepository.Conflict,
        with candidate: ServiceRepository.Conflict.Candidate
    ) {
        Task {
            await manager.resolveConflict(
                serviceID: conflict.serviceID,
                repositoryID: candidate.repositoryID,
                locale: locale
            )
        }
    }
}

private struct AddServiceRepositoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var manager
    @State private var draft = ""
    @State private var installing = false
    @FocusState private var focused: Bool

    private var origin: URL? {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }

    private var locale: String? {
        AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        "Git Repository",
                        footer: "The repository must be public, use HTTPS, and contain ox.json at its root."
                    ) {
                        TextField("https://github.com/example/plugins.git", text: $draft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { if origin != nil { install() } }
                            .accessibilityIdentifier(A11yID.Settings.repositoryURL)
                    }

                    if case .failed(let message) = manager.repositoryState {
                        SettingsErrorMessage(message: message, systemImage: "exclamationmark.circle.fill")
                    }
                }
                .settingsPagePadding()
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
            .navigationTitle("Add Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(installing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(installing ? "Adding…" : "Add") { install() }
                        .disabled(origin == nil || installing)
                        .accessibilityIdentifier(A11yID.Settings.repositoryInstall)
                }
            }
            .task { focused = true }
        }
    }

    private func install() {
        guard let origin else { return }
        focused = false
        installing = true
        Task {
            await manager.installRepository(from: origin, locale: locale)
            installing = false
            if case .ready = manager.repositoryState { dismiss() }
        }
    }
}

struct ServiceRepositoryDetailView: View {
    let repositoryID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var manager
    @State private var confirmingRemoval = false

    private var repository: ServiceRepository.Repository? {
        manager.repositories.first { $0.id == repositoryID }
    }

    private var locale: String? {
        AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
    }

    private var canUpdate: Bool {
        repositoryID != ServiceRepository.bundledID && repositoryID != ServiceRepository.localID
    }

    private var canRemove: Bool {
        repositoryID != ServiceRepository.bundledID
            && repositoryID != ServiceRepository.localID
            && repositoryID != "development"
    }

    private var errorMessage: String? {
        if case .failed(let message) = manager.repositoryState { return message }
        guard let repository,
              case .failed(let message) = repository.state
        else { return nil }
        return message
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                if let repository {
                    VStack(alignment: .leading, spacing: SettingsLayout.headerSpacing) {
                        Text("Repository")
                            .font(Theme.Fonts.labelMd)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                            .settingsSectionHeaderInset()

                        if let message = errorMessage {
                            SettingsErrorMessage(message: message, systemImage: "exclamationmark.circle.fill")
                        }

                        VStack(spacing: 0) {
                            switch repository.provenance {
                            case .bundled:
                                detailRow("Source", value: "Included with Ox")
                            case .local:
                                detailRow("Source", value: "Editable on this device")
                            case .development, .remote:
                                detailRow("Last Synced", value: lastSyncedText(repository))
                            }
                            if let origin = repository.origin {
                                Divider().settingsContentInset()
                                detailRow("Origin", value: origin.absoluteString)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsSurface()
                    }
                    if !repository.services.isEmpty {
                        SettingsSection("Plugins", insetContent: false) {
                            VStack(spacing: 0) {
                                ForEach(Array(repository.services.enumerated()), id: \.element.id) { index, service in
                                    if index > 0 { Divider().settingsContentInset() }
                                    serviceRow(service)
                                }
                            }
                        }
                    }
                    if canRemove { removalSection }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(Text(verbatim: repository?.name ?? "Repository"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canUpdate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await manager.updateRepository(repositoryID, locale: locale) }
                    } label: {
                        if manager.repositoryState == .syncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Sync")
                        }
                    }
                    .disabled(manager.repositoryState == .syncing)
                    .accessibilityLabel("Sync")
                    .accessibilityIdentifier(A11yID.Settings.repositoryUpdate(repositoryID))
                }
            }
        }
        .alert("Remove Repository?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) {
                Task {
                    await manager.removeRepository(repositoryID, locale: locale)
                    if !manager.repositories.contains(where: { $0.id == repositoryID }) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local snapshot. Website sign-ins and data are kept.")
        }
    }

    private func lastSyncedText(_ repository: ServiceRepository.Repository) -> String {
        repository.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Unavailable")
    }

    @ViewBuilder
    private func serviceRow(_ reference: ServiceRepository.ServiceReference) -> some View {
        if let service = manager.service(domain: reference.runtimeID) {
            NavigationLink {
                ServiceDetailView(
                    initialService: service,
                    primaryAction: nil,
                    isAttached: false,
                    onPrimaryAction: nil
                )
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(verbatim: reference.id)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                .contentShape(Rectangle())
                .settingsRowPadding()
            }
            .buttonStyle(.plain)
        } else {
            Text(verbatim: reference.id)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowPadding()
        }
    }

    private var removalSection: some View {
        SettingsSection("Manage", insetContent: false) {
            Button(role: .destructive) {
                confirmingRemoval = true
            } label: {
                HStack {
                    Text("Remove Repository")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.error)
                    Spacer(minLength: 0)
                }
                .settingsRowPadding()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Settings.repositoryRemove(repositoryID))
        }
    }

    private func detailRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            Text(verbatim: value)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .truncationMode(.middle)
        }
        .settingsRowPadding()
    }
}
