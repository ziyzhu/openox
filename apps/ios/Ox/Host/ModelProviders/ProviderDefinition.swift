import Foundation

nonisolated struct ProviderDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var url: URL
    var api: LLMWireProtocol
    var auth: Authentication
    var options: Options?
    var models: [Model]

    struct Authentication: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case none, bearer, oauth, custom
            case apiKey = "api-key"
        }
        enum Flow: String, Codable, Sendable {
            case authorizationCode = "authorization-code"
            case deviceCode = "device-code"
        }
        enum Encoding: String, Codable, Sendable { case form, json }

        var kind: Kind
        var optional: Bool?
        var header: String?
        var adapter: String?
        var flow: Flow?
        var clientID: String?
        var scopes: [String]?
        var tokenURL: URL?
        var requestEncoding: Encoding?
        var authorizeURL: URL?
        var redirectURI: String?
        var authorizeParams: [String: String]?
        var deviceAuthorizationURL: URL?

        var requiresCredential: Bool {
            kind != .none && optional != true
        }
    }

    struct Options: Codable, Equatable, Sendable {
        var headers: [String: String]?
        var extraBody: [String: JSONValue]?
        var maxTokensField: String?
        var reasoningFormat: String?
        var reasoningEffort: String?
        var cachesSystemPrompt: Bool?
        var cacheRouting: String?
        var sessionHeader: String?
        var streaming: String?
        var accountHeader: String?
        var version: String?
        var beta: [String]?
    }

    struct Model: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var wireID: String?
        var contextTokens: Int?
        var outputTokens: Int?
        var input: [ProviderModelModality]?
        var output: [ProviderModelModality]?
        var reasoningEfforts: [String]?
        var options: Options?

        struct Options: Codable, Equatable, Sendable {
            var serviceTier: String?
            var adaptiveThinking: Bool?
            var replayReasoning: Bool?
        }

        init(_ model: ProviderModel, options: Options? = nil) {
            id = model.id
            name = model.displayName
            wireID = model.providerModelID
            contextTokens = model.maxContext
            outputTokens = model.maxTokens
            input = model.modalities.input.sorted { $0.rawValue < $1.rawValue }
            output = model.modalities.output.sorted { $0.rawValue < $1.rawValue }
            reasoningEfforts = model.reasoningEfforts.isEmpty ? nil : model.reasoningEfforts
            self.options = options
        }

        var runtimeModel: ProviderModel {
            ProviderModel(
                id: id,
                providerModelID: wireID,
                displayName: name,
                maxTokens: outputTokens ?? 4_096,
                maxContext: contextTokens ?? 32_768,
                supportsTools: true,
                reasoning: !(reasoningEfforts ?? []).isEmpty || options?.adaptiveThinking == true,
                reasoningEfforts: reasoningEfforts ?? [],
                modalities: ProviderModelModalities(input: Set(input ?? [.text]), output: Set(output ?? [.text]))
            )
        }
    }

    static let schema: JSONValue = {
        guard let url = Bundle.main.url(forResource: "provider-definition.schema", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schema = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            fatalError("Missing provider definition schema")
        }
        return schema
    }()

    static func decode(_ value: JSONValue) throws -> Self {
        let violations = JSONSchemaValidator.validate(value, against: schema, definitions: [:])
        guard violations.isEmpty else {
            throw RuntimeError.bridge("Invalid provider: \(Service.InvokeError.describe(violations))")
        }
        let definition = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        try definition.validate()
        return definition
    }

    func validate() throws {
        try Self.validateURL(url, field: "url", allowHTTP: true)
        if let header = auth.header { try Self.validateHeader(header) }
        if let header = options?.sessionHeader { try Self.validateHeader(header) }
        if let header = options?.accountHeader { try Self.validateHeader(header) }
        for (key, value) in options?.headers ?? [:] {
            try Self.validateHeader(key)
            guard !Self.secretName(key), !value.contains("\r"), !value.contains("\n") else {
                throw RuntimeError.bridge("Invalid provider: options.headers must not contain credentials or line breaks")
            }
        }
        let ownedFields: Set<String> = ["model", "messages", "input", "tools", "stream", "max_tokens", "max_completion_tokens", "max_output_tokens", "contents", "system", "systemInstruction"]
        guard ownedFields.isDisjoint(with: Set(options?.extraBody?.keys.map { $0 } ?? [])),
              !Self.containsSecret(.object(options?.extraBody ?? [:])) else {
            throw RuntimeError.bridge("Invalid provider: extraBody overrides an owned request field or contains credential fields")
        }
        guard Set(models.map(\.id)).count == models.count else {
            throw RuntimeError.bridge("Invalid provider: duplicate model IDs")
        }
        for model in models {
            if let context = model.contextTokens, let output = model.outputTokens, output > context {
                throw RuntimeError.bridge("Invalid provider: models.\(model.id).outputTokens exceeds contextTokens")
            }
            if model.options?.serviceTier != nil, api != .openAIResponses {
                throw RuntimeError.bridge("Invalid provider: serviceTier requires openai-responses")
            }
            if model.options?.adaptiveThinking != nil, api != .anthropicMessages {
                throw RuntimeError.bridge("Invalid provider: adaptiveThinking requires anthropic-messages")
            }
            if model.options?.replayReasoning != nil, api != .openAIChatCompletions {
                throw RuntimeError.bridge("Invalid provider: replayReasoning requires openai-chat-completions")
            }
        }
        if auth.kind == .oauth {
            for (field, endpoint) in [("tokenURL", auth.tokenURL), ("authorizeURL", auth.authorizeURL), ("deviceAuthorizationURL", auth.deviceAuthorizationURL)] {
                if let endpoint { try Self.validateURL(endpoint, field: field, allowHTTP: false) }
            }
            let reserved: Set<String> = ["client_id", "response_type", "redirect_uri", "scope", "state", "nonce", "code_challenge", "code_challenge_method"]
            guard reserved.isDisjoint(with: Set(auth.authorizeParams?.keys.map { $0 } ?? [])),
                  !(auth.authorizeParams ?? [:]).keys.contains(where: Self.secretName) else {
                throw RuntimeError.bridge("Invalid provider: authorizeParams overrides OAuth fields or contains credentials")
            }
            if let redirect = auth.redirectURI {
                guard let callback = URLComponents(string: redirect), callback.scheme != nil,
                      callback.user == nil, callback.password == nil, callback.fragment == nil else {
                    throw RuntimeError.bridge("Invalid provider: redirectURI is not a callback URI")
                }
            }
        }
        if options?.streaming == "websocket-with-sse-fallback", auth.kind != .custom {
            throw RuntimeError.bridge("Invalid provider: WebSocket account routing requires a registered custom adapter")
        }
    }

    var json: JSONValue {
        get throws { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self)) }
    }

    static func validateURL(_ url: URL, field: String, allowHTTP: Bool) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, scheme == "https" || allowHTTP && scheme == "http",
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw RuntimeError.bridge("Invalid provider: \(field) must be a public endpoint without credentials, query, or fragment")
        }
    }

    static func validateHeader(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RuntimeError.bridge("Invalid provider: invalid HTTP header name")
        }
    }

    private static func secretName(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["authorization", "proxy_authorization", "cookie", "set_cookie", "api_key", "apikey", "access_token", "refresh_token", "id_token", "client_secret", "password", "secret"].contains(normalized) || normalized.hasSuffix("_api_key")
    }

    private static func containsSecret(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields): fields.contains { secretName($0.key) || containsSecret($0.value) }
        case .array(let values): values.contains(where: containsSecret)
        default: false
        }
    }
}
