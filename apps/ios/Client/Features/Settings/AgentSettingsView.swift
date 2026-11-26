import SwiftUI

struct AgentSettingsView: View {
    @State private var addingAgent = false
    @State private var pendingRemoval: RemoteAgent?
    @State private var errorMessage: String?
    private var directory: RemoteAgentDirectory { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                SettingsSection(
                    footer: "Ox runs conversations on this device by default. Add pi running on another computer with `ox agent serve`, such as ws://my-mac.tailnet.ts.net:9877. It keeps Ox's tools and context. Long-press an agent to remove it.",
                    layout: .group
                ) {
                    VStack(spacing: 0) {
                        row(title: Text("Ox"), subtitle: L10n.string("Built in"))
                            .accessibilityElement(children: .combine)
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
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
        .navigationTitle("Agents")
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
        .errorAlert("Couldn't Remove Agent", message: $errorMessage)
    }

    private func remoteRow(_ agent: RemoteAgent) -> some View {
        row(title: Text(verbatim: agent.name), subtitle: "\(subtitle(directory.statuses[agent.endpoint])) · \(agent.endpoint.absoluteString)")
            .accessibilityElement(children: .combine)
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
        case .online(let implementation, let version, let machine, let folder):
            let place = [machine, URL(fileURLWithPath: folder).lastPathComponent].filter { !$0.isEmpty }.joined(separator: " · ")
            return L10n.string("Reachable · \(implementation) \(version) · \(place)")
        case .offline: return L10n.string("Unavailable")
        case .checking, nil: return L10n.string("Checking…")
        }
    }

    private func row(title: Text, subtitle: String) -> some View {
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
        }
        .padding(.horizontal, SettingsLayout.horizontalInset)
        .padding(.vertical, SettingsLayout.rowVerticalInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct RemoteAgentCreationSheet: View {
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
                        footer: "Run `ox agent serve` on the computer, then use its ws:// or wss:// address. ws:// uses port 9877 when none is given.",
                        layout: .group
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Name", text: $name)
                                .settingsRowPadding()
                                .accessibilityIdentifier(A11yID.Settings.agentAddName)
                            Divider().settingsContentInset()
                            TextField("ws://my-mac.tailnet.ts.net:9877", text: $address)
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AgentSettingsSection: View {
    @State private var errorMessage: String?
    private var directory: RemoteAgentDirectory { .shared }

    var body: some View {
        SettingsSection(footer: "Run conversations on pi on another computer. New conversations use the default agent.", layout: .group) {
            VStack(spacing: 0) {
                NavigationLink { AgentSettingsView() } label: {
                    SettingsDisclosureRow(title: "Agents", value: Text(directory.agents.isEmpty ? "Ox" : "\(directory.agents.count + 1) agents"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Settings.agents)
                if !directory.agents.isEmpty {
                    Divider().settingsContentInset()
                    Menu {
                        Button("Ox") { setDefault(nil) }
                        ForEach(directory.agents) { agent in
                            Button { setDefault(agent.endpoint) } label: { Text(verbatim: agent.name) }
                        }
                    } label: {
                        SettingsDisclosureRow(title: "Default agent",
                                              value: Text(verbatim: directory.defaultEndpoint.map(directory.displayName(for:)) ?? "Ox"),
                                              indicator: "chevron.up.chevron.down")
                    }
                    .accessibilityIdentifier(A11yID.Settings.defaultAgent)
                }
            }
        }
        .errorAlert("Couldn't Change Default Agent", message: $errorMessage)
    }

    private func setDefault(_ endpoint: URL?) {
        do { try directory.setDefault(endpoint) } catch { errorMessage = error.localizedDescription }
    }
}
