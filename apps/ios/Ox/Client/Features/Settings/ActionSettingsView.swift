import SwiftUI

extension ActionPolicy {
    var title: LocalizedStringKey {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .block: "Block"
        }
    }
}

struct ActionPolicyPicker: View {
    let title: LocalizedStringKey?
    let selection: ActionPolicy?
    let resolved: ActionPolicy?
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
                    Text(resolved?.title ?? "Default")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
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
                    footer: "By default, built-in Ox Actions are allowed except deletion. Services and devices use their declared defaults. Ask, Allow, or Block overrides that behavior for all Actions. More specific choices take priority."
                ) {
                    ActionPolicyPicker(
                        title: "All Actions",
                        selection: serviceManager.defaultActionPolicy,
                        resolved: serviceManager.defaultActionPolicy,
                        inheritLabel: "Use Default",
                        onChange: { serviceManager.defaultActionPolicy = $0 }
                    )
                }

                SettingsSection("Actions", layout: .group) {
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
        .navigationTitle("Permissions")
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
            Text(serviceManager.resolvedSourcePolicy(for: "ox")?.title ?? "Default")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Image(systemName: "chevron.right")
                .font(Theme.Icons.xs)
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
            Text(serviceManager.resolvedSourcePolicy(for: ActionPolicyConfiguration.sourceID(forServiceNamespace: service.definition.actionNamespace))?.title ?? "Default")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            Image(systemName: "chevron.right")
                .font(Theme.Icons.xs)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .settingsRowPadding()
        .contentShape(Rectangle())
    }
}

private enum BuiltInActionGroup: String, CaseIterable, Identifiable {
    case chats, models, web, artifacts, memory, skills, services, repositories, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .chats: "Chats"
        case .models: "Models & secrets"
        case .web: "Web & browser"
        case .artifacts: "Artifacts & images"
        case .memory: "Memory"
        case .skills: "Skills & schedules"
        case .services: "Services"
        case .repositories: "Repositories"
        case .settings: "App settings"
        }
    }

    var actions: [String] {
        Actions.builtIn.filter {
            !OxFileSystem.actions.contains($0) && Self.group(for: $0) == self
        }
    }

    private static func group(for action: String) -> Self {
        switch action {
        case Actions.appRenameChat: return .chats
        case Actions.appModel, Actions.appDefaultModel: return .models
        case Actions.appRepositories: return .repositories
        case Actions.outputRead: return .artifacts
        default: break
        }
        // Group by user-facing feature, not by permission policy or storage source.
        return switch action.split(separator: ".").dropFirst().first {
        case "chat", "user": .chats
        case "provider", "secret": .models
        case "web": .web
        case "artifact", "vision", "widget": .artifacts
        case "memory": .memory
        case "skill", "schedule": .skills
        case "service": .services
        case "repository": .repositories
        default: .settings
        }
    }
}

struct BuiltInActionSettingsView: View {
    @Environment(ServiceManager.self) private var serviceManager

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

                SettingsSection("Categories", layout: .group) {
                    VStack(spacing: 0) {
                        ForEach(Array(BuiltInActionGroup.allCases.enumerated()), id: \.element) { index, group in
                            if index > 0 { Divider().settingsContentInset() }
                            NavigationLink {
                                BuiltInActionGroupSettingsView(group: group)
                            } label: {
                                SettingsDisclosureRow(title: group.title, value: Text(""))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.actions.group.\(group.rawValue)")
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
}

private struct BuiltInActionGroupSettingsView: View {
    let group: BuiltInActionGroup
    @Environment(ServiceManager.self) private var serviceManager

    var body: some View {
        ScrollView {
            SettingsSection("Actions", layout: .group) {
                VStack(spacing: 0) {
                    ForEach(Array(group.actions.enumerated()), id: \.element) { index, action in
                        if index > 0 { Divider().settingsContentInset() }
                        actionRow(action)
                    }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle(group.title)
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
                resolved: serviceManager.actionPolicy(for: action, default: Actions.defaultPolicy(for: action)),
                inheritLabel: "Use Default",
                onChange: { serviceManager.setActionPolicy($0, for: action) }
            )
        }
        .settingsRowPadding()
        .accessibilityIdentifier("settings.actions.action.\(action)")
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

                SettingsSection("Actions", layout: .group) {
                    VStack(spacing: 0) {
                        serviceActionRow(
                            title: String(localized: "Attach to a chat"),
                            actionID: Chat.attachApproveKey(service.domain),
                            defaultPolicy: Actions.defaultPolicy(for: Actions.serviceAttach)
                        )
                        if service.detailCapabilities.supportsFolderAccess {
                            ForEach(OxFileSystem.actions, id: \.self) { action in
                                Divider().settingsContentInset()
                                serviceActionRow(
                                    title: Actions.label(for: action) ?? action,
                                    actionID: action,
                                    defaultPolicy: Actions.defaultPolicy(for: action)
                                )
                            }
                        } else {
                            ForEach(actions) { action in
                                Divider().settingsContentInset()
                                serviceActionRow(
                                    title: action.label,
                                    actionID: service.definition.qualifiedActionName(action.id),
                                    defaultPolicy: action.requireApproval ? .ask : .allow
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

    private func serviceActionRow(title: String, actionID: String, defaultPolicy: ActionPolicy) -> some View {
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
                    resolved: serviceManager.actionPolicy(for: actionID, default: defaultPolicy),
                    inheritLabel: "Use Service Default",
                    onChange: { serviceManager.setActionPolicy($0, for: actionID) }
                )
            }
        }
        .settingsRowPadding()
    }
}
