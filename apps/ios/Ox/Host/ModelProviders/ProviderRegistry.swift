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

    private let builtInClients: [LLMRegion: [any ProviderClient]]
    private(set) var customProviders: [CustomLLMProvider] {
        didSet { Self.persist(customProviders) }
    }
    private(set) var customProviderLoading: Set<UUID> = []
    private(set) var customProviderErrors: [UUID: String] = [:]

    var clients: [any ProviderClient] {
        clients(for: defaultRegion)
    }

    private(set) var defaultModel: ModelSelection {
        didSet { Self.persist(defaultModel) }
    }

    var defaultClient: String { defaultModel.providerID }
    var defaultRegion: LLMRegion { defaultModel.region }

    nonisolated static let defaultModelKey = "llm.defaultModel"
    nonisolated static let customProvidersKey = "llm.customProviders"

    private init() {
        let detectedRegion = AppRegion.shared.region
        let providerModels = Self.loadProviderModels()
        let modelLookup = { (clientID: String, region: LLMRegion) in
            providerModels.models(for: clientID, in: region)
        }
        var prefixClients: [any ProviderClient] = []
        if MockLLMClient.isEnabled {
            prefixClients.append(MockLLMClient())
            Log.agent.info("ProviderRegistry added MockLLMClient")
        }
        var builtInClients: [LLMRegion: [any ProviderClient]] = [:]
        for candidate in LLMRegion.allCases {
            var clients = prefixClients
            clients.append(contentsOf: BuiltInProviders.clients(for: candidate, modelLookup: modelLookup))
            builtInClients[candidate] = clients
        }
        let customProviders = Self.loadCustomProviders()
        let storedDefault = UserDefaults.standard.data(forKey: Self.defaultModelKey).flatMap {
            try? JSONDecoder().decode(ModelSelection.self, from: $0)
        }
        let region = storedDefault?.region ?? detectedRegion
        let configuredClients = builtInClients[region, default: []] + customProviders.map(\.client)
        let availableClients = configuredClients.filter { client in
            client.models.contains { client.supportsTools(for: $0) }
        }
        let fallbackClient = availableClients[0]
        let fallbackModel = fallbackClient.models.first { fallbackClient.supportsTools(for: $0) }!
        let resolvedDefault: ModelSelection
        if let storedDefault,
           let client = configuredClients.first(where: { $0.id == storedDefault.providerID }),
           let model = client.models.first(where: { $0.id == storedDefault.modelID && client.supportsTools(for: $0) }) {
            resolvedDefault = ModelSelection(
                region: storedDefault.region,
                providerID: client.id,
                modelID: model.id,
                reasoningEffort: storedDefault.reasoningEffort.flatMap {
                    model.reasoningEfforts.contains($0) ? $0 : nil
                } ?? model.lowestReasoningEffort
            )
        } else if let storedDefault,
                  customProviders.contains(where: { $0.clientID == storedDefault.providerID }),
                  !storedDefault.modelID.isEmpty {
            resolvedDefault = storedDefault
        } else {
            resolvedDefault = ModelSelection(
                region: region,
                providerID: fallbackClient.id,
                modelID: fallbackModel.id,
                reasoningEffort: fallbackModel.lowestReasoningEffort
            )
        }
        self.builtInClients = builtInClients
        self.customProviders = customProviders
        self.defaultModel = resolvedDefault
        Self.persist(resolvedDefault)
        Log.agent.info("ProviderRegistry ready clients=[\(self.clients.map(\.id).joined(separator: ","))] default=\(resolvedDefault.providerID)/\(resolvedDefault.modelID) region=\(resolvedDefault.region.rawValue) detectedRegion=\(detectedRegion.rawValue)")
        for provider in customProviders {
            Task { [weak self] in
                await self?.refresh(provider)
            }
        }
    }

    func client(id: String) -> (any ProviderClient)? {
        clients.first { $0.id == id }
    }

    func client(id: String, in region: LLMRegion) -> (any ProviderClient)? {
        clients(for: region).first { $0.id == id && $0.regions.contains(region) }
    }

    func isCustomProviderPending(clientID: String) -> Bool {
        guard let provider = customProviders.first(where: { $0.clientID == clientID }) else { return false }
        return provider.models.isEmpty && customProviderErrors[provider.id] == nil
    }

    func clients(in region: LLMRegion) -> [any ProviderClient] {
        clients(for: region).filter { $0.regions.contains(region) }
    }

    func client(for selection: ModelSelection?) -> any ProviderClient {
        let selection = selection ?? defaultModel
        if let client = client(id: selection.providerID, in: selection.region) { return client }
        if let provider = customProviders.first(where: { $0.clientID == selection.providerID }) { return provider.client }
        return newSessionClient
    }

    func model(for selection: ModelSelection?, client: any ProviderClient) -> ProviderModel {
        let selection = selection ?? defaultModel
        if var model = client.models.first(where: { $0.id == selection.modelID }) {
            model.reasoningEffort = selection.reasoningEffort.flatMap {
                model.reasoningEfforts.contains($0) ? $0 : nil
            } ?? model.lowestReasoningEffort
            return model
        }
        if customProviders.contains(where: { $0.clientID == client.id }) {
            return CustomLLMModel(id: selection.modelID, supportsTools: true).modelInfo
        }
        return selected(for: client.id, in: selection.region)
    }

    var newSessionClient: any ProviderClient {
        let region = defaultRegion
        let inRegion = clients(in: region)
        if let preferred = client(id: defaultClient), preferred.regions.contains(region), !preferred.models.isEmpty {
            return preferred
        }
        return inRegion.first(where: { !$0.models.isEmpty }) ?? clients.first(where: { !$0.models.isEmpty })!
    }

    var defaultClientModel: ProviderModel {
        selected(for: defaultClient, in: defaultRegion)
    }

    func selected(for clientID: String) -> ProviderModel {
        selected(for: clientID, in: defaultRegion)
    }

    func selected(for clientID: String, in region: LLMRegion) -> ProviderModel {
        let regionalClients = clients(in: region)
        let client = regionalClients.first { $0.id == clientID } ?? regionalClients[0]
        if defaultModel.region == region,
           defaultModel.providerID == client.id,
           var model = client.models.first(where: { $0.id == defaultModel.modelID }) {
            model.reasoningEffort = reasoningEffort(for: model, in: client.id, region: region)
            return model
        }
        var model = client.models.first ?? newSessionClient.models[0]
        model.reasoningEffort = reasoningEffort(for: model, in: client.id, region: region)
        return model
    }

    func reasoningEffort(for model: ProviderModel, in clientID: String, region: LLMRegion) -> String? {
        let stored = defaultModel.region == region
            && defaultModel.providerID == clientID
            && defaultModel.modelID == model.id
            ? defaultModel.reasoningEffort
            : nil
        return stored.flatMap { model.reasoningEfforts.contains($0) ? $0 : nil } ?? model.lowestReasoningEffort
    }

    func select(_ model: ProviderModel, in clientID: String, region: LLMRegion) {
        defaultModel = ModelSelection(
            region: region,
            providerID: clientID,
            modelID: model.id,
            reasoningEffort: model.selectedReasoningEffort
        )
        Log.agent.info("ProviderRegistry.select client=\(clientID) model=\(model.id) reasoning=\(model.selectedReasoningEffort ?? "unavailable") region=\(region.rawValue)")
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
        Credentials.clear(for: provider.client.credentialID)
        if defaultClient == provider.clientID {
            let client = builtInClients[defaultRegion]![0]
            let model = client.models[0]
            defaultModel = ModelSelection(
                region: defaultRegion,
                providerID: client.id,
                modelID: model.id,
                reasoningEffort: model.lowestReasoningEffort
            )
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

    private static func persist(_ selection: ModelSelection) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(selection), forKey: defaultModelKey)
        } catch {
            Log.agent.error("ProviderRegistry.defaultModel encode failed error=\(error.localizedDescription)")
        }
    }

    private func clients(for region: LLMRegion) -> [any ProviderClient] {
        let candidates = builtInClients[region, default: []] + customProviders.map(\.client)
        return candidates.filter { client in
            client.models.contains { client.supportsTools(for: $0) }
        }
    }

}
