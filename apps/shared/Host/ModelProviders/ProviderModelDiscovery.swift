import Foundation

nonisolated struct ProviderModelDiscovery: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable {
        case openai, gemini, chatgpt, anthropic

        var listKey: String { self == .gemini || self == .chatgpt ? "models" : "data" }
        var impliesTools: Bool { self == .chatgpt || self == .anthropic }
    }

    struct Rule: Codable, Equatable, Sendable {
        var match: String
        var exclude: Bool?
        var options: ProviderDefinition.Model.Options?
        var outputTokens: Int?

        func matches(_ id: String) -> Bool {
            NSPredicate(format: "SELF LIKE %@", match).evaluate(with: id)
        }
    }

    var format: Format
    var catalog: String?
    var rules: [Rule]?

    func models(for definition: ProviderDefinition) async throws -> [ProviderDefinition.Model] {
        let (data, response) = try await URLSession.shared.data(for: try await request(for: definition))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw RuntimeError.bridge("The provider's model list returned HTTP \(status)")
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = body[format.listKey] as? [[String: Any]] else {
            throw RuntimeError.bridge("The provider returned a malformed model list")
        }
        let known = ProviderModelCatalog.models(for: catalog)
        return entries.compactMap { model($0, known: known) }
    }

    private func request(for definition: ProviderDefinition) async throws -> URLRequest {
        var url = definition.url.appendingPathComponent("models")
        switch format {
        case .chatgpt: url.append(queryItems: [URLQueryItem(name: "client_version", value: "1.0.0")])
        case .gemini: url.append(queryItems: [URLQueryItem(name: "pageSize", value: "1000")])
        case .anthropic: url.append(queryItems: [URLQueryItem(name: "limit", value: "1000")])
        case .openai: break
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in try await headers(for: definition) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func headers(for definition: ProviderDefinition) async throws -> [String: String] {
        guard definition.auth.kind != .custom else {
            return try await ProviderClientFactory.customAuth(definition).resolve(forceRefresh: false).headers
        }
        let account = definition.auth.kind == .oauth ? ProviderOAuthAccount(definition) : nil
        var headers = try await ProviderRequestAuthentication(definition: definition, account: account).headers()
        if format == .anthropic {
            headers["anthropic-version"] = definition.options?.version ?? "2023-06-01"
            if let beta = definition.options?.beta, !beta.isEmpty { headers["anthropic-beta"] = beta.joined(separator: ",") }
        }
        return headers
    }

    private func model(_ entry: [String: Any], known: [String: ProviderModel]) -> ProviderDefinition.Model? {
        guard let id = identifier(entry), isListed(entry),
              rules?.contains(where: { $0.exclude == true && $0.matches(id) }) != true else { return nil }
        let catalogModel = known[id]
        guard Self.toolSupport(entry) ?? (catalogModel != nil || format.impliesTools) else { return nil }
        let input = Self.modalities(entry, "input_modalities") ?? Self.modalities(entry, "architecture.input_modalities")
            ?? catalogModel?.modalities.input ?? [.text]
        let output = Self.modalities(entry, "output_modalities") ?? Self.modalities(entry, "architecture.output_modalities")
            ?? catalogModel?.modalities.output ?? [.text]
        let cap = rules?.first { $0.matches(id) && $0.outputTokens != nil }?.outputTokens
        guard input.contains(.text), output.contains(.text),
              let context = Self.integer(entry, Self.contextKeys) ?? catalogModel?.maxContext,
              let limit = Self.integer(entry, Self.outputKeys) ?? catalogModel?.maxTokens ?? cap else { return nil }
        let efforts = Self.reasoningEfforts(entry) ?? catalogModel?.reasoningEfforts ?? []
        let model = ProviderModel(
            id: id,
            displayName: catalogModel?.displayName ?? Self.string(entry, ["display_name", "displayName", "name"]) ?? id,
            maxTokens: min(limit, cap ?? limit, context),
            maxContext: context,
            supportsTools: true,
            reasoning: !efforts.isEmpty,
            reasoningEfforts: efforts,
            modalities: ProviderModelModalities(input: input, output: output)
        )
        return ProviderDefinition.Model(model, options: rules?.first { $0.matches(id) && $0.options != nil }?.options)
    }

    private func identifier(_ entry: [String: Any]) -> String? {
        switch format {
        case .gemini: (entry["name"] as? String).map { String($0.trimmingPrefix("models/")) }
        case .chatgpt: entry["slug"] as? String
        case .openai, .anthropic: entry["id"] as? String
        }
    }

    private func isListed(_ entry: [String: Any]) -> Bool {
        if entry["visibility"] as? String == "hide" || entry["status"] as? String == "Shutdown" { return false }
        if entry["model_picker_enabled"] as? Bool == false || Self.value(entry, "policy.state") as? String == "disabled" { return false }
        if let methods = entry["supportedGenerationMethods"] as? [String] { return methods.contains("generateContent") }
        return true
    }

    private static let contextKeys = [
        "context_window", "context_length", "inputTokenLimit", "max_input_tokens",
        "top_provider.context_length", "capabilities.limits.max_context_window_tokens",
    ]
    private static let outputKeys = [
        "max_output_tokens", "outputTokenLimit", "top_provider.max_completion_tokens",
        "capabilities.limits.max_output_tokens",
    ]

    private static func toolSupport(_ entry: [String: Any]) -> Bool? {
        if let parameters = entry["supported_parameters"] as? [String] { return parameters.contains("tools") }
        return value(entry, "features.tools.function_calling") as? Bool ?? value(entry, "capabilities.supports.tool_calls") as? Bool
    }

    private static func reasoningEfforts(_ entry: [String: Any]) -> [String]? {
        if let levels = entry["supported_reasoning_levels"] as? [[String: Any]] { return levels.compactMap { $0["effort"] as? String } }
        return value(entry, "reasoning_efforts.valid_efforts") as? [String] ?? value(entry, "effort.supported_levels") as? [String]
    }

    private static func modalities(_ entry: [String: Any], _ path: String) -> Set<ProviderModelModality>? {
        guard let names = value(entry, path) as? [String] else { return nil }
        return Set(names.compactMap { $0 == "file" ? .pdf : ProviderModelModality(rawValue: $0) })
    }

    private static func integer(_ entry: [String: Any], _ paths: [String]) -> Int? {
        paths.lazy.compactMap { value(entry, $0) as? Int }.first { $0 > 0 }
    }

    private static func string(_ entry: [String: Any], _ keys: [String]) -> String? {
        keys.lazy.compactMap { entry[$0] as? String }.first { !$0.isEmpty }
    }

    private static func value(_ entry: [String: Any], _ path: String) -> Any? {
        path.split(separator: ".").reduce(entry as Any?) { ($0 as? [String: Any])?[String($1)] }
    }
}

nonisolated enum ProviderModelCatalog {
    private static let snapshot: [String: [ProviderModel]] = {
        guard let url = Bundle.main.url(forResource: "provider-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode([String: [ProviderModel]].self, from: data) else {
            Log.agent.error("ProviderModelCatalog snapshot unavailable")
            return [:]
        }
        return snapshot
    }()

    static func models(for catalog: String?) -> [String: ProviderModel] {
        Dictionary((catalog.flatMap { snapshot[$0] } ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
