import SwiftUI

struct AgentSettingsView: View {
    @State private var addingAgent = false
    @State private var pendingRemoval: RemoteAgent?
    @State private var errorMessage: String?
    private var directory: RemoteAgentDirectory { .shared }
    private var registry: ProviderRegistry { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection(
                    footer: "New conversations use the default agent. Current Device runs Ox on this device. Add pi running on another computer with `ox agent serve`, using its Tailscale name such as my-mac.tailnet.ts.net. It keeps Ox's tools and context. Long-press an agent to remove it.",
                    layout: .group
                ) {
                    VStack(spacing: 0) {
                        Button { setDefault(nil) } label: {
                            row(title: Text("Current Device"), subtitle: L10n.string("Built in"), selected: directory.defaultEndpoint == nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(directory.defaultEndpoint == nil ? .isSelected : [])
                        .accessibilityIdentifier(A11yID.Settings.agentRow("local"))
                        ForEach(directory.agents) { agent in
                            Divider().settingsContentInset()
                            remoteRow(agent)
                        }
                        Divider().settingsContentInset()
                        Button { addingAgent = true } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "plus").foregroundStyle(Theme.Colors.primary)
                                Text("Add Remote Agent")
                                    .font(Theme.Fonts.bodyMd)
                                    .foregroundStyle(Theme.Colors.primary)
                                Spacer(minLength: 0)
                            }
                            .settingsRowPadding()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.agentAdd)
                    }
                }
                if directory.defaultEndpoint == nil {
                    SettingsSection(
                        footer: "Used for new conversations on this device. Existing conversations keep their model.",
                        layout: .row
                    ) {
                        NavigationLink {
                            ModelPickerContent(
                                title: "Default model",
                                activeSelection: registry.sessionModel,
                                scopeDescription: "Changes apply immediately to new conversations. Existing conversations keep their model."
                            ) { client, model, selection in
                                Log.ui.info("Settings.defaultModel client=\(client.id) model=\(model.id) region=\(selection.region.rawValue)")
                                registry.select(model, in: client.id, region: selection.region)
                            }
                        } label: {
                            SettingsDisclosureRow(title: "Model", value: DefaultAgentValue.model(registry))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(A11yID.Settings.defaultModel)
                    }
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
        .navigationTitle("Default Agent")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await directory.refreshAll() }
        .task(id: directory.agents.map(\.id)) { await directory.refreshAll() }
        .sheet(isPresented: $addingAgent) { RemoteAgentCreationSheet() }
        .confirmationDialog(
            "Remove this agent?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { agent in
            Button("Remove", role: .destructive) {
                do { try directory.remove(agent.endpoint) } catch { errorMessage = error.localizedDescription }
            }
            .accessibilityIdentifier(A11yID.Settings.agentRemoveConfirm)
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text("Conversations that use it stay in Ox but can't continue until it's added again.\n\(agent.endpoint.absoluteString)")
        }
        .errorAlert("Couldn't Change Agents", message: $errorMessage)
    }

    private func setDefault(_ endpoint: URL?) {
        guard endpoint != directory.defaultEndpoint else { return }
        do {
            try directory.setDefault(endpoint)
            Log.ui.info("Settings.defaultAgent endpoint=\(endpoint.map { LogPrivacy.url($0.absoluteString) } ?? "local")")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remoteRow(_ agent: RemoteAgent) -> some View {
        Button { setDefault(agent.endpoint) } label: {
            row(title: Text(verbatim: agent.name),
                subtitle: "\(subtitle(directory.statuses[agent.endpoint])) · \(agent.endpoint.absoluteString)",
                selected: directory.defaultEndpoint == agent.endpoint)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(directory.defaultEndpoint == agent.endpoint ? .isSelected : [])
        .contextMenu {
            Button(role: .destructive) { pendingRemoval = agent } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityIdentifier(A11yID.Settings.agentRemove(agent.endpoint.absoluteString))
        }
        .accessibilityIdentifier(A11yID.Settings.agentRow(agent.endpoint.absoluteString))
        .accessibilityAction(named: Text("Remove")) { pendingRemoval = agent }
    }

    private func subtitle(_ status: RemoteAgentStatus?) -> String {
        switch status {
        case .online(let implementation, let version, let machine, _):
            return L10n.string("Reachable · \(implementation) \(version) · \(machine)")
        case .offline: return L10n.string("Unavailable")
        case .checking, nil: return L10n.string("Checking…")
        }
    }

    private func row(title: Text, subtitle: String, selected: Bool) -> some View {
        HStack(spacing: SettingsLayout.horizontalInset) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                Text(verbatim: subtitle)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.Colors.primary)
            }
        }
        .padding(.horizontal, SettingsLayout.horizontalInset)
        .padding(.vertical, SettingsLayout.rowVerticalInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct RemoteAgentCreationSheet: View {
    var onAdded: (URL) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var errorMessage: String?

    private var endpoint: URL? { RemoteAgentDirectory.endpoint(from: address) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: SettingsLayout.sectionSpacing) {
                    SettingsSection(
                        footer: "Run `ox agent serve` on the computer, then enter the address it prints, or just its Tailscale name. Tailscale names use wss:// and port 9878 by default.",
                        layout: .group
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Name", text: $name)
                                .settingsRowPadding()
                                .accessibilityIdentifier(A11yID.Settings.agentAddName)
                            Divider().settingsContentInset()
                            TextField("my-mac.tailnet.ts.net", text: $address)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .settingsRowPadding()
                                .accessibilityIdentifier(A11yID.Settings.agentAddEndpoint)
                        }
                    }
                }
                .settingsPagePadding()
            }
            .background(Theme.Colors.background)
            .navigationTitle("Add Remote Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier(A11yID.Settings.agentAddCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(endpoint == nil)
                        .accessibilityIdentifier(A11yID.Settings.agentAddConfirm)
                }
            }
            .errorAlert("Couldn't Add Agent", message: $errorMessage)
        }
    }

    private func add() {
        guard let endpoint else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try RemoteAgentDirectory.shared.add(name: trimmed.isEmpty ? endpoint.host() ?? endpoint.absoluteString : trimmed, endpoint: endpoint)
            onAdded(endpoint)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum DefaultAgentValue {
    @MainActor
    static func model(_ registry: ProviderRegistry) -> Text {
        guard let selection = registry.defaultModel else { return Text("Not configured") }
        let client = registry.client(for: selection)
        return Text(verbatim: registry.model(for: selection, client: client).displayName)
    }
}

struct DefaultAgentSettingsSection: View {
    private var directory: RemoteAgentDirectory { .shared }
    private var registry: ProviderRegistry { .shared }

    private var value: Text {
        guard let endpoint = directory.defaultEndpoint else { return Text("Current Device · \(DefaultAgentValue.model(registry))") }
        let name = directory.displayName(for: endpoint)
        guard let model = directory.model(nil, endpoint: endpoint) else { return Text(verbatim: name) }
        return Text(verbatim: "\(name) · \(model.name)")
    }

    var body: some View {
        SettingsSection(footer: "Used for new conversations. Existing conversations keep their agent and model.", layout: .row) {
            NavigationLink { AgentSettingsView() } label: {
                SettingsDisclosureRow(title: "Default agent", value: value)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11yID.Settings.defaultAgent)
        }
    }
}
