import Foundation
import Observation

nonisolated struct ProviderCatalog: Codable, Equatable, Sendable {
    var format = 2
    var providers: [ProviderDefinition] = []

    func validate() throws {
        guard format == 2, Set(providers.map(\.id)).count == providers.count else {
            throw RuntimeError.bridge("Invalid or unsupported provider catalog")
        }
        for provider in providers {
            _ = try ProviderDefinition.decode(provider.json)
            try ProviderClientFactory.validateAdapter(provider)
        }
    }
}

@MainActor
@Observable
final class ProviderRegistry {
    static let shared = ProviderRegistry()
    nonisolated static let defaultModelKey = "llm.defaultModel"
    nonisolated static let customProvidersKey = "llm.customProviders"
    nonisolated static let catalogKey = "llm.providerCatalog"

    private let bundled: [BundledProviderDefinition]
    private var catalog: ProviderCatalog
    private var catalogAvailable = true
    private(set) var allClients: [any ProviderClient] = []
    private(set) var defaultModel: ModelSelection?

    private init() {
        bundled = Self.bundledDefinitions()
        do {
            if let data = UserDefaults.standard.data(forKey: Self.catalogKey) {
                catalog = try JSONDecoder().decode(ProviderCatalog.self, from: data)
                try catalog.validate()
            } else { catalog = ProviderCatalog() }
        } catch {
            catalog = ProviderCatalog()
            catalogAvailable = false
            Log.agent.error("ProviderRegistry catalog unavailable error=\(error.localizedDescription)")
        }
        defaultModel = UserDefaults.standard.data(forKey: Self.defaultModelKey).flatMap { try? JSONDecoder().decode(ModelSelection.self, from: $0) }
        rebuildClients()
        Log.agent.info("ProviderRegistry ready definitions=\(definitions.count) default=\(defaultModel?.providerID ?? "unconfigured")")
    }

    nonisolated static func bundledDefinitions() -> [BundledProviderDefinition] {
        struct File: Decodable {
            struct Provider: Decodable {
                struct Regional: Decodable {
                    struct Entry: Decodable { let model: ProviderModel }
                    let models: [Entry]
                }
                let global: Regional?
                let china: Regional?
            }
            let providers: [String: Provider]
        }
        guard let url = Bundle.main.url(forResource: "provider-models", withExtension: "json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            fatalError("Missing bundled provider models")
        }
        return BuiltInProviders.definitions { id, region in
            let entry = file.providers[id]
            let models = region == .global ? entry?.global?.models : entry?.china?.models
            guard let models else { fatalError("Missing provider models \(id)/\(region.rawValue)") }
            return models.map(\.model)
        }
    }

    var definitions: [ProviderDefinition] {
        let replacements = Dictionary(uniqueKeysWithValues: catalog.providers.map { ($0.id, $0) })
        let bundledIDs = Set(bundled.map { $0.definition.id })
        return bundled.map { replacements[$0.definition.id] ?? $0.definition }
            + catalog.providers.filter { !bundledIDs.contains($0.id) }
    }
    var defaultDefinitions: [ProviderDefinition] { bundled.map(\.definition) }

    var clients: [any ProviderClient] { allClients.filter { !$0.models.isEmpty } }
    var defaultClient: String { sessionModel.providerID }
    var defaultRegion: LLMRegion { region(for: defaultModel?.providerID) }

    var sessionModel: ModelSelection {
        if let defaultModel { return defaultModel }
        let client = clients(in: AppRegion.shared.region).first ?? clients.first ?? unavailableClient
        return ModelSelection(providerID: client.id, modelID: client.models.first!.id, reasoningEffort: client.models.first!.lowestReasoningEffort)
    }

    var newSessionClient: any ProviderClient { client(for: sessionModel) }
    var defaultClientModel: ProviderModel { model(for: sessionModel, client: newSessionClient) }

    func definition(id: String) throws -> ProviderDefinition {
        guard let definition = definitions.first(where: { $0.id == id }) else { throw RuntimeError.bridge("Provider not found: \(id)") }
        return definition
    }

    func region(for id: String?) -> LLMRegion {
        let regions = id.flatMap { target in bundled.first { $0.definition.id == target }?.presentation.regions }
        if regions?.count == 1 { return regions!.first! }
        return AppRegion.shared.region
    }

    func client(id: String) -> (any ProviderClient)? { allClients.first { $0.id == id } }
    func client(id: String, in region: LLMRegion) -> (any ProviderClient)? { client(id: id) }
    func clients(in region: LLMRegion) -> [any ProviderClient] { clients.filter { $0.regions.contains(region) } }

    func client(for selection: ModelSelection?) -> any ProviderClient {
        let selection = selection ?? sessionModel
        return client(id: selection.providerID) ?? unavailableClient
    }

    func model(for selection: ModelSelection?, client: any ProviderClient) -> ProviderModel {
        let selection = selection ?? sessionModel
        if var model = client.models.first(where: { $0.id == selection.modelID }) {
            model.reasoningEffort = selection.reasoningEffort.flatMap { model.reasoningEfforts.contains($0) ? $0 : nil } ?? model.lowestReasoningEffort
            return model
        }
        return ProviderModel(id: selection.modelID, displayName: selection.modelID, maxTokens: 4_096, maxContext: 32_768, supportsTools: true)
    }

    func selected(for clientID: String) -> ProviderModel { selected(for: clientID, in: defaultRegion) }
    func selected(for clientID: String, in region: LLMRegion) -> ProviderModel {
        let client = client(id: clientID) ?? unavailableClient
        if let selection = defaultModel, selection.providerID == clientID { return model(for: selection, client: client) }
        return client.models.first ?? unavailableClient.models[0]
    }

    func reasoningEffort(for model: ProviderModel, in clientID: String, region: LLMRegion) -> String? {
        guard let selection = defaultModel, selection.providerID == clientID, selection.modelID == model.id else { return model.lowestReasoningEffort }
        return selection.reasoningEffort.flatMap { model.reasoningEfforts.contains($0) ? $0 : nil } ?? model.lowestReasoningEffort
    }

    func select(_ model: ProviderModel, in clientID: String, region: LLMRegion) {
        let selection = ModelSelection(providerID: clientID, modelID: model.id, reasoningEffort: model.selectedReasoningEffort)
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(selection), forKey: Self.defaultModelKey)
            defaultModel = selection
            Log.agent.info("ProviderRegistry.select provider=\(clientID) model=\(model.id)")
        } catch { Log.agent.error("ProviderRegistry.select failed error=\(error.localizedDescription)") }
    }

    func save(_ definition: ProviderDefinition) throws {
        _ = try ProviderDefinition.decode(definition.json)
        try ProviderClientFactory.validateAdapter(definition)
        _ = try ProviderClientFactory.make(definition, presentation: presentation(for: definition))
        var next = catalog
        if let index = next.providers.firstIndex(where: { $0.id == definition.id }) {
            next.providers[index] = definition
        } else { next.providers.append(definition) }
        try persist(next)
        rebuildClients()
        Log.agent.info("ProviderRegistry.save provider=\(definition.id) models=\(definition.models.count)")
    }

    func updateDiscoveredModels(_ models: [ProviderModel], for clientID: String) throws {
        guard client(id: clientID)?.canLoadModels == true,
              let bundledDefinition = bundled.first(where: { $0.definition.id == clientID })?.definition,
              let defaultModel = bundledDefinition.models.first else {
            throw RuntimeError.bridge("Model discovery is unavailable for this provider")
        }
        var definition = try definition(id: clientID)
        definition.models = [defaultModel] + models.map { ProviderDefinition.Model($0) }
        try save(definition)
    }

    func delete(id: String) throws {
        let definition = try definition(id: id)
        guard catalog.providers.contains(where: { $0.id == id }) else {
            throw RuntimeError.bridge("Provider has no saved override: \(id)")
        }
        var next = catalog
        next.providers.removeAll { $0.id == id }
        try persist(next)
        deauthenticate(definition)
        if defaultModel?.providerID == id {
            UserDefaults.standard.removeObject(forKey: Self.defaultModelKey)
            defaultModel = nil
        }
        rebuildClients()
        Log.agent.info("ProviderRegistry.delete provider=\(id)")
    }

    func deauthenticate(_ definition: ProviderDefinition) {
        do { try Secret.unbind(.provider, id: definition.credentialID) }
        catch { Log.agent.error("ProviderRegistry.deauthenticate secret unavailable error=\(error.localizedDescription)") }
        if let account = client(id: definition.id)?.subscriptionAccount { account.signOut() }
        else if definition.auth.kind == .oauth { ProviderOAuthAccount(definition).signOut() }
        Log.agent.info("ProviderRegistry.deauthenticate provider=\(definition.id)")
    }

    func authenticationStatus(id: String) -> String {
        guard let definition = try? definition(id: id) else { return "unavailable" }
        if definition.api == .web { return "browser-session" }
        if definition.auth.kind == .none { return "not-required" }
        if client(id: id)?.subscriptionAccount?.isSignedIn == true { return "authenticated" }
        if Credentials.key(for: definition.credentialID) != nil { return "credential-stored" }
        return definition.auth.requiresCredential ? "required" : "optional"
    }

    private func presentation(for definition: ProviderDefinition) -> ProviderPresentation {
        bundled.first { $0.definition.id == definition.id }?.presentation ?? ProviderPresentation(inferenceLocation: .userHosted)
    }

    private func persist(_ next: ProviderCatalog) throws {
        guard catalogAvailable else { throw RuntimeError.bridge("Provider catalog is unavailable. Open a compatible Ox version before making changes.") }
        try next.validate()
        let data = try JSONEncoder().encode(next)
        UserDefaults.standard.set(data, forKey: Self.catalogKey)
        guard UserDefaults.standard.data(forKey: Self.catalogKey) == data else { throw RuntimeError.bridge("Provider catalog could not be saved") }
        catalog = next
    }

    private func rebuildClients() {
        var resolved: [any ProviderClient] = []
        if MockLLMClient.isEnabled { resolved.append(MockLLMClient()) }
        for definition in definitions {
            do { resolved.append(try ProviderClientFactory.make(definition, presentation: presentation(for: definition))) }
            catch { Log.agent.error("ProviderRegistry.resolve provider=\(definition.id) error=\(error.localizedDescription)") }
        }
        allClients = resolved
    }

    private var unavailableClient: any ProviderClient { UnavailableProviderClient() }

    var customProviders: [CustomLLMProvider] {
        definitions.compactMap { definition in
            guard definition.id.hasPrefix("custom:"), let id = UUID(uuidString: String(definition.id.dropFirst(7))) else { return nil }
            return CustomLLMProvider(id: id, name: definition.name, baseURL: definition.url,
                                     models: definition.models.map { CustomLLMModel(id: $0.id, displayName: $0.name, maxTokens: $0.outputTokens ?? 4_096, maxContext: $0.contextTokens ?? 32_768) })
        }
    }
    var customProviderLoading: Set<UUID> { [] }
    var customProviderErrors: [UUID: String] { [:] }
    func isCustomProviderPending(clientID: String) -> Bool { false }

    func upsert(_ provider: CustomLLMProvider) {
        do { try save(provider.definition) }
        catch { Log.agent.error("ProviderRegistry.custom save failed error=\(error.localizedDescription)") }
    }

    func remove(_ provider: CustomLLMProvider) {
        do { try delete(id: provider.clientID) }
        catch { Log.agent.error("ProviderRegistry.custom delete failed error=\(error.localizedDescription)") }
    }
}

nonisolated private struct UnavailableProviderClient: ProviderClient {
    let id = "unconfigured"
    let displayName = "Model"
    let models = [ProviderModel(id: "unconfigured", displayName: "Model", maxTokens: 4_096, maxContext: 32_768)]

    func stream(model: ProviderModel, systemPrompt: String?, messages: [Message], tools: [any AgentTool], options: StreamOptions) -> AsyncThrowingStream<AssistantEvent, Error> {
        streamingTask(model: model, messages: messages) { _ in
            throw RuntimeError.bridge("The selected provider is unavailable. Choose another model in Settings.")
        }
    }
}
