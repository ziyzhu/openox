import Foundation

nonisolated struct CustomLLMModel: Equatable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var maxTokens: Int
    var maxContext: Int
    var supportsTools: Bool

    init(
        id: String,
        displayName: String? = nil,
        maxTokens: Int = 4_096,
        maxContext: Int = 32_768,
        supportsTools: Bool = false
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.maxTokens = maxTokens
        self.maxContext = maxContext
        self.supportsTools = supportsTools
    }

    var modelInfo: ProviderModel {
        ProviderModel(
            id: id,
            displayName: displayName,
            maxTokens: maxTokens,
            maxContext: maxContext,
            supportsTools: supportsTools
        )
    }
}

nonisolated struct CustomLLMProvider: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var baseURL: URL
    var models: [CustomLLMModel]

    init(id: UUID = UUID(), name: String, baseURL: URL, models: [CustomLLMModel]) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        models = []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(baseURL, forKey: .baseURL)
    }

    var clientID: String { "custom:\(id.uuidString.lowercased())" }

    var profile: OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: clientID,
            displayName: RegionalValue(name),
            models: RegionalValue(models.map(\.modelInfo)),
            regions: [.global, .china],
            endpoint: RegionalValue(baseURL),
            auth: .optionalBearer,
            inferenceLocation: .userHosted
        )
    }

    var client: OpenAIChatTransport { profile.client(for: .global, models: []) }
}

nonisolated enum CustomLLMProviderError: LocalizedError {
    case invalidURL
    case invalidResponse
    case requestFailed(Int, String)
    case noModels

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter an HTTP or HTTPS server address."
        case .invalidResponse:
            return "The server returned an invalid models response."
        case .requestFailed(let status, let message):
            return message.isEmpty ? "The server returned HTTP \(status)." : "HTTP \(status): \(message)"
        case .noModels:
            return "The server did not report any models whose supported_parameters include tools."
        }
    }
}

nonisolated enum CustomLLMProviderDiscovery {
    private struct ModelsResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let supportedParameters: [String]?

            enum CodingKeys: String, CodingKey {
                case id
                case supportedParameters = "supported_parameters"
            }
        }

        let data: [Entry]
    }

    static func normalizedBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/v1" : "/\(path)"
        return components.url
    }

    static func models(baseURL: URL, apiKey: String?) async throws -> [CustomLLMModel] {
        var url = baseURL
        url.appendPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        Log.network.info("CustomLLMProvider.models GET \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CustomLLMProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            Log.network.error("CustomLLMProvider.models failed status=\(http.statusCode) bodyChars=\(message.count)")
            throw CustomLLMProviderError.requestFailed(http.statusCode, String(message.prefix(500)))
        }
        let discovered = try JSONDecoder().decode(ModelsResponse.self, from: data).data.compactMap { entry -> CustomLLMModel? in
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, entry.supportedParameters?.contains("tools") == true else { return nil }
            return CustomLLMModel(id: id, supportsTools: true)
        }
        let unique = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
        guard !unique.isEmpty else { throw CustomLLMProviderError.noModels }
        Log.network.info("CustomLLMProvider.models ok count=\(unique.count)")
        return unique
    }
}
