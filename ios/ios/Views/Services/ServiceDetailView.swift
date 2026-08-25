import SwiftUI
import UniformTypeIdentifiers

enum ServiceDetailPrimaryAction {
    case startChat
    case attach

    func label(isAttached: Bool) -> LocalizedStringKey {
        switch self {
        case .startChat: "Start chat"
        case .attach: isAttached ? "Remove" : "Attach"
        }
    }

    func systemImage(isAttached: Bool) -> String {
        switch self {
        case .startChat: "paperclip"
        case .attach: isAttached ? "minus.circle" : "plus.circle"
        }
    }

    func accessibilityIdentifier(_ domain: String, isAttached: Bool) -> String {
        switch self {
        case .startChat: A11yID.Chat.Attach.startChat(domain)
        case .attach:
            isAttached
                ? A11yID.Chat.Attach.remove(domain)
                : A11yID.Chat.Attach.attach(domain)
        }
    }
}

struct ServiceDetailView: View {
    let initialService: Service
    let primaryAction: ServiceDetailPrimaryAction?
    let isAttached: Bool
    let onPrimaryAction: (() -> Void)?
    var browserSessionID: UUID? = nil
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.dismiss) private var dismiss

    private var service: Service {
        serviceManager.service(domain: initialService.domain) ?? initialService
    }

    private var capabilities: ServiceDetailCapabilities { service.detailCapabilities }

    @State private var actions: [Manifest.Action] = []
    @State private var skills: [Manifest.Skill] = []
    @State private var loadingManifest = true
    @State private var refreshingAuth = true
    @State private var signingOut = false
    @State private var descriptionExpanded = false
    @State private var descriptionFullHeight: CGFloat = 0
    @State private var descriptionLimitedHeight: CGFloat = 0
    @State private var confirmClearWebData = false
    @State private var showPageInspector = false
    @State private var folderPickerPresented = false
    @State private var folderError: String?
    @State private var authorizingMCP = false
    @State private var mcpAuthorizationError: String?
    @State private var confirmRemoveMCP = false
    @State private var confirmDeleteLocalService = false
    @State private var localServiceDeleteError: String?
    @State private var presentations = AppPresentationCoordinator()

    var body: some View {
        content
            .alert("Delete Local plugin?", isPresented: $confirmDeleteLocalService) {
                Button("Delete", role: .destructive) {
                    Task { await deleteLocalService() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes this plugin's editable source from Local. The deletion remains an uncommitted Local Git change, and website sign-ins and data are kept.")
            }
            .alert("Couldn't delete Local plugin", isPresented: Binding(
                get: { localServiceDeleteError != nil },
                set: { if !$0 { localServiceDeleteError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(localServiceDeleteError ?? "")
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                descriptionSection
                permissionsSection
                actionsSection
                skillsSection
                domainSection
                repositorySection
                manageSection
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(service.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: Theme.Spacing.sm) {
                    let saved = serviceManager.isSaved(service)
                    Button {
                        serviceManager.setSaved(service, !saved)
                    } label: {
                        Label(saved ? "Saved" : "Save",
                              systemImage: saved ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityIdentifier(A11yID.Chat.Attach.save(service.domain))

                    if let primaryAction, let onPrimaryAction {
                        Button {
                            onPrimaryAction()
                        } label: {
                            Label(
                                primaryAction.label(isAttached: isAttached),
                                systemImage: primaryAction.systemImage(isAttached: isAttached)
                            )
                        }
                        .accessibilityIdentifier(
                            primaryAction.accessibilityIdentifier(service.domain, isAttached: isAttached)
                        )
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showPageInspector) {
            ServicePageInspector(service: service, browserSessionID: browserSessionID)
        }
        .alert("Clear website data?", isPresented: $confirmClearWebData) {
            Button("Clear data", role: .destructive) {
                Task { await service.clearWebData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes cookies, cache, and stored data for \(service.title). You may need to sign in again.")
        }
        .alert("Remove MCP server?", isPresented: $confirmRemoveMCP) {
            Button("Remove", role: .destructive) {
                serviceManager.removeRemoteMCP(service)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this server, its discovered tools, and its local authorization from Ox. The server does not receive a revocation request.")
        }
        .alert("Couldn't authorize MCP server", isPresented: Binding(
            get: { mcpAuthorizationError != nil },
            set: { if !$0 { mcpAuthorizationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mcpAuthorizationError ?? "")
        }
        .alert("Couldn't update Files access", isPresented: Binding(
            get: { folderError != nil },
            set: { if !$0 { folderError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(folderError ?? "")
        }
        .fileImporter(
            isPresented: $folderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    try await DeviceFolderStore.shared.add(url)
                } catch {
                    Log.ui.error("ServiceDetail.files add failed \(error.localizedDescription)")
                    folderError = error.localizedDescription
                }
            }
        }
        .task(id: service.id) {
            refreshingAuth = true
            loadingManifest = true
            _ = await service.loadManifest(reason: .serviceDetail)
            actions = service.definition.exposedActions
            skills = service.definition.skills
            loadingManifest = false
            guard !Task.isCancelled else { return }
            switch capabilities.authentication {
            case .systemPermission:
                await service.resolveAccess(reason: .serviceDetail)
                refreshingAuth = false
                return
            case .service:
                await service.resolveSignInState(reason: .serviceDetail)
                guard !Task.isCancelled else { return }
                refreshingAuth = false
            case .mcp:
                await service.resolveAccess(reason: .serviceDetail)
                refreshingAuth = false
            case .none:
                refreshingAuth = false
            }
        }
        .appPresentations(presentations)
    }

    private func deleteLocalService() async {
        do {
            _ = try await serviceManager.deleteLocalService(
                domain: service.domain,
                locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
            )
            dismiss()
        } catch {
            localServiceDeleteError = error.localizedDescription
        }
    }

    // MARK: - Auth chip

    @ViewBuilder
    private var authChip: some View {
        switch capabilities.authentication {
        case .systemPermission:
            permissionButton
        case .service:
            if refreshingAuth && service.signInState == .unknown {
                signInButton(signingIn: true)
                    .accessibilityIdentifier(A11yID.Chat.Attach.signInProgress(service.domain))
            } else {
                switch service.signInState {
                case .signedOut, .notAuthorized, .unknown:
                    let signingIn = service.auth.isSigningIn
                    signInButton(signingIn: signingIn)
                        .accessibilityIdentifier(
                            signingIn
                                ? A11yID.Chat.Attach.signInProgress(service.domain)
                                : A11yID.Chat.Attach.signIn(service.domain)
                        )
                case .signedIn, .authorized:
                    if signingOut {
                        ServiceSignInButton(
                            signingIn: true,
                            isDisabled: true,
                            layout: .compact,
                            action: {}
                        )
                        .accessibilityLabel(String(localized: "Signing out…"))
                        .accessibilityIdentifier(A11yID.Chat.Attach.signOutProgress(service.domain))
                    } else {
                        Button("Sign out") { Task { await signOut() } }
                            .buttonStyle(OxChipButton(filled: false))
                            .accessibilityIdentifier(A11yID.Chat.Attach.signOut(service.domain))
                    }
                case .notRequired:
                    EmptyView()
                }
            }
        case .mcp:
            if let title = service.accessAuthorizationTitle {
                Button {
                    Task { await authorizeMCP() }
                } label: {
                    Group {
                        if authorizingMCP {
                            CellularAutomatonLoader(size: 16, tint: Theme.Colors.onPrimary.dynamic)
                                .accessibilityLabel(String(localized: "Authorizing…"))
                        } else {
                            Text(title)
                                .font(Theme.Fonts.labelMd)
                                .foregroundStyle(Theme.Colors.onPrimary)
                        }
                    }
                    .frame(minWidth: 64)
                    .frame(minHeight: 18)
                }
                .buttonStyle(OxChipButton(filled: true))
                .disabled(authorizingMCP)
                .accessibilityIdentifier(A11yID.Chat.Attach.signIn(service.domain))
            }
        case .none:
            EmptyView()
        }
    }

    private func signInButton(signingIn: Bool) -> some View {
        ServiceSignInButton(
            signingIn: signingIn,
            isDisabled: signingIn,
            layout: .compact
        ) {
            Task { await service.signIn(using: presentations, source: .serviceDetail) }
        }
    }

    private func signOut() async {
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        await service.signOut()
    }

    private func authorizeMCP() async {
        authorizingMCP = true
        defer { authorizingMCP = false }
        do {
            try await service.authorizeMCP()
        } catch {
            Log.service.error("RemoteMCP.authorize failed id=\(service.domain) error=\(error.localizedDescription)")
            mcpAuthorizationError = error.localizedDescription
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
            ServiceAvatar(
                service: service,
                size: 64,
                shape: .roundedRect(Theme.Radius.lg),
                monogramSize: 26
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(service.title)
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.Colors.onSurface)
                Spacer(minLength: Theme.Spacing.xs)
                authChip
                    .frame(height: Theme.Size.chipHeight)
            }
            .frame(minHeight: 64)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Description

    private var descriptionTruncated: Bool {
        descriptionFullHeight > descriptionLimitedHeight + 1
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if service.summary.isEmpty {
                Text("No description.")
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            } else {
                Text(service.summary)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(descriptionExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(heightProbe(lineLimit: nil) { descriptionFullHeight = $0 })
                    .background(heightProbe(lineLimit: 4) { descriptionLimitedHeight = $0 })
                if descriptionTruncated {
                    Button(descriptionExpanded ? "Less" : "More") {
                        withAnimation(.easeInOut(duration: 0.15)) { descriptionExpanded.toggle() }
                    }
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.primary)
                }
            }
        }
    }

    private func heightProbe(lineLimit: Int?, onMeasure: @escaping (CGFloat) -> Void) -> some View {
        Text(service.summary)
            .font(Theme.Fonts.bodyMd)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { onMeasure(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in onMeasure(h) }
            })
    }

    @ViewBuilder
    private var domainSection: some View {
        if capabilities.showsDomain {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(service.isMCPService ? "Endpoint" : "Domain")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.md)
                Text(verbatim: service.isMCPService ? service.url : service.domain)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.md)
                    .settingsSurface()
                    .accessibilityIdentifier(A11yID.Chat.Attach.domain(service.domain))
            }
        }
    }

    private var repository: ServiceRepository.Repository? {
        guard let repositoryID = service.definition.repositoryID else { return nil }
        return serviceManager.repositories.first { $0.id == repositoryID }
    }

    @ViewBuilder
    private var repositorySection: some View {
        if let repository {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Repository")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.md)
                NavigationLink {
                    ServiceRepositoryDetailView(repositoryID: repository.id)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: repository.name)
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .lineLimit(1)
                            Text(verbatim: repositoryStatus(repository))
                                .font(Theme.Fonts.bodySm)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                    .padding(Theme.Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsSurface()
                .accessibilityIdentifier(A11yID.Chat.Attach.repository(service.domain))
            }
        }
    }

    private func repositoryStatus(_ repository: ServiceRepository.Repository) -> String {
        if repository.provenance == .bundled { return String(localized: "Included with Ox") }
        if repository.provenance == .local { return String(localized: "Editable on this device") }
        guard let date = repository.lastSyncedAt else { return String(localized: "Last sync unavailable") }
        return String(localized: "Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Actions")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .padding(.horizontal, Theme.Spacing.md)

            if loadingManifest {
                CellularAutomatonLoader.small
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.lg)
            } else if capabilities.supportsFolderAccess {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(OxFileSystem.invocations, id: \.rawValue) { action in
                        fileSystemActionRow(action)
                    }
                }
            } else if actions.isEmpty {
                Text("This plugin exposes no actions.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.md)
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(actions) { action in
                        actionRow(action)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        if capabilities.showsSkills {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Skills")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.md)

                if loadingManifest {
                    CellularAutomatonLoader.small
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.lg)
                } else if skills.isEmpty {
                    Text("This plugin exposes no skills.")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .padding(.horizontal, Theme.Spacing.md)
                } else {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(skills, id: \.name) { skill in
                            skillRow(skill)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Manage

    private func autoApprove(_ action: Manifest.Action) -> Binding<Bool> {
        let name = "\(service.domain):\(action.id)"
        return Binding(
            get: { serviceManager.isAutoApproved(name) },
            set: { serviceManager.setAutoApprove(name, $0) }
        )
    }

    private func autoApproveFileAction(_ action: InvocationName) -> Binding<Bool> {
        let name = Chat.fileApproveKey(action)
        return Binding(
            get: { serviceManager.isAutoApproved(name) },
            set: { serviceManager.setAutoApprove(name, $0) }
        )
    }

    private var autoApproveAttach: Binding<Bool> {
        let name = Chat.attachApproveKey(service.domain)
        return Binding(
            get: { serviceManager.isAutoApproved(name) },
            set: { serviceManager.setAutoApprove(name, $0) }
        )
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Permissions")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .padding(.horizontal, Theme.Spacing.md)
            attachPermissionContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                .settingsSurface()
            if capabilities.supportsFolderAccess {
                filesPermissionContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.md)
                    .settingsSurface()
            }
        }
    }

    private var attachPermissionContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Attach to a chat")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Text(attachPermissionDescription)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .fixedSize(horizontal: false, vertical: true)
            Divider().padding(.vertical, 4)
            Toggle(isOn: autoApproveAttach) {
                Text("Attach without asking for approval")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .tint(Theme.Colors.primary)
        }
    }

    private var attachPermissionDescription: LocalizedStringKey {
        switch capabilities.attachmentData {
        case .signedIn: "Adds this plugin to a chat, giving Ox its actions, skills, and your signed-in data."
        case .onDevice: "Its actions and permitted device data become available to this chat."
        case .remote: "Its remote tools can receive arguments from this chat and return data to Ox."
        }
    }

    private var filesPermissionContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Folders")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Text("Ox can only access folders you add here.")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            ChipFlowLayout(spacing: 6) {
                ForEach(DeviceFolderStore.shared.grants) { grant in
                    folderGrantChip(grant)
                }
                addFolderChip
            }
        }
    }

    private var addFolderChip: some View {
        Button {
            Log.ui.info("IOSService.files picker requested")
            folderPickerPresented = true
        } label: {
            Chip {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add folder")
                    .font(Theme.Fonts.labelMd)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Chat.Attach.deviceFilesAdd)
    }

    private func folderGrantChip(_ grant: DeviceFolderStore.Grant) -> some View {
        Chip {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Text(grant.name)
                .font(Theme.Fonts.labelMd)
                .lineLimit(1)
            Button {
                Task {
                    do {
                        try await DeviceFolderStore.shared.remove(grant.id)
                    } catch {
                        folderError = error.localizedDescription
                    }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(grant.name)")
            .accessibilityIdentifier(A11yID.Chat.Attach.deviceFilesRemove(grant.id))
        }
    }

    private var permissionButton: some View {
        Button(LocalizedStringKey(service.accessActionLabel)) {
            Task { try? await service.requestAccess() }
        }
        .buttonStyle(OxChipButton(filled: service.auth == .authorizationRequired))
        .disabled(service.auth == .unknown || service.auth.isUnavailable)
        .accessibilityIdentifier(A11yID.Chat.Attach.devicePermission(service.domain))
    }

    @ViewBuilder
    private var manageSection: some View {
        if canInspectPage || capabilities.supportsWebsiteDataManagement || capabilities.supportsRemoteManagement || service.isLocalService {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Manage")
                    .font(Theme.Fonts.labelMd)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .padding(.horizontal, Theme.Spacing.md)
                VStack(spacing: 0) {
                    if canInspectPage {
                        manageRow("Inspect plugin page", tint: AnyShapeStyle(Theme.Colors.onSurface)) {
                            inspectPage()
                        }
                        .accessibilityIdentifier(A11yID.Chat.Attach.inspectPage(service.domain))
                    }
                    if capabilities.supportsWebsiteDataManagement {
                        if canInspectPage {
                            Divider().padding(.horizontal, Theme.Spacing.md)
                        }
                        manageRow("Clear website data", tint: AnyShapeStyle(Theme.Colors.error)) {
                            confirmClearWebData = true
                        }
                        .accessibilityIdentifier(A11yID.Chat.Attach.clearWebData(service.domain))
                    }
                    if capabilities.supportsRemoteManagement {
                        manageRow("Remove MCP server", tint: AnyShapeStyle(Theme.Colors.error)) {
                            confirmRemoveMCP = true
                        }
                        .accessibilityIdentifier(A11yID.Chat.Attach.disconnectMCP(service.domain))
                    }
                    if service.isLocalService {
                        if canInspectPage || capabilities.supportsWebsiteDataManagement || capabilities.supportsRemoteManagement {
                            Divider().padding(.horizontal, Theme.Spacing.md)
                        }
                        manageRow("Delete Local plugin", tint: AnyShapeStyle(Theme.Colors.error)) {
                            confirmDeleteLocalService = true
                        }
                        .accessibilityIdentifier(A11yID.Chat.Attach.deleteLocalService(service.domain))
                    }
                }
                .settingsSurface()
            }
        }
    }

    private var canInspectPage: Bool {
        guard capabilities.supportsPageInspection else { return false }
        guard service.domain == "ios:browser" else { return true }
        return isAttached && browserSessionID != nil
    }

    private func inspectPage() {
        if service.domain == "ios:browser", let browserSessionID {
            _ = serviceManager.browserActionSessions.session(for: service, chatID: browserSessionID)
        }
        showPageInspector = true
    }

    private func manageRow(_ label: LocalizedStringKey, tint: AnyShapeStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(_ action: Manifest.Action) -> some View {
        actionCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(action.label)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .accessibilityIdentifier(A11yID.Chat.Attach.action(action.id))
                    Spacer(minLength: 0)
                    if action.requireAuth { chip("Authenticated") }
                }
                if let desc = action.description, !desc.isEmpty {
                    Text(desc)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if action.requireApproval {
                    approvalControl(isOn: autoApprove(action), actionID: action.id)
                }
            }
        }
    }

    private func fileSystemActionRow(_ action: InvocationName) -> some View {
        actionCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.approvalLabel)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .accessibilityIdentifier(A11yID.Chat.Attach.action(action.rawValue))
                if OxFileSystem.approvalInvocations.contains(action) {
                    approvalControl(isOn: autoApproveFileAction(action), actionID: action.rawValue)
                }
            }
        }
    }

    @ViewBuilder
    private func approvalControl(isOn: Binding<Bool>, actionID: String) -> some View {
        Divider().padding(.vertical, 4)
        Toggle(isOn: isOn) {
            Text("Auto-approve")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .tint(Theme.Colors.primary)
        .accessibilityIdentifier(A11yID.Chat.Attach.actionApproval(actionID))
    }

    private func actionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .settingsSurface()
    }

    private func skillRow(_ skill: Manifest.Skill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(skill.name)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Text(skill.description)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .settingsSurface()
    }

    private func chip(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.Fonts.captionSm)
            .foregroundStyle(Theme.Colors.onSurface)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(Theme.Colors.surfaceSunken, in: Capsule(style: .continuous))
    }
}
