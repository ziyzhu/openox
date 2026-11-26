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

    func validated() throws -> Self {
        guard format == 1, agents.count <= 20 else { throw RuntimeError.bridge("Agent configuration needs format 1 and at most 20 agents") }
        var next = self
        next.agents = try agents.map { agent in
            let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100 else { throw RuntimeError.bridge("Each agent needs a name of 1–100 characters") }
            guard let endpoint = RemoteAgentDirectory.endpoint(from: agent.endpoint.absoluteString) else {
                throw RuntimeError.bridge("Agent \(name) has an invalid address; use a Tailscale name such as my-mac.tailnet.ts.net or a ws:// or wss:// URL")
            }
            return RemoteAgent(name: name, endpoint: endpoint)
        }
        guard Set(next.agents.map { $0.name.lowercased() }).count == next.agents.count,
              Set(next.agents.map(\.endpoint)).count == next.agents.count else {
            throw RuntimeError.bridge("Agent names and addresses must be unique")
        }
        if let endpoint = defaultEndpoint {
            guard let normalized = RemoteAgentDirectory.endpoint(from: endpoint.absoluteString), next.agents.contains(where: { $0.endpoint == normalized }) else {
                throw RuntimeError.bridge("defaultEndpoint must be the address of a listed agent, or null for this device")
            }
            next.defaultEndpoint = normalized
        }
        return next
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = AppStoragePaths.remoteAgentConfiguration
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

nonisolated struct RemoteAgentModel: Equatable, Hashable, Identifiable, Sendable {
    let reference: AgentModelReference
    let name: String
    let reasoning: Bool
    var thinkingLevels: [String] = ["off"]

    var id: String { "\(reference.provider)/\(reference.id)" }
}

nonisolated enum RemoteAgentStatus: Equatable, Sendable {
    case checking
    case online(implementation: String, version: String, machine: String, cwd: String?)
    case offline(String)

    var isOnline: Bool { if case .online = self { true } else { false } }
}

@MainActor
@Observable
final class RemoteAgentDirectory {
    static let shared = RemoteAgentDirectory()
    nonisolated static let defaultPort = 9878

    private(set) var configuration: RemoteAgentConfiguration
    private(set) var statuses: [URL: RemoteAgentStatus] = [:]
    private(set) var models: [URL: [RemoteAgentModel]] = [:]
    private(set) var defaultModels: [URL: AgentModelReference] = [:]
    private(set) var defaultThinkingLevels: [URL: String] = [:]
    @ObservationIgnored private var clients: [URL: RemoteAgentClient] = [:]
    @ObservationIgnored var pushDevice: JSONValue? {
        didSet {
            guard pushDevice != oldValue else { return }
            for agent in configuration.agents { Task { await registerPush(agent.endpoint) } }
        }
    }

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

    func replace(_ next: RemoteAgentConfiguration) throws {
        try next.save()
        adopt(next, reason: "replace")
    }

    func reloadConfiguration() {
        let next = RemoteAgentConfiguration.load()
        guard next != configuration else { return }
        adopt(next, reason: "profile")
    }

    private func adopt(_ next: RemoteAgentConfiguration, reason: String) {
        let kept = Set(next.agents.map(\.endpoint))
        for endpoint in configuration.agents.map(\.endpoint) where !kept.contains(endpoint) {
            unregisterPush(endpoint)
            statuses[endpoint] = nil
            models[endpoint] = nil
            clients[endpoint] = nil
        }
        configuration = next
        Log.agent.info("RemoteAgentDirectory.\(reason) count=\(next.agents.count) default=\(next.defaultEndpoint?.absoluteString ?? "local")")
        Task { await refreshAll() }
    }

    func refreshUnknown() async {
        await withTaskGroup(of: Void.self) { group in
            for agent in configuration.agents where statuses[agent.endpoint].map({ $0 == .checking }) ?? true {
                group.addTask { await self.refresh(agent.endpoint) }
            }
        }
    }

    var appInformation: JSONValue {
        .array(configuration.agents.map { agent in
            var fields: [String: JSONValue] = [
                "name": .string(agent.name), "address": .string(agent.endpoint.absoluteString),
                "default": .bool(configuration.defaultEndpoint == agent.endpoint),
                "models": .int(models[agent.endpoint]?.count ?? 0),
            ]
            switch statuses[agent.endpoint] {
            case .online(let implementation, let version, let machine, let cwd):
                fields["status"] = .string("online")
                fields["agent"] = .string("\(implementation) \(version)")
                fields["machine"] = .string(machine)
                if let cwd { fields["cwd"] = .string(cwd) }
            case .offline(let error):
                fields["status"] = .string("offline")
                fields["error"] = .string(String(error.prefix(200)))
            case .checking, nil:
                fields["status"] = .string("checking")
            }
            return .object(fields)
        })
    }

    func remove(_ endpoint: URL) throws {
        var next = configuration
        next.agents.removeAll { $0.endpoint == endpoint }
        try next.save()
        configuration = next
        unregisterPush(endpoint)
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
                cwd: description["cwd"]?.stringValue
            )
            let listing = try await client.call("models.list", timeout: .seconds(30)).objectValue ?? [:]
            models[endpoint] = (listing["models"]?.arrayValue ?? []).compactMap(Self.model)
            defaultModels[endpoint] = listing["current"].flatMap(Self.reference)
            defaultThinkingLevels[endpoint] = listing["thinkingLevel"]?.stringValue
            Log.agent.info("RemoteAgentDirectory.refresh endpoint=\(endpoint.absoluteString) online=true models=\(models[endpoint]?.count ?? 0)")
            await registerPush(endpoint)
        } catch {
            statuses[endpoint] = .offline(error.localizedDescription)
            Log.agent.info("RemoteAgentDirectory.refresh endpoint=\(endpoint.absoluteString) online=false error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
        }
    }

    private func registerPush(_ endpoint: URL) async {
        guard let device = pushDevice else { return }
        do {
            _ = try await client(for: endpoint).call("notifications.register", device, timeout: .seconds(10))
            Log.agent.info("RemoteAgentDirectory.push registered endpoint=\(endpoint.absoluteString)")
        } catch {
            Log.agent.warning("RemoteAgentDirectory.push register failed endpoint=\(endpoint.absoluteString) error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
        }
    }

    private func unregisterPush(_ endpoint: URL) {
        guard let token = pushDevice?.objectValue?["token"] else { return }
        let client = client(for: endpoint)
        Task {
            do {
                _ = try await client.call("notifications.unregister", .object(["token": token]), timeout: .seconds(5))
                Log.agent.info("RemoteAgentDirectory.push unregistered endpoint=\(endpoint.absoluteString)")
            } catch {
                Log.agent.warning("RemoteAgentDirectory.push unregister failed endpoint=\(endpoint.absoluteString) error=\(LogPrivacy.text(error.localizedDescription, limit: 200))")
            }
        }
    }

    func displayName(for endpoint: URL) -> String {
        if let name = agent(for: endpoint)?.name { return name }
        guard let host = endpoint.host() else { return endpoint.absoluteString }
        return host.hasSuffix(".ts.net") ? String(host.prefix { $0 != "." }) : host
    }

    func machine(for endpoint: URL) -> String? {
        if case .online(_, _, let machine, _) = statuses[endpoint] { machine } else { nil }
    }

    func cwd(for endpoint: URL) -> String? {
        if case .online(_, _, _, let cwd) = statuses[endpoint] { cwd } else { nil }
    }

    func agent(named name: String) -> RemoteAgent? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return configuration.agents.first { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    func modelName(_ reference: AgentModelReference?, endpoint: URL) -> String? {
        guard let reference = reference ?? defaultModels[endpoint] else { return nil }
        return models[endpoint]?.first { $0.reference == reference }?.name ?? reference.id
    }

    nonisolated static func endpoint(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let bare = !trimmed.contains("://")
        let text = bare ? "\(trimmed.hasSuffix(".ts.net") || trimmed.contains(".ts.net:") ? "wss" : "ws")://\(trimmed)" : trimmed
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".ts.net") { components.scheme = "wss" }
        if components.port == nil, scheme == "ws" || host.hasSuffix(".ts.net") { components.port = defaultPort }
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
        let reasoning = fields["reasoning"]?.boolValue ?? false
        let levels = fields["thinkingLevels"]?.arrayValue?.compactMap(\.stringValue)
        return RemoteAgentModel(reference: reference, name: fields["name"]?.stringValue ?? reference.id, reasoning: reasoning,
                                thinkingLevels: levels ?? (reasoning ? ["off", "minimal", "low", "medium", "high"] : ["off"]))
    }

    func model(_ reference: AgentModelReference?, endpoint: URL) -> RemoteAgentModel? {
        guard let reference = reference ?? defaultModels[endpoint] else { return nil }
        return models[endpoint]?.first { $0.reference == reference }
    }
}
