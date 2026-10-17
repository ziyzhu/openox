import Foundation

nonisolated enum ConversationMigrator {
    private static let legacyConversationSchemaVersion = 6

    @MainActor
    static func migratedServiceDomains(_ domains: [String], services: ServiceManager) -> [String] {
        domains.map { domain in
            guard services.service(domain: domain) == nil else { return domain }
            return services.services.first {
                $0.definition.mcpEndpoint.map(RemoteMCPDescriptor.serviceID(for:)) == domain
            }?.domain ?? domain
        }
    }

    private static func legacyTurn(from data: Data, decoder: JSONDecoder) throws -> Turn {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard root["type"] as? String == "agent",
              var agent = root["agent"] as? [String: Any] else {
            return try decoder.decode(Turn.self, from: data)
        }
        var steps = (agent["steps"] ?? agent["content"]) as? [[String: Any]] ?? []
        let generation = legacyGenerationID(agent: &agent, steps: steps)
        steps = steps.map { canonicalLegacyStep($0, generation: generation) }
        agent["steps"] = steps
        agent.removeValue(forKey: "content")
        agent.removeValue(forKey: "model")
        root["agent"] = agent
        return try decoder.decode(Turn.self, from: try JSONSerialization.data(withJSONObject: root))
    }

    private static func legacyGenerationID(
        agent: inout [String: Any],
        steps: [[String: Any]]
    ) -> String? {
        if let generations = agent["generations"] as? [[String: Any]],
           let id = generations.first?["id"] as? String {
            return id
        }
        guard let model = agent["model"] as? String,
              let at = agent["at"],
              let outcome = agent["outcome"] else { return nil }
        let seed = (steps.first?["id"] as? String) ?? "\(at).\(model)"
        let id = StableID.uuid("legacy-generation.\(seed)").uuidString
        agent["generations"] = [[
            "id": id,
            "at": at,
            "model": model,
            "outcome": outcome,
        ]]
        return id
    }

    private static func canonicalLegacyStep(
        _ value: [String: Any],
        generation: String?
    ) -> [String: Any] {
        var step = value
        if step["generation"] == nil {
            step["generation"] = generation ?? step["id"]
        }
        guard step["type"] as? String == "action",
              var action = step["action"] as? [String: Any],
              action["type"] as? String == "execute",
              var execution = action["execute"] as? [String: Any] else { return step }
        let effects = (execution["effects"] ?? execution["trace"]) as? [[String: Any]] ?? []
        execution["effects"] = effects.compactMap(canonicalLegacyEffect)
        execution.removeValue(forKey: "trace")
        action["execute"] = execution
        step["action"] = action
        return step
    }

    static func canonicalLegacyEffect(_ value: [String: Any]) -> [String: Any]? {
        var effect = value
        switch effect["type"] as? String {
        case "step":
            effect["type"] = "invocation"
            effect["invocation"] = effect.removeValue(forKey: "step")
        case "widget":
            return nil
        case "media":
            if effect["media"] == nil { effect["media"] = effect.removeValue(forKey: "artifact") }
        default:
            break
        }
        return effect
    }

    static func migrateLegacyAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let encoder = JSONEncoder()
        let directories = try fm.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.path < $1.path }
        var upgraded = 0
        var refreshed = 0
        for directory in directories {
            let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard fm.fileExists(atPath: metadataURL.path) else { continue }
            var metadata = try decoder.decode(ConversationMeta.self, from: Data(contentsOf: metadataURL))
            guard [ConversationFormat.currentSchemaVersion, legacyConversationSchemaVersion].contains(metadata.schemaVersion) else {
                Log.app.warning("StorageMigrator.agentContext skipped=\(directory.lastPathComponent) schema=\(metadata.schemaVersion)")
                continue
            }
            let transcriptURL = directory.appendingPathComponent("turns.jsonl", isDirectory: false)
            let lines = fm.fileExists(atPath: transcriptURL.path) ? try [UInt8](Data(contentsOf: transcriptURL)).split(separator: 0x0A).map { Data($0) } : []
            let legacy = metadata.schemaVersion == legacyConversationSchemaVersion
            let decoded = try lines.map {
                legacy
                    ? try legacyTurn(from: $0, decoder: decoder)
                    : try decoder.decode(Turn.self, from: $0)
            }
            let turns = ConversationFormat.normalize(decoded)
            if legacy || turns != decoded {
                try turns.reduce(into: Data()) { output, turn in
                    output.append(try encoder.encode(turn))
                    output.append(0x0A)
                }.write(to: transcriptURL, options: .atomic)
            }
            if legacy {
                metadata.schemaVersion = ConversationFormat.currentSchemaVersion
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
                upgraded += 1
            }
            let contextURL = directory.appendingPathComponent("context.json", isDirectory: false)
            guard let lastAgent = turns.lastIndex(where: { turn in
                if case .agent = turn { return true }
                return false
            }) else {
                if fm.fileExists(atPath: contextURL.path) { try fm.removeItem(at: contextURL) }
                continue
            }
            let stored = try? decoder.decode(AgentContextCheckpoint.self, from: Data(contentsOf: contextURL))
            let messages: [Message]
            let tokensBefore: Int
            if !legacy, let stored, let boundary = stored.boundary(in: turns), boundary <= lastAgent {
                let tail = boundary == lastAgent
                    ? []
                    : ConversationProjection.makeWireMessages(from: Array(turns[(boundary + 1)...lastAgent]))
                messages = stored.messages + tail
                tokensBefore = stored.tokensBefore
            } else {
                messages = ConversationProjection.makeWireMessages(from: Array(turns[...lastAgent]))
                tokensBefore = 0
            }
            let context = AgentContextCheckpoint(
                messages: messages,
                tokensBefore: tokensBefore,
                turns: turns,
                through: lastAgent
            )
            try encoder.encode(context).write(to: contextURL, options: .atomic)
            refreshed += 1
        }
        Log.app.info("StorageMigrator.agentContexts root=\(root.lastPathComponent) conversations=\(directories.count) refreshed=\(refreshed) upgraded=\(upgraded)")
    }

}
