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
                    header: conversation.canChangeAgent || !agents.agents.isEmpty ? AnyView(AgentSelectionGroup(conversation: conversation)) : nil,
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
    @State private var addingAgent = false
    private var agents: RemoteAgentDirectory { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(spacing: 0) {
                Menu {
                    Button { select(nil) } label: {
                        Label { Text("Current Device") } icon: { if conversation.remoteAgent == nil { Image(systemName: "checkmark") } }
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
                        .accessibilityIdentifier(A11yID.ConversationControls.agentOption(agent.name))
                    }
                    Divider()
                    Button { addingAgent = true } label: {
                        Label("Add Remote Agent…", systemImage: "plus")
                    }
                    .accessibilityIdentifier(A11yID.ConversationControls.agentAdd)
                } label: {
                    SettingsDisclosureRow(title: "Agent", value: conversation.remoteAgentName.map { Text(verbatim: $0) } ?? Text("Current Device"),
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
        .sheet(isPresented: $addingAgent) {
            RemoteAgentCreationSheet { endpoint in select(endpoint) }
        }
    }

    private func subtitle(_ agent: RemoteAgent) -> String {
        switch agents.statuses[agent.endpoint] {
        case .online(_, _, let machine, let folders):
            [machine, folders.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
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
                    NavigationLink {
                        SettingsSelectionPickerView(
                            title: "Model",
                            options: models.map { model in
                                SettingsSelectionOption(id: model.id, value: model.id, title: model.name, subtitle: model.reference.provider,
                                                        accessibilityIdentifier: A11yID.ConversationControls.modelOption(model.id))
                            },
                            selection: Binding(
                                get: { selected.map { "\($0.provider)/\($0.id)" } ?? "" },
                                set: { id in if let model = models.first(where: { $0.id == id }) { conversation.selectRemoteModel(model) } }
                            ),
                            searchAccessibilityIdentifier: A11yID.ConversationControls.modelSearch
                        )
                    } label: {
                        SettingsDisclosureRow(title: "Model", value: Text(verbatim: conversation.remoteModelName ?? String(localized: "Agent default")),
                                              isLoading: agents.statuses[endpoint] == .checking && models.isEmpty)
                    }
                    .buttonStyle(.plain)
                    .disabled(models.isEmpty)
                    .accessibilityIdentifier(A11yID.ConversationControls.agentModelMenu)
                    if let levels = selectedModel?.thinkingLevels, levels.count > 1 {
                        Divider().settingsContentInset()
                        Menu {
                            ForEach(levels, id: \.self) { level in
                                Button { conversation.selectRemoteThinking(level) } label: {
                                    Label { Text(verbatim: ModelPickerContent.thinkingLevelName(level)) } icon: {
                                        if level == conversation.remoteThinkingLevel { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityIdentifier(A11yID.ConversationControls.modelThinkingLevelOption(level))
                            }
                        } label: {
                            SettingsDisclosureRow(title: "Thinking level",
                                                  value: Text(verbatim: conversation.remoteThinkingLevel.map { ModelPickerContent.thinkingLevelName($0) } ?? String(localized: "Agent default")),
                                                  indicator: "chevron.up.chevron.down")
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.modelThinkingLevel)
                    }
                }
                .settingsSurface()
                if !agents.folders(for: endpoint).isEmpty || conversation.remoteAgent?.folder != nil {
                    VStack(spacing: 0) {
                        Menu {
                            Button { conversation.selectRemoteFolder(nil) } label: {
                                Label { Text("Own folder"); Text("A new folder for this conversation") } icon: {
                                    if selectedFolder == nil { Image(systemName: "checkmark") }
                                }
                            }
                            ForEach(agents.folders(for: endpoint), id: \.self) { folder in
                                Button { conversation.selectRemoteFolder(folder) } label: {
                                    Label { Text(verbatim: URL(fileURLWithPath: folder).lastPathComponent); Text(verbatim: folder) } icon: {
                                        if folder == selectedFolder { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            SettingsDisclosureRow(title: "Folder", value: selectedFolder.map { Text(verbatim: URL(fileURLWithPath: $0).lastPathComponent) } ?? Text("Own folder"),
                                                  indicator: conversation.canChangeAgent ? "chevron.up.chevron.down" : nil)
                        }
                        .disabled(!conversation.canChangeAgent)
                        .accessibilityIdentifier(A11yID.ConversationControls.agentFolderMenu)
                    }
                    .settingsSurface()
                }
                if agents.allowsShell(endpoint) {
                    VStack(spacing: 0) {
                        Menu {
                            ForEach(ShellAccess.allCases, id: \.self) { access in
                                Button { conversation.selectRemoteShell(access) } label: {
                                    Label { Text(Self.shellName(access)); Text(Self.shellDetail(access)) } icon: {
                                        if access == conversation.remoteAgent?.shell { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityIdentifier(A11yID.ConversationControls.agentShellOption(access.rawValue))
                            }
                        } label: {
                            SettingsDisclosureRow(title: "Shell", value: Text(conversation.remoteAgent?.shell.map { Self.shellName($0) } ?? "Agent default"),
                                                  indicator: "chevron.up.chevron.down")
                        }
                        .accessibilityIdentifier(A11yID.ConversationControls.agentShellMenu)
                    }
                    .settingsSurface()
                }
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

    private static func shellName(_ access: ShellAccess) -> LocalizedStringKey {
        switch access {
        case .off: "Off"
        case .ask: "Ask each time"
        case .on: "On"
        }
    }

    private static func shellDetail(_ access: ShellAccess) -> LocalizedStringKey {
        switch access {
        case .off: "Files only, no commands"
        case .ask: "Approve each command in Ox"
        case .on: "Run commands without asking"
        }
    }

    private var selectedFolder: String? {
        conversation.remoteAgent?.folder
    }

    private var selectedModel: RemoteAgentModel? {
        agents.model(selected, endpoint: endpoint)
    }

    private var selected: AgentModelReference? {
        conversation.remoteAgent?.model ?? agents.defaultModels[endpoint]
    }
}
