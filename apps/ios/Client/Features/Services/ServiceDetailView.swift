import SwiftUI
import UniformTypeIdentifiers

enum ServiceDetailPrimaryAction {
    case startConversation
    case attach

    func label(isAttached: Bool) -> LocalizedStringKey {
        switch self {
        case .startConversation: "Start conversation"
        case .attach: isAttached ? "Remove" : "Attach"
        }
    }

    func systemImage(isAttached: Bool) -> String {
        switch self {
        case .startConversation: "paperclip"
        case .attach: isAttached ? "minus.circle" : "plus.circle"
        }
    }

    func accessibilityIdentifier(_ domain: String, isAttached: Bool) -> String {
        switch self {
        case .startConversation: A11yID.ConversationControls.Attach.startConversation(domain)
        case .attach:
            isAttached
                ? A11yID.ConversationControls.Attach.remove(domain)
                : A11yID.ConversationControls.Attach.attach(domain)
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
    @Environment(\.colorScheme) private var colorScheme

    private var service: Service {
        serviceManager.service(domain: initialService.domain) ?? initialService
    }

    private var capabilities: ServiceDetailCapabilities { service.detailCapabilities }

    private var actions: [Manifest.Action] { service.definition.actions }
    private var loadingManifest: Bool { service.capabilityState == .unloaded || service.capabilityState == .loading }
    @State private var signInRequestActive = false
    @State private var signingOut = false
    @State private var descriptionExpanded = false
    @State private var descriptionFullHeight: CGFloat = 0
    @State private var descriptionLimitedHeight: CGFloat = 0
    @State private var confirmClearWebData = false
    @State private var showPageInspector = false
    @State private var authorizingMCP = false
    @State private var mcpAuthorizationError: String?
    @State private var confirmRemoveMCP = false
    @State private var confirmDeleteLocalService = false
    @State private var localServiceDeleteError: String?
    @State private var presentations = AppPresentationCoordinator()

    var body: some View {
        content
            .alert("Delete Local service?", isPresented: $confirmDeleteLocalService) {
                Button("Delete", role: .destructive) {
                    Task { await deleteLocalService() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Permanently deletes this service's editable source from Local. Website sign-ins and data are kept.")
            }
            .alert("Couldn't delete Local service", isPresented: Binding(
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
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                header
                descriptionSection
                actionsSection
                domainSection
                repositorySection
                manageSection
            }
            .settingsPagePadding()
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
                    .accessibilityIdentifier(A11yID.ConversationControls.Attach.save(service.domain))

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
        .fullScreenCover(isPresented: $showPageInspector) {
            NavigationStack {
                ServicePageInspector(service: service, browserSessionID: browserSessionID)
            }
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
                Task {
                    await serviceManager.removeRemoteMCP(service)
                    dismiss()
                }
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
        .task(id: service.id) {
            _ = await service.loadManifest(reason: .serviceDetail)
            guard !Task.isCancelled else { return }
            await service.checkAccess(reason: .serviceDetail)
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
            if signInRequestActive || service.auth == .unknown || service.auth.isChecking {
                signInButton(signingIn: true)
                    .accessibilityIdentifier(A11yID.ConversationControls.Attach.signInProgress(service.domain))
            } else {
                switch service.signInState {
                case .signedOut, .notAuthorized, .unknown:
                    let signingIn = service.auth.isSigningIn
                    signInButton(signingIn: signingIn)
                        .accessibilityIdentifier(
                            signingIn
                                ? A11yID.ConversationControls.Attach.signInProgress(service.domain)
                                : A11yID.ConversationControls.Attach.signIn(service.domain)
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
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.signOutProgress(service.domain))
                    } else {
                        Button("Sign out") { Task { await signOut() } }
                            .buttonStyle(OxChipButton(filled: false, secondaryFill: colorScheme == .light ? Theme.Colors.surface : Theme.Colors.chipOnBackground))
                            .accessibilityIdentifier(A11yID.ConversationControls.Attach.signOut(service.domain))
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
                .accessibilityIdentifier(A11yID.ConversationControls.Attach.signIn(service.domain))
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
            guard !signInRequestActive else { return }
            signInRequestActive = true
            Task { @MainActor in
                defer { signInRequestActive = false }
                try? await service.requestAccess(using: presentations, source: .serviceDetail)
            }
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
            try await service.requestAccess()
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
                shape: .roundedRect(Theme.Radius.lg)
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
                        withAnimation(Theme.Animation.quick) { descriptionExpanded.toggle() }
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
            SettingsSection {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    Text(service.isMCPService ? "Endpoint" : "Domain")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Spacer(minLength: 0)
                    Text(verbatim: service.isMCPService ? service.url : service.domain)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.domain(service.domain))
                }
            }
        }
    }

    private var repository: Repository.Descriptor? {
        guard let repositoryID = service.definition.repositoryID else { return nil }
        return serviceManager.repositories.first { $0.id == repositoryID }
    }

    @ViewBuilder
    private var repositorySection: some View {
        if let repository {
            SettingsSection(layout: .row) {
                NavigationLink {
                    RepositoryDetailView(repositoryID: repository.id)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        Text("Repository")
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(verbatim: repository.name)
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .lineLimit(1)
                            if let status = repositoryStatus(repository) {
                                Text(verbatim: status)
                                    .font(Theme.Fonts.bodySm)
                                    .foregroundStyle(Theme.Colors.conversationSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(Theme.Icons.xs)
                            .foregroundStyle(Theme.Colors.conversationSecondary)
                    }
                    .settingsRowPadding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.ConversationControls.Attach.repository(service.domain))
            }
        }
    }

    private func repositoryStatus(_ repository: Repository.Descriptor) -> String? {
        if repository.provenance == .bundled { return String(localized: "Included with Ox") }
        if repository.provenance == .local { return nil }
        guard let date = repository.lastSyncedAt else { return String(localized: "Last sync unavailable") }
        return String(localized: "Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.headerSpacing) {
            Text("Actions")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .settingsSectionHeaderInset()

            servicePolicyContent
            attachActionContent

            if loadingManifest {
                CellularAutomatonLoader.small
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.lg)
            } else if actions.isEmpty {
                Text("This service provides no actions.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsContentInset()
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(actions) { action in
                        actionRow(action)
                    }
                }
            }
        }
    }

    // MARK: - Manage

    private var actionPolicySource: String {
        ActionPolicyConfiguration.sourceID(forServiceNamespace: service.definition.actionNamespace)
    }

    private var servicePolicyContent: some View {
        ActionPolicyPicker(
            title: "Default for This Service",
            selection: serviceManager.sourcePolicy(for: actionPolicySource),
            resolved: serviceManager.resolvedSourcePolicy(for: actionPolicySource),
            inheritLabel: "Use Global Default",
            onChange: { serviceManager.setSourcePolicy($0, for: actionPolicySource) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsRowPadding()
        .settingsSurface(singleRow: true)
    }

    private var attachActionContent: some View {
        actionCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Attach to a conversation")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                    Spacer(minLength: 0)
                    approvalControl(actionID: Conversation.attachApproveKey(service.domain), defaultPolicy: Actions.defaultPolicy(for: Actions.serviceAttach))
                }
                Divider().padding(.vertical, 4)
                Text(attachPermissionDescription)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var attachPermissionDescription: LocalizedStringKey {
        switch capabilities.attachmentData {
        case .signedIn: "Adds this service to a conversation, giving Ox its actions and your signed-in data."
        case .onDevice: "Its actions and permitted device data become available to this conversation."
        case .remote: "Its remote Actions can receive arguments from this conversation and return data to Ox."
        }
    }

    private var permissionButton: some View {
        Button(LocalizedStringKey(service.accessActionLabel)) {
            Task { try? await service.requestAccess() }
        }
        .buttonStyle(OxChipButton(filled: service.auth == .authorizationRequired))
        .disabled(service.auth == .unknown || service.auth.isUnavailable)
        .accessibilityIdentifier(A11yID.ConversationControls.Attach.devicePermission(service.domain))
    }

    @ViewBuilder
    private var manageSection: some View {
        if canInspectPage || service.isLocalService {
            SettingsSection(layout: .group) {
                VStack(spacing: 0) {
                    if canInspectPage {
                        manageRow("Inspect service page", tint: AnyShapeStyle(Theme.Colors.onSurface)) {
                            inspectPage()
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.inspectPage(service.domain))
                    }
                    if service.isLocalService {
                        if canInspectPage {
                            Divider().settingsContentInset()
                        }
                        ShareLink(
                            item: ServicePackageDocument(domain: service.domain, manager: serviceManager),
                            preview: SharePreview(Text(verbatim: service.title))
                        ) {
                            Text("Share Service")
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .settingsRowPadding()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.shareLocalService(service.domain))
                    }
                }
            }
        }
        if capabilities.supportsWebsiteDataManagement {
            SettingsSection(layout: .row) {
                manageRow("Clear website data", tint: AnyShapeStyle(Theme.Colors.error), role: .destructive) {
                    confirmClearWebData = true
                }
                .accessibilityIdentifier(A11yID.ConversationControls.Attach.clearWebData(service.domain))
            }
        }
        if capabilities.supportsRemoteManagement || service.isLocalService {
            SettingsSection(layout: .group) {
                VStack(spacing: 0) {
                    if capabilities.supportsRemoteManagement {
                        manageRow("Remove MCP server", tint: AnyShapeStyle(Theme.Colors.error), role: .destructive) {
                            confirmRemoveMCP = true
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.disconnectMCP(service.domain))
                    }
                    if service.isLocalService {
                        if capabilities.supportsRemoteManagement {
                            Divider().settingsContentInset()
                        }
                        manageRow("Delete Local service", tint: AnyShapeStyle(Theme.Colors.error), role: .destructive) {
                            confirmDeleteLocalService = true
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.deleteLocalService(service.domain))
                    }
                }
            }
        }
    }

    private var canInspectPage: Bool {
        capabilities.supportsPageInspection
    }

    private func inspectPage() {
        showPageInspector = true
    }

    private func manageRow(_ label: LocalizedStringKey, tint: AnyShapeStyle, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(label)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowPadding()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionRow(_ action: Manifest.Action) -> some View {
        let isStandard = service.definition.isStandardAction(action.id)
        return actionCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(action.label)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.action(action.id))
                    Spacer(minLength: 0)
                    if !isStandard {
                        approvalControl(
                            actionID: service.definition.qualifiedActionName(action.id),
                            defaultPolicy: action.requireApproval ? .ask : .allow
                        )
                    }
                }
                if let desc = action.description, !desc.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text(desc)
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isStandard || action.requireAuth {
                    HStack(spacing: Theme.Spacing.sm) {
                        if isStandard { chip("Standard") }
                        if action.requireAuth { chip("Authenticated") }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func approvalControl(actionID: String, defaultPolicy: ActionPolicy) -> some View {
        let explicit = serviceManager.explicitActionPolicy(for: actionID)
        ActionPolicyPicker(
            title: nil,
            selection: explicit,
            resolved: serviceManager.actionPolicy(for: actionID, default: defaultPolicy),
            inheritLabel: "Use Service Default",
            onChange: { serviceManager.setActionPolicy($0, for: actionID) }
        )
        .accessibilityIdentifier(A11yID.ConversationControls.Attach.actionApproval(actionID))
    }

    private func actionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowPadding()
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
