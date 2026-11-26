import SwiftUI

struct AgentPickerSheet: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    private var registry: ProviderRegistry { .shared }
    private var agents: RemoteAgentDirectory { .shared }
    private var isChoosingInitialDefault: Bool { registry.defaultModel == nil }

    var body: some View {
        NavigationStack {
            if let binding = conversation.remoteAgent {
                RemoteAgentModelPicker(conversation: conversation, endpoint: binding.endpoint, onClose: { dismiss() }) {
                    AgentSelectionGroup(conversation: conversation)
                }
            } else {
                ModelPickerContent(
                    title: isChoosingInitialDefault ? "Choose default model" : "Model for this conversation",
                    activeSelection: conversation.modelSelectionChange?.pendingSelection ?? conversation.modelSelection,
                    scopeDescription: isChoosingInitialDefault
                        ? "Your choice will be used for this conversation and future conversations."
                        : conversation.isBusy
                            ? "Changes apply after the current response and stay with this conversation."
                            : "Changes apply immediately and stay with this conversation.",
                    header: agents.agents.isEmpty ? nil : AnyView(AgentSelectionGroup(conversation: conversation)),
                    onClose: { dismiss() }
                ) { client, model, selection in
                    if registry.defaultModel == nil {
                        registry.select(model, in: client.id, region: selection.region)
                    }
                    let status = conversation.requestModelSelection(.init(client: client, model: model))
                    Log.ui.info("AgentPicker.select conversation=\(conversation.id) client=\(client.id) model=\(model.id) region=\(selection.region.rawValue) status=\(status)")
                }
            }
        }
        .task { await agents.refreshAll() }
    }
}

struct AgentSelectionGroup: View {
    let conversation: Conversation
    private var agents: RemoteAgentDirectory { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(spacing: 0) {
                Menu {
                    Button { select(nil) } label: {
                        Label { Text("Ox") } icon: { if conversation.remoteAgent == nil { Image(systemName: "checkmark") } }
                    }
                    .accessibilityIdentifier(A11yID.ConversationControls.agentOption("local"))
                    ForEach(agents.agents) { agent in
                        Button { select(agent.endpoint) } label: {
                            Label {
                                Text(verbatim: agent.name)
                                Text(verbatim: subtitle(agent))
                            } icon: {
                                if conversation.remoteAgent?.endpoint == agent.endpoint { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(agents.statuses[agent.endpoint]?.isOnline != true)
                        .accessibilityIdentifier(A11yID.ConversationControls.agentOption(agent.name))
                    }
                } label: {
                    SettingsDisclosureRow(title: "Agent", value: Text(verbatim: conversation.remoteAgentName ?? "Ox"),
                                          indicator: conversation.canChangeAgent ? "chevron.up.chevron.down" : nil)
                }
                .disabled(!conversation.canChangeAgent)
                .accessibilityIdentifier(A11yID.ConversationControls.agentMenu)
            }
            .settingsSurface()
            if !conversation.canChangeAgent {
                Text("Start a new conversation to change agent.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsContentInset()
            }
        }
    }

    private func subtitle(_ agent: RemoteAgent) -> String {
        switch agents.statuses[agent.endpoint] {
        case .online(_, _, let machine, let folder):
            [machine, URL(fileURLWithPath: folder).lastPathComponent].filter { !$0.isEmpty }.joined(separator: " · ")
        case .offline: String(localized: "Offline")
        case .checking, nil: String(localized: "Checking…")
        }
    }

    private func select(_ endpoint: URL?) {
        let selected = conversation.selectAgent(endpoint)
        Log.ui.info("AgentPicker.agent conversation=\(conversation.id) agent=\(endpoint?.absoluteString ?? "local") selected=\(selected)")
    }
}

struct RemoteAgentModelPicker<Header: View>: View {
    let conversation: Conversation
    let endpoint: URL
    let onClose: () -> Void
    @ViewBuilder let header: () -> Header
    private var agents: RemoteAgentDirectory { .shared }

    private var models: [RemoteAgentModel] { agents.models[endpoint] ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                Text("Runs on \(agents.machine(for: endpoint) ?? agents.displayName(for: endpoint)) with its own tools, plus Ox's tools and context.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .settingsContentInset()
                header()
                VStack(spacing: 0) {
                    Menu {
                        ForEach(models) { model in
                            Button { conversation.selectRemoteModel(model) } label: {
                                Label { Text(verbatim: model.name); Text(verbatim: model.reference.provider) } icon: {
                                    if selected == model.reference { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        SettingsDisclosureRow(title: "Model", value: Text(verbatim: conversation.remoteModelName ?? String(localized: "Agent default")),
                                              isLoading: agents.statuses[endpoint] == .checking && models.isEmpty,
                                              indicator: "chevron.up.chevron.down")
                    }
                    .disabled(models.isEmpty)
                    .accessibilityIdentifier(A11yID.ConversationControls.agentModelMenu)
                }
                .settingsSurface()
                if case .offline(let error) = agents.statuses[endpoint] {
                    SettingsErrorMessage(message: String(localized: "\(agents.displayName(for: endpoint)) is offline: \(error)"),
                                         systemImage: "exclamationmark.circle.fill")
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background, ignoresSafeAreaEdges: .all)
        .navigationTitle("Agent for this conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                SheetDismissToolbarButton(accessibilityIdentifier: A11yID.ConversationControls.modelClose, action: onClose)
            }
        }
    }

    private var selected: AgentModelReference? {
        conversation.remoteAgent?.model ?? agents.defaultModels[endpoint]
    }
}
