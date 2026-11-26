import Foundation
import Observation

nonisolated struct RemoteAgent: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var endpoint: URL

    var id: URL { endpoint }
}

nonisolated struct RemoteAgentConfiguration: Codable, Equatable, Sendable {
    var format = 1
    var agents: [RemoteAgent] = []
    var defaultEndpoint: URL?

    static func load() -> Self {
        guard let data = try? Data(contentsOf: AppStoragePaths.remoteAgentConfiguration) else { return Self() }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.format == 1 else { throw StorageMigrationError.invalidApplicationStorage("Remote agent configuration") }
            return value
        } catch {
            Log.agent.error("RemoteAgentConfiguration.load failed error=\(error.localizedDescription)")
            return Self()
        }
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: AppStoragePaths.configuration, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: AppStoragePaths.remoteAgentConfiguration, options: .atomic)
    }
}

nonisolated struct RemoteAgentModel: Equatable, Hashable, Identifiable, Sendable {
    let reference: AgentModelReference
    let name: String
    let reasoning: Bool

    var id: String { "\(reference.provider)/\(reference.id)" }
}

nonisolated enum RemoteAgentStatus: Equatable, Sendable {
    case checking
    case online(implementation: String, version: String, machine: String, folder: String)
    case offline(String)

    var isOnline: Bool { if case .online = self { true } else { false } }
}

@MainActor
@Observable
final class RemoteAgentDirectory {
    static let shared = RemoteAgentDirectory()
    static let defaultPort = 9877

    private(set) var configuration: RemoteAgentConfiguration
    private(set) var statuses: [URL: RemoteAgentStatus] = [:]
    private(set) var models: [URL: [RemoteAgentModel]] = [:]
    private(set) var defaultModels: [URL: AgentModelReference] = [:]
    @ObservationIgnored private var clients: [URL: RemoteAgentClient] = [:]

    init(configuration: RemoteAgentConfiguration = .load()) {
        self.configuration = configuration
    }

    var agents: [RemoteAgent] { configuration.agents }

    var defaultEndpoint: URL? {
        configuration.defaultEndpoint.flatMap { endpoint in agent(for: endpoint).map(\.endpoint) }
    }

    var defaultBinding: RemoteAgentBinding? {
        defaultEndpoint.map { RemoteAgentBinding(endpoint: $0, model: defaultModels[$0]) }
    }

    func setDefault(_ endpoint: URL?) throws {
        var next = configuration
        next.defaultEndpoint = endpoint
        try next.save()
        configuration = next
        Log.agent.info("RemoteAgentDirectory.default endpoint=\(endpoint?.absoluteString ?? "local")")
    }

    func agent(for endpoint: URL) -> RemoteAgent? {
        configuration.agents.first { $0.endpoint == endpoint }
    }

    func client(for endpoint: URL) -> RemoteAgentClient {
        if let client = clients[endpoint] { return client }
        let client = RemoteAgentClient(endpoint: endpoint)
        clients[endpoint] = client
        return client
    }

    @discardableResult
    func add(name: String, endpoint: URL) throws -> RemoteAgent {
        let agent = RemoteAgent(name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint)
        var next = configuration
        next.agents.removeAll { $0.endpoint == endpoint }
        next.agents.append(agent)
        try next.save()
        configuration = next
        Log.agent.info("RemoteAgentDirectory.add endpoint=\(endpoint.absoluteString) count=\(next.agents.count)")
        Task { await refresh(endpoint) }
        return agent
    }

    func remove(_ endpoint: URL) throws {
        var next = configuration
        next.agents.removeAll { $0.endpoint == endpoint }
        try next.save()
        configuration = next
        statuses[endpoint] = nil
        models[endpoint] = nil
        clients[endpoint] = nil
        Log.agent.info("RemoteAgentDirectory.remove endpoint=\(endpoint.absoluteString) count=\(next.agents.count)")
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for agent in configuration.agents { group.addTask { await self.refresh(agent.endpoint) } }
        }
    }

    func refresh(_ endpoint: URL) async {
        statuses[endpoint] = .checking
        let client = client(for: endpoint)
        do {
            let description = try await client.call("agent.describe", timeout: .seconds(5)).objectValue ?? [:]
            let implementation = description["implementation"]?.objectValue
            statuses[endpoint] = .online(
                implementation: implementation?["name"]?.stringValue ?? "agent",
                version: implementation?["version"]?.stringValue ?? "",
                machine: description["machine"]?.stringValue ?? endpoint.host() ?? "",
                folder: description["folder"]?.stringValue ?? ""
            )
            let listing = try await client.call("models.list", timeout: .seconds(30)).objectValue ?? [:]
            models[endpoint] = (listing["models"]?.arrayValue ?? []).compactMap(Self.model)
            defaultModels[endpoint] = listing["current"].flatMap(Self.reference)
            Log.agent.info("RemoteAgentDirectory.refresh endpoint=\(endpoint.absoluteString) online=true models=\(models[endpoint]?.count ?? 0)")
        } catch {
            statuses[endpoint] = .offline(error.localizedDescription)
            Log.agent.info("RemoteAgentDirectory.refresh endpoint=\(endpoint.absoluteString) online=false error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
        }
    }

    func displayName(for endpoint: URL) -> String {
        agent(for: endpoint)?.name ?? endpoint.host() ?? endpoint.absoluteString
    }

    func machine(for endpoint: URL) -> String? {
        if case .online(_, _, let machine, _) = statuses[endpoint] { machine } else { nil }
    }

    func modelName(_ reference: AgentModelReference?, endpoint: URL) -> String? {
        guard let reference = reference ?? defaultModels[endpoint] else { return nil }
        return models[endpoint]?.first { $0.reference == reference }?.name ?? reference.id
    }

    static func endpoint(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme), let host = components.host, !host.isEmpty else { return nil }
        if scheme == "ws", components.port == nil { components.port = defaultPort }
        if components.path == "/" { components.path = "" }
        return components.url
    }

    private static func reference(_ value: JSONValue) -> AgentModelReference? {
        guard let fields = value.objectValue, let provider = fields["provider"]?.stringValue, let id = fields["id"]?.stringValue else { return nil }
        return AgentModelReference(provider: provider, id: id)
    }

    private static func model(_ value: JSONValue) -> RemoteAgentModel? {
        guard let reference = reference(value) else { return nil }
        let fields = value.objectValue ?? [:]
        return RemoteAgentModel(reference: reference, name: fields["name"]?.stringValue ?? reference.id,
                                reasoning: fields["reasoning"]?.boolValue ?? false)
    }
}
