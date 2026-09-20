import SwiftUI

extension ActionPolicy {
    var title: LocalizedStringKey {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .block: "Block"
        }
    }

    var systemImage: String {
        switch self {
        case .ask: "questionmark.circle"
        case .allow: "checkmark.circle"
        case .block: "nosign"
        }
    }
}

struct ActionPolicyPicker: View {
    let title: LocalizedStringKey?
    let selection: ActionPolicy?
    let resolved: ActionPolicy
    let inheritLabel: LocalizedStringKey?
    let onChange: (ActionPolicy?) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let title {
                Text(title)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                Spacer(minLength: 0)
            }
            Menu {
                if let inheritLabel {
                    Button {
                        onChange(nil)
                    } label: {
                        policyOption(inheritLabel, selected: selection == nil)
                    }
                    Divider()
                }
                ForEach(ActionPolicy.allCases) { policy in
                    Button {
                        onChange(policy)
                    } label: {
                        policyOption(policy.title, selected: selection == policy)
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: resolved.systemImage)
                    Text(resolved.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.primary)
            }
        }
    }

    private func policyOption(_ label: LocalizedStringKey, selected: Bool) -> some View {
        HStack {
            Text(label)
            if selected { Image(systemName: "checkmark") }
        }
    }
}

struct ActionSettingsView: View {
    @Environment(ServiceManager.self) private var serviceManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection(
                    "Default",
                    footer: "Ask shows a confirmation before an Action runs. Allow runs it automatically. Block prevents it from running. More specific choices override this default."
                ) {
                    ActionPolicyPicker(
                        title: "All Actions",
                        selection: serviceManager.defaultActionPolicy,
                        resolved: serviceManager.defaultActionPolicy,
                        inheritLabel: nil,
                        onChange: { policy in
                            if let policy { serviceManager.defaultActionPolicy = policy }
                        }
                    )
                }

                SettingsSection("Actions", insetContent: false) {
                    VStack(spacing: 0) {
                        NavigationLink {
                            BuiltInActionSettingsView()
                        } label: {
                            builtInRow
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.builtInActions)

                        ForEach(serviceManager.services) { service in
                            Divider().settingsContentInset()
                            NavigationLink {
                                ServiceActionSettingsView(service: service)
                            } label: {
                                serviceRow(service)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Actions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var builtInRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image("OxIcon")
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            Text("Built into Ox")
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            Text(serviceManager.resolvedSourcePolicy(for: "ox").title)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }

    private func serviceRow(_ service: Service) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ServiceAvatar(service: service, size: 32, shape: .roundedRect(Theme.Radius.sm))
            Text(verbatim: service.title)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            Text(serviceManager.resolvedSourcePolicy(for: ActionPolicyConfiguration.sourceID(forServiceNamespace: service.definition.actionNamespace)).title)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }
}

struct BuiltInActionSettingsView: View {
    @Environment(ServiceManager.self) private var serviceManager

    private var actions: [String] {
        Actions.builtIn.filter { !OxFileSystem.actions.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection("Default for Ox Actions") {
                    ActionPolicyPicker(
                        title: "All Built-in Actions",
                        selection: serviceManager.sourcePolicy(for: "ox"),
                        resolved: serviceManager.resolvedSourcePolicy(for: "ox"),
                        inheritLabel: "Use Global Default",
                        onChange: { serviceManager.setSourcePolicy($0, for: "ox") }
                    )
                }

                SettingsSection("Actions", insetContent: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                            if index > 0 { Divider().settingsContentInset() }
                            actionRow(action)
                        }
                    }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Built into Ox")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func actionRow(_ action: String) -> some View {
        let explicit = serviceManager.explicitActionPolicy(for: action)
        return HStack(spacing: Theme.Spacing.sm) {
            Text(Actions.label(for: action) ?? action)
                .font(Theme.Fonts.bodyMd)
                .foregroundStyle(Theme.Colors.onSurface)
            Spacer(minLength: 0)
            ActionPolicyPicker(
                title: nil,
                selection: explicit,
                resolved: serviceManager.actionPolicy(for: action),
                inheritLabel: "Use Default",
                onChange: { serviceManager.setActionPolicy($0, for: action) }
            )
        }
        .settingsRowPadding()
    }
}

struct ServiceActionSettingsView: View {
    let service: Service
    @Environment(ServiceManager.self) private var serviceManager

    private var source: String {
        ActionPolicyConfiguration.sourceID(forServiceNamespace: service.definition.actionNamespace)
    }
    private var actions: [Manifest.Action] { service.definition.exposedActions }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection("Default for This Service") {
                    ActionPolicyPicker(
                        title: "All Service Actions",
                        selection: serviceManager.sourcePolicy(for: source),
                        resolved: serviceManager.resolvedSourcePolicy(for: source),
                        inheritLabel: "Use Global Default",
                        onChange: { serviceManager.setSourcePolicy($0, for: source) }
                    )
                }

                SettingsSection("Actions", insetContent: false) {
                    VStack(spacing: 0) {
                        serviceActionRow(
                            title: String(localized: "Attach to a chat"),
                            actionID: Chat.attachApproveKey(service.domain)
                        )
                        if service.detailCapabilities.supportsFolderAccess {
                            ForEach(OxFileSystem.actions, id: \.self) { action in
                                Divider().settingsContentInset()
                                serviceActionRow(title: Actions.label(for: action) ?? action, actionID: action)
                            }
                        } else {
                            ForEach(actions) { action in
                                Divider().settingsContentInset()
                                serviceActionRow(
                                    title: action.label,
                                    actionID: service.definition.qualifiedActionName(action.id)
                                )
                            }
                        }
                    }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(service.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: service.id) {
            _ = await service.loadManifest(reason: .serviceDetail)
        }
    }

    private func serviceActionRow(title: String, actionID: String) -> some View {
        let explicit = serviceManager.explicitActionPolicy(for: actionID)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: title)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Spacer(minLength: 0)
                ActionPolicyPicker(
                    title: nil,
                    selection: explicit,
                    resolved: serviceManager.actionPolicy(for: actionID),
                    inheritLabel: "Use Service Default",
                    onChange: { serviceManager.setActionPolicy($0, for: actionID) }
                )
            }
        }
        .settingsRowPadding()
    }
}
