import Foundation

nonisolated enum ModelsDevCatalog {
    private struct CatalogFile: Decodable, Sendable {
        let models: [String: CanonicalModel]
        let providers: [String: Provider]
    }

    private struct CanonicalModel: Decodable, Sendable {}

    private struct Provider: Decodable, Sendable {
        let models: [String: Model]
    }

    private struct Model: Decodable, Sendable {
        struct ReasoningOption: Decodable, Sendable {
            let type: String
            let values: [String?]?
        }

        struct Limit: Decodable, Sendable {
            let context: Int
            let output: Int
        }

        let id: String
        let name: String
        let status: String?
        let toolCall: Bool
        let reasoning: Bool
        let reasoningOptions: [ReasoningOption]?
        let modalities: ProviderModelModalities
        let limit: Limit

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case status
            case toolCall = "tool_call"
            case reasoning
            case reasoningOptions = "reasoning_options"
            case modalities
            case limit
        }

        var reasoningEfforts: [String] {
            reasoningOptions?
                .filter { $0.type == "effort" }
                .flatMap { $0.values ?? [] }
                .compactMap { $0 } ?? []
        }
    }

    private struct SelectionFile: Decodable, Sendable {
        let providers: [String: ProviderSelection]
    }

    private struct ProviderSelection: Decodable, Sendable {
        let global: RegionalSelection?
        let china: RegionalSelection?

        func value(for region: LLMRegion) -> RegionalSelection? {
            switch region {
            case .global: global
            case .china: china
            }
        }
    }

    private struct RegionalSelection: Decodable, Sendable {
        let catalogProvider: String
        let models: [ModelSelection]
    }

    private struct ModelSelection: Decodable, Sendable {
        let source: String
        let id: String?
        let providerModelID: String?
        let displayName: String?
        let variant: ProviderModelVariant?
        let maxTokens: Int?
        let maxContext: Int?
    }

    private struct Storage: Sendable {
        let catalog: CatalogFile
        let selection: SelectionFile

        init() {
            catalog = Self.load("models-dev-catalog", as: CatalogFile.self)
            selection = Self.load("models-dev-selection", as: SelectionFile.self)
            Log.agent.info("ModelsDevCatalog loaded canonical=\(catalog.models.count) providers=\(catalog.providers.count) selections=\(selection.providers.count)")
        }

        func models(for clientID: String, in region: LLMRegion) -> [ProviderModel] {
            guard let selectedProvider = selection.providers[clientID]?.value(for: region) else {
                fatalError("Missing models.dev selection for \(clientID) in \(region.rawValue)")
            }
            guard let provider = catalog.providers[selectedProvider.catalogProvider] else {
                fatalError("Missing models.dev provider \(selectedProvider.catalogProvider) for \(clientID)")
            }
            return selectedProvider.models.map { selected in
                guard let source = provider.models[selected.source] else {
                    fatalError("Missing models.dev model \(selectedProvider.catalogProvider)/\(selected.source)")
                }
                guard source.status == nil || source.status == "active",
                      source.toolCall,
                      source.modalities.input.contains(.text),
                      source.modalities.output.contains(.text),
                      source.limit.context > 0,
                      source.limit.output > 0 else {
                    fatalError("Incompatible models.dev model \(selectedProvider.catalogProvider)/\(selected.source)")
                }
                let id = selected.id ?? source.id
                let providerModelID = selected.providerModelID ?? (id == selected.source ? nil : selected.source)
                let baseDisplayName = selected.displayName ?? source.name
                let displayName = selected.variant == .fast ? "\(baseDisplayName) · Fast" : baseDisplayName
                return ProviderModel(
                    id: id,
                    providerModelID: providerModelID,
                    variant: selected.variant,
                    displayName: displayName,
                    maxTokens: min(selected.maxTokens ?? source.limit.output, source.limit.output),
                    maxContext: min(selected.maxContext ?? source.limit.context, source.limit.context),
                    supportsTools: source.toolCall,
                    reasoning: source.reasoning,
                    reasoningEfforts: source.reasoningEfforts,
                    modalities: source.modalities
                )
            }
        }

        private static func load<Value: Decodable>(_ name: String, as: Value.Type) -> Value {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
                fatalError("Missing bundled \(name).json")
            }
            do {
                return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
            } catch {
                fatalError("Invalid bundled \(name).json: \(error.localizedDescription)")
            }
        }
    }

    private static let storage = Storage()

    static func models(for clientID: String, in region: LLMRegion = .global) -> [ProviderModel] {
        storage.models(for: clientID, in: region)
    }

}
