import SwiftUI

struct RepositoriesView: View {
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
        .navigationTitle("Repositories")
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
            AddRepositoryView()
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

            Text("Repositories provide services and shared skills. Your personal skills are stored in your Profile.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsContentInset()
        }
    }

    private func repositoryRow(_ repository: Repository.Descriptor) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
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

            NavigationLink {
                RepositoryDetailView(repositoryID: repository.id)
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
                        if let description = repository.provenance.skillOwnershipDescription {
                            Text(description)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Theme.Icons.xs)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Settings.repository(repository.id))
        }
        .settingsRowPadding()
    }

    private func repositorySubtitle(_ repository: Repository.Descriptor) -> String {
        let source = switch repository.provenance {
        case .bundled: String(localized: "Included with Ox")
        case .local: String(localized: "Editable on this device")
        case .development: String(localized: "Development Server")
        case .remote: repository.origin?.host ?? String(localized: "Repository")
        }
        return String(localized: "\(repository.serviceCount) services · \(repository.skills.count) skills · \(source)")
    }

    private var conflictsSection: some View {
        SettingsSection(
            "Conflicts",
            footer: "Choose which repository provides each service. Ox never combines implementations.",
            layout: .group
        ) {
            VStack(spacing: 0) {
                ForEach(Array(manager.repositoryConflicts.enumerated()), id: \.element.id) { index, conflict in
                    if index > 0 { Divider().settingsContentInset() }
                    conflictRow(conflict)
                }
            }
        }
    }

    private func conflictRow(_ conflict: Repository.Conflict) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(verbatim: conflict.serviceID)
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            conflictPicker(conflict)
        }
        .settingsRowPadding()
    }

    private func conflictPicker(_ conflict: Repository.Conflict) -> some View {
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
        _ conflict: Repository.Conflict,
        with candidate: Repository.Conflict.Candidate
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

private struct AddRepositoryView: View {
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
                        footer: "The repository must be public, use HTTPS, and contain repository.json at its root."
                    ) {
                        TextField("https://github.com/example/services.git", text: $draft)
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

struct RepositoryDetailView: View {
    let repositoryID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var manager
    @State private var confirmingRemoval = false

    private var repository: Repository.Descriptor? {
        manager.repositories.first { $0.id == repositoryID }
    }

    private var locale: String? {
        AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
    }

    private var canUpdate: Bool {
        repositoryID != Repository.bundledID && repositoryID != Repository.localID
    }

    private var canRemove: Bool {
        repositoryID != Repository.bundledID
            && repositoryID != Repository.localID
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
                                detailRow("Source", value: String(localized: "Included with Ox"))
                            case .local:
                                detailRow("Source", value: String(localized: "Editable on this device"))
                            case .development, .remote:
                                detailRow("Last Synced", value: lastSyncedText(repository))
                            }
                            if let origin = repository.origin {
                                Divider().settingsContentInset()
                                detailRow("Origin", value: origin.absoluteString)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsSurface(singleRow: repository.origin == nil)
                        if let description = repository.provenance.skillOwnershipDescription {
                            Text(description)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                                .settingsSectionHeaderInset()
                        }
                    }
                    if !repository.services.isEmpty {
                        SettingsSection("Services", layout: .group) {
                            VStack(spacing: 0) {
                                ForEach(Array(repository.services.enumerated()), id: \.element.id) { index, service in
                                    if index > 0 { Divider().settingsContentInset() }
                                    serviceRow(service)
                                }
                            }
                        }
                    }
                    if !repository.skills.isEmpty {
                        SettingsSection("Skills", layout: .group) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                ForEach(repository.skills, id: \.self) { name in
                                    Text(verbatim: "/\(name)").settingsRowPadding()
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

    private func lastSyncedText(_ repository: Repository.Descriptor) -> String {
        repository.lastSyncedAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Unavailable")
    }

    @ViewBuilder
    private func serviceRow(_ reference: Repository.ServiceReference) -> some View {
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
                        .font(Theme.Icons.xs)
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
        SettingsSection("Manage", layout: .row) {
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

private extension Repository.Descriptor.Provenance {
    var skillOwnershipDescription: LocalizedStringKey? {
        switch self {
        case .bundled: "Services and shared skills included with Ox."
        case .local: "Services and shared skills you can edit on this device. Available across Profiles."
        case .development, .remote: nil
        }
    }
}
