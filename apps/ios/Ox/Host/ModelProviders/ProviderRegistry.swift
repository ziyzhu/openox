import Foundation
import Observation

@MainActor
@Observable
final class ProviderRegistry {
    static let shared = ProviderRegistry()

    private struct ProviderModelsFile: Decodable {
        struct Provider: Decodable {
            let global: RegionalModels?
            let china: RegionalModels?

            func models(in region: LLMRegion) -> [ProviderModel]? {
                switch region {
                case .global: global?.models.map(\.model)
                case .china: china?.models.map(\.model)
                }
            }
        }

        struct RegionalModels: Decodable {
            struct Entry: Decodable {
                let model: ProviderModel
            }

            let models: [Entry]
        }

        let providers: [String: Provider]

        func models(for clientID: String, in region: LLMRegion) -> [ProviderModel] {
            guard let models = providers[clientID]?.models(in: region) else {
                fatalError("Missing provider models for \(clientID) in \(region.rawValue)")
            }
            return models
        }
    }

    private let builtInClients: [LLMRegion: [any LLMClient]]
    private(set) var customProviders: [CustomLLMProvider] {
        didSet { Self.persist(customProviders) }
    }
    private(set) var customProviderLoading: Set<UUID> = []
    private(set) var customProviderErrors: [UUID: String] = [:]

    var clients: [any LLMClient] {
        clients(for: AppRegion.shared.region)
    }

    private var selectedModelIds: [String: String] {
        didSet { UserDefaults.standard.set(selectedModelIds, forKey: Self.selectedKey) }
    }

    private var selectedReasoningEfforts: [String: String] {
        didSet { UserDefaults.standard.set(selectedReasoningEfforts, forKey: Self.selectedReasoningEffortsKey) }
    }

    private(set) var defaultClient: String {
        didSet { UserDefaults.standard.set(defaultClient, forKey: Self.defaultClientKey) }
    }

    private static let selectedKey = "llm.selectedModels"
    private static let selectedReasoningEffortsKey = "llm.selectedReasoningEfforts"
    private static let defaultClientKey = "llm.defaultClient"
    static let customProvidersKey = "llm.customProviders"

    private init() {
        let region = AppRegion.shared.region
        let providerModels = Self.loadProviderModels()
        let modelLookup = { (clientID: String, region: LLMRegion) in
            providerModels.models(for: clientID, in: region)
        }
        let leadingClients: [any LLMClient] = [
            ChatGPTResponsesClient(models: modelLookup("chatgpt", .global)),
            GeminiClient(models: modelLookup("gemini", .global)),
            GitHubCopilotClient(models: modelLookup("github-copilot", .global)),
        ]
        let middleClients: [any LLMClient] = [
            OpenAIClient.make(models: modelLookup("openai", .global)),
            AnthropicClient.make(models: modelLookup("anthropic", .global)),
            BedrockClient(models: modelLookup("amazon-bedrock", .global)),
            XAIClient.make(models: modelLookup("xai", .global)),
        ]
        var prefixClients: [any LLMClient] = []
        if MockLLMClient.isEnabled {
            prefixClients.append(MockLLMClient())
            Log.agent.info("ProviderRegistry added MockLLMClient")
        }
        var builtInClients: [LLMRegion: [any LLMClient]] = [:]
        for candidate in LLMRegion.allCases {
            var clients = prefixClients
            clients.append(contentsOf: leadingClients)
            clients.append(contentsOf: Self.leadingClients(for: candidate, modelLookup: modelLookup))
            clients.append(contentsOf: middleClients)
            clients.append(contentsOf: Self.trailingClients(for: candidate, modelLookup: modelLookup))
            builtInClients[candidate] = clients
        }
        let customProviders = Self.loadCustomProviders()
        let configuredClients = builtInClients[region, default: []] + customProviders.map(\.client)
        let availableClients = configuredClients.filter { client in
            client.models.contains { client.supportsTools(for: $0) }
        }
        self.builtInClients = builtInClients
        self.customProviders = customProviders
        self.selectedModelIds = UserDefaults.standard.dictionary(forKey: Self.selectedKey) as? [String: String] ?? [:]
        self.selectedReasoningEfforts = UserDefaults.standard.dictionary(forKey: Self.selectedReasoningEffortsKey) as? [String: String] ?? [:]
        let configuredClientIDs = Set(availableClients.map(\.id) + customProviders.map(\.clientID))
        let storedDefault = UserDefaults.standard.string(forKey: Self.defaultClientKey)
        self.defaultClient = storedDefault.flatMap { configuredClientIDs.contains($0) ? $0 : nil } ?? availableClients[0].id
        UserDefaults.standard.set(self.defaultClient, forKey: Self.defaultClientKey)
        Log.agent.info("ProviderRegistry ready clients=[\(self.clients.map(\.id).joined(separator: ","))] default=\(self.defaultClient) region=\(region.rawValue)")
        for provider in customProviders {
            Task { [weak self] in
                await self?.refresh(provider)
            }
        }
    }

    func client(id: String) -> (any LLMClient)? {
        clients.first { $0.id == id }
    }

    func client(id: String, in region: LLMRegion) -> (any LLMClient)? {
        clients(for: region).first { $0.id == id && $0.regions.contains(region) }
    }

    func isCustomProviderPending(clientID: String) -> Bool {
        guard let provider = customProviders.first(where: { $0.clientID == clientID }) else { return false }
        return provider.models.isEmpty && customProviderErrors[provider.id] == nil
    }

    func clients(in region: LLMRegion) -> [any LLMClient] {
        clients(for: region).filter { $0.regions.contains(region) }
    }

    func client(forSnapshot id: String?) -> any LLMClient {
        if let id, let client = client(id: id) { return client }
        if let id, let provider = customProviders.first(where: { $0.clientID == id }) { return provider.client }
        return newSessionClient
    }

    func model(forSnapshot id: String?, reasoningEffort: String?, client: any LLMClient) -> ProviderModel {
        if let id, var model = client.models.first(where: { $0.id == id }) {
            model.reasoningEffort = reasoningEffort
            return model
        }
        if let id, customProviders.contains(where: { $0.clientID == client.id }) {
            return CustomLLMModel(id: id, supportsTools: true).modelInfo
        }
        return selected(for: client.id)
    }

    var newSessionClient: any LLMClient {
        let region = AppRegion.shared.region
        let inRegion = clients(in: region)
        if let preferred = client(id: defaultClient), preferred.regions.contains(region), !preferred.models.isEmpty {
            return preferred
        }
        return inRegion.first(where: { !$0.models.isEmpty }) ?? clients.first(where: { !$0.models.isEmpty })!
    }

    var defaultClientModel: ProviderModel {
        selected(for: defaultClient)
    }

    func selected(for clientID: String) -> ProviderModel {
        selected(for: clientID, in: AppRegion.shared.region)
    }

    func selected(for clientID: String, in region: LLMRegion) -> ProviderModel {
        let regionalClients = clients(in: region)
        let client = regionalClients.first { $0.id == clientID } ?? regionalClients[0]
        if let modelId = selectedModelIds[client.id],
           var model = client.models.first(where: { $0.id == modelId }) {
            model.reasoningEffort = reasoningEffort(for: model, in: client.id)
            return model
        }
        var model = client.models.first ?? newSessionClient.models[0]
        model.reasoningEffort = reasoningEffort(for: model, in: client.id)
        return model
    }

    func reasoningEffort(for model: ProviderModel, in clientID: String) -> String? {
        let stored = selectedReasoningEfforts[reasoningSelectionKey(clientID: clientID, modelID: model.id)]
        return stored.flatMap { model.reasoningEfforts.contains($0) ? $0 : nil } ?? model.lowestReasoningEffort
    }

    func select(_ model: ProviderModel, in clientID: String) {
        selectedModelIds[clientID] = model.id
        let reasoningKey = reasoningSelectionKey(clientID: clientID, modelID: model.id)
        if let effort = model.selectedReasoningEffort {
            selectedReasoningEfforts[reasoningKey] = effort
        } else {
            selectedReasoningEfforts.removeValue(forKey: reasoningKey)
        }
        defaultClient = clientID
        Log.agent.info("ProviderRegistry.select client=\(clientID) model=\(model.id) reasoning=\(model.selectedReasoningEffort ?? "unavailable")")
    }

    func upsert(_ provider: CustomLLMProvider) {
        customProviderErrors.removeValue(forKey: provider.id)
        if let index = customProviders.firstIndex(where: { $0.id == provider.id }) {
            customProviders[index] = provider
            Log.agent.info("ProviderRegistry.custom updated client=\(provider.clientID) models=\(provider.models.count)")
        } else {
            customProviders.append(provider)
            Log.agent.info("ProviderRegistry.custom added client=\(provider.clientID) models=\(provider.models.count)")
        }
    }

    func refresh(_ provider: CustomLLMProvider) async {
        guard !customProviderLoading.contains(provider.id) else { return }
        customProviderLoading.insert(provider.id)
        customProviderErrors.removeValue(forKey: provider.id)
        defer { customProviderLoading.remove(provider.id) }
        do {
            let models = try await CustomLLMProviderDiscovery.models(
                baseURL: provider.baseURL,
                apiKey: Credentials.key(for: provider.clientID)
            )
            guard let index = customProviders.firstIndex(where: {
                $0.id == provider.id && $0.baseURL == provider.baseURL
            }) else { return }
            customProviders[index].models = models
            Log.agent.info("ProviderRegistry.custom discovered client=\(provider.clientID) models=\(models.count)")
        } catch {
            guard customProviders.contains(where: {
                $0.id == provider.id && $0.baseURL == provider.baseURL
            }) else { return }
            customProviderErrors[provider.id] = error.localizedDescription
            Log.agent.error("ProviderRegistry.custom discovery failed client=\(provider.clientID) error=\(error.localizedDescription)")
        }
    }

    func remove(_ provider: CustomLLMProvider) {
        customProviders.removeAll { $0.id == provider.id }
        customProviderLoading.remove(provider.id)
        customProviderErrors.removeValue(forKey: provider.id)
        selectedModelIds.removeValue(forKey: provider.clientID)
        selectedReasoningEfforts = selectedReasoningEfforts.filter { !$0.key.hasPrefix("\(provider.clientID)\u{1F}") }
        Credentials.clear(for: provider.client.credentialID)
        if defaultClient == provider.clientID {
            defaultClient = builtInClients[AppRegion.shared.region]![0].id
        }
        Log.agent.info("ProviderRegistry.custom removed client=\(provider.clientID)")
    }

    private static func loadProviderModels() -> ProviderModelsFile {
        guard let url = Bundle.main.url(forResource: "provider-models", withExtension: "json") else {
            fatalError("Missing bundled provider-models.json")
        }
        do {
            let value = try JSONDecoder().decode(ProviderModelsFile.self, from: Data(contentsOf: url))
            Log.agent.info("ProviderRegistry loaded provider models providers=\(value.providers.count)")
            return value
        } catch {
            fatalError("Invalid bundled provider-models.json: \(error.localizedDescription)")
        }
    }

    private static func loadCustomProviders() -> [CustomLLMProvider] {
        UserDefaults.standard.data(forKey: customProvidersKey).flatMap {
            try? JSONDecoder().decode([CustomLLMProvider].self, from: $0)
        } ?? []
    }

    private static func persist(_ providers: [CustomLLMProvider]) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(providers), forKey: customProvidersKey)
        } catch {
            Log.agent.error("ProviderRegistry.custom encode failed error=\(error.localizedDescription)")
        }
    }

    private func clients(for region: LLMRegion) -> [any LLMClient] {
        let candidates = builtInClients[region, default: []] + customProviders.map(\.client)
        return candidates.filter { client in
            client.models.contains { client.supportsTools(for: $0) }
        }
    }

    private func reasoningSelectionKey(clientID: String, modelID: String) -> String {
        "\(clientID)\u{1F}\(modelID)"
    }
}
