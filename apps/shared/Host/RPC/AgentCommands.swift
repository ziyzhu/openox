import Foundation

extension OxHostProtocol {
    struct AgentModelRow: Encodable {
        let provider: String
        let id: String
        let name: String
        let reasoning: Bool
    }

    struct AgentRow: Encodable {
        let name: String
        let endpoint: String
        let status: String
        let implementation: String?
        let version: String?
        let machine: String?
        let folder: String?
        let error: String?
        let models: [AgentModelRow]
    }

    struct ListAgentsResult: Encodable {
        let agents: [AgentRow]
    }

    struct AgentResult: Encodable {
        let agent: AgentRow
    }

    struct AgentConversationRow: Encodable {
        let id: String
        let title: String
        let cwd: String
        let state: String
        let origin: String
        let updatedAt: String
        let hostConversationId: String?
    }

    struct ListAgentConversationsResult: Encodable {
        let conversations: [AgentConversationRow]
    }

    @MainActor
    static func agentRow(_ agent: RemoteAgent) -> AgentRow {
        let directory = RemoteAgentDirectory.shared
        let models = (directory.models[agent.endpoint] ?? []).map {
            AgentModelRow(provider: $0.reference.provider, id: $0.reference.id, name: $0.name, reasoning: $0.reasoning)
        }
        switch directory.statuses[agent.endpoint] {
        case .online(let implementation, let version, let machine, let cwd):
            return AgentRow(name: agent.name, endpoint: agent.endpoint.absoluteString, status: "online", implementation: implementation,
                            version: version, machine: machine, folder: cwd, error: nil, models: models)
        case .offline(let error):
            return AgentRow(name: agent.name, endpoint: agent.endpoint.absoluteString, status: "offline", implementation: nil,
                            version: nil, machine: nil, folder: nil, error: error, models: models)
        case .checking, nil:
            return AgentRow(name: agent.name, endpoint: agent.endpoint.absoluteString, status: "checking", implementation: nil,
                            version: nil, machine: nil, folder: nil, error: nil, models: models)
        }
    }

    @MainActor
    static func handleListAgents(_ command: EmptyRequest, reply: OxHostRPC.Reply) {
        Task { @MainActor in
            let directory = RemoteAgentDirectory.shared
            await directory.refreshAll()
            Log.agent.debug("OxHostRPC.agents.list id=\(reply.id) count=\(directory.agents.count)")
            reply.success(ListAgentsResult(agents: directory.agents.map { agentRow($0) }))
        }
    }

    @MainActor
    static func handleAddAgent(_ command: AddAgentRequest, reply: OxHostRPC.Reply) {
        guard let endpoint = RemoteAgentDirectory.endpoint(from: command.endpoint) else { return reply.failure("invalid agent endpoint") }
        Task { @MainActor in
            do {
                let agent = try RemoteAgentDirectory.shared.add(name: command.name, endpoint: endpoint)
                await RemoteAgentDirectory.shared.refresh(endpoint)
                Log.agent.info("OxHostRPC.agents.add id=\(reply.id) endpoint=\(endpoint.absoluteString)")
                reply.success(AgentResult(agent: agentRow(agent)))
            } catch { reply.failure(error.localizedDescription) }
        }
    }

    @MainActor
    static func handleRemoveAgent(_ command: AgentEndpointRequest, reply: OxHostRPC.Reply) {
        guard let endpoint = RemoteAgentDirectory.endpoint(from: command.endpoint) else { return reply.failure("invalid agent endpoint") }
        do {
            try RemoteAgentDirectory.shared.remove(endpoint)
            Log.agent.info("OxHostRPC.agents.remove id=\(reply.id) endpoint=\(endpoint.absoluteString)")
            reply.success()
        } catch { reply.failure(error.localizedDescription) }
    }

    @MainActor
    static func handleListAgentConversations(_ command: AgentEndpointRequest, conversationManager: ConversationManager, reply: OxHostRPC.Reply) {
        guard let endpoint = RemoteAgentDirectory.endpoint(from: command.endpoint) else { return reply.failure("invalid agent endpoint") }
        Task { @MainActor in
            do {
                let listing = try await RemoteAgentDirectory.shared.client(for: endpoint).call("conversations.list")
                await conversationManager.loadAllSummaries()
                let known = Dictionary(conversationManager.summaries.compactMap { meta in
                    meta.remoteAgent.flatMap { $0.endpoint == endpoint ? $0.conversationID : nil }.map { ($0, meta.id) }
                }, uniquingKeysWith: { first, _ in first })
                let rows = (listing.objectValue?["conversations"]?.arrayValue ?? []).compactMap { value -> AgentConversationRow? in
                    guard let fields = value.objectValue, let id = fields["id"]?.stringValue else { return nil }
                    return AgentConversationRow(id: id, title: fields["title"]?.stringValue ?? "", cwd: fields["cwd"]?.stringValue ?? "",
                                                state: fields["state"]?.stringValue ?? "idle", origin: fields["origin"]?.stringValue ?? "terminal",
                                                updatedAt: fields["updatedAt"]?.stringValue ?? "", hostConversationId: known[id]?.uuidString)
                }
                reply.success(ListAgentConversationsResult(conversations: rows))
            } catch { reply.failure(error.localizedDescription) }
        }
    }
}
