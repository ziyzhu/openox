import Foundation

nonisolated enum LegacyChatImport {
    static let schemaVersion = 6

    static func turn(from data: Data, decoder: JSONDecoder) throws -> Turn {
        var root = try object(from: data)
        guard root["type"] as? String == "agent",
              var agent = root["agent"] as? [String: Any] else {
            return try decoder.decode(Turn.self, from: data)
        }
        var steps = (agent["steps"] ?? agent["content"]) as? [[String: Any]] ?? []
        let generation = generationID(agent: &agent, steps: steps)
        steps = steps.map { canonicalStep($0, generation: generation) }
        agent["steps"] = steps
        agent.removeValue(forKey: "content")
        agent.removeValue(forKey: "model")
        root["agent"] = agent
        return try decoder.decode(Turn.self, from: try JSONSerialization.data(withJSONObject: root))
    }

    private static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private static func generationID(agent: inout [String: Any], steps: [[String: Any]]) -> String? {
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

    private static func canonicalStep(_ value: [String: Any], generation: String?) -> [String: Any] {
        var step = value
        if step["generation"] == nil {
            step["generation"] = generation ?? step["id"]
        }
        guard step["type"] as? String == "action",
              var action = step["action"] as? [String: Any],
              action["type"] as? String == "execute",
              var execution = action["execute"] as? [String: Any] else { return step }
        let effects = (execution["effects"] ?? execution["trace"]) as? [[String: Any]] ?? []
        execution["effects"] = effects.compactMap(canonicalEffect)
        execution.removeValue(forKey: "trace")
        action["execute"] = execution
        step["action"] = action
        return step
    }

    private static func canonicalEffect(_ value: [String: Any]) -> [String: Any]? {
        var effect = value
        switch effect["type"] as? String {
        case "step":
            effect["type"] = "invocation"
            effect["invocation"] = effect.removeValue(forKey: "step")
        case "widget":
            return nil
        case "media":
            effect["media"] = effect.removeValue(forKey: "artifact")
        default:
            break
        }
        return effect
    }
}
