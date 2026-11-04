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

    private var service: Service {
        serviceManager.service(domain: initialService.domain) ?? initialService
    }

    private var capabilities: ServiceDetailCapabilities { service.detailCapabilities }

    private var actions: [Manifest.Action] { service.definition.actions }
    private var loadingManifest: Bool { service.capabilityState == .loading }
    @State private var confirmClearWebData = false
    @State private var showPageInspector = false
    @State private var mcpRemovalError: String?
    @State private var confirmRemoveMCP = false
    @State private var confirmDeleteLocalService = false
    @State private var localServiceDeleteError: String?

    var body: some View {
        content
            .alert("Delete Local service?", isPresented: $confirmDeleteLocalService) {
                Button("Delete", role: .destructive) {
                    Task { await deleteLocalService() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Permanently deletes this service's editable source from Local. Website logins and data are kept.")
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
            ToolbarItem(placement: .principal) {
                HStack(spacing: Theme.Spacing.sm) {
                    ServiceAvatar(service: service, size: 24, shape: .roundedRect(Theme.Radius.sm))
                        .accessibilityHidden(true)
                    Text(service.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                .accessibilityAddTraits(.isHeader)
            }
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
            Text("Removes cookies, cache, and stored data for \(service.title). You may need to log in again.")
        }
        .alert("Remove MCP server?", isPresented: $confirmRemoveMCP) {
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await serviceManager.removeRemoteMCP(service)
                        dismiss()
                    } catch {
                        Log.ui.error("ServiceDetail.removeMCP domain=\(service.domain) failed=\(error.localizedDescription)")
                        mcpRemovalError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this server, its discovered tools, and its local authorization from Ox. The server does not receive a revocation request.")
        }
        .alert("Couldn't remove MCP server", isPresented: Binding(
            get: { mcpRemovalError != nil },
            set: { if !$0 { mcpRemovalError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mcpRemovalError ?? "")
        }
        .task(id: service.id) {
            _ = await service.loadManifest(reason: .serviceDetail)
        }
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

    private var descriptionSection: some View {
        SettingsSection(layout: .group) {
            Group {
                if service.summary.isEmpty {
                    Text("No description.")
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                } else {
                    Text(service.summary)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsRowPadding()
        }
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
        case .signedIn: "Adds this service to a conversation, giving Ox its actions and your logged-in data."
        case .onDevice: "Its actions and permitted device data become available to this conversation."
        case .remote: "Its remote Actions can receive arguments from this conversation and return data to Ox."
        }
    }

    @ViewBuilder
    private var manageSection: some View {
        if canInspectPage || isLocalScriptService {
            SettingsSection(layout: .group) {
                VStack(spacing: 0) {
                    if canInspectPage {
                        manageRow("Inspect service page", tint: AnyShapeStyle(Theme.Colors.onSurface)) {
                            inspectPage()
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.inspectPage(service.domain))
                    }
                    if isLocalScriptService {
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
        if capabilities.supportsRemoteManagement || isLocalScriptService {
            SettingsSection(layout: .group) {
                VStack(spacing: 0) {
                    if capabilities.supportsRemoteManagement {
                        manageRow("Remove MCP server", tint: AnyShapeStyle(Theme.Colors.error), role: .destructive) {
                            confirmRemoveMCP = true
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.Attach.disconnectMCP(service.domain))
                    }
                    if isLocalScriptService {
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

    private var isLocalScriptService: Bool {
        service.isLocalService && !service.isMCPService
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
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
                    .padding(.top, SettingsLayout.rowVerticalInset - Theme.Spacing.xs)
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
