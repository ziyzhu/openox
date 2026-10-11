import CryptoKit
import Foundation

nonisolated func systemPromptFingerprint(_ systemPrompt: String?) -> String {
    SHA256.hash(data: Data((systemPrompt ?? "").utf8))
        .prefix(6)
        .map { String(format: "%02x", $0) }
        .joined()
}

// Cache backends route requests by a caller-supplied affinity key (OpenAI's
// prompt_cache_key / session-id, OpenRouter's x-session-id); the key must be
// identical across requests sharing a prompt prefix or every request lands on
// a cold machine and never reads the cache.
nonisolated func promptCacheKey(model: ProviderModel, systemPrompt: String?, tools: [any AgentTool]) -> String {
    let payload = JSONValue.object([
        "model": .string(model.id),
        "systemPrompt": systemPrompt.map(JSONValue.string) ?? .null,
        "tools": .array(tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.parameters,
                "strict": .bool(tool.strict),
            ])
        }),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(payload)) ?? Data()
    return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
}
