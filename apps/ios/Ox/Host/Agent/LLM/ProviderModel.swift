import Foundation

nonisolated public enum ProviderModelVariant: String, Sendable, Codable {
    case fast
}

nonisolated public enum ProviderModelModality: String, Sendable, Codable, CaseIterable, Hashable {
    case text
    case image
    case pdf
    case audio
    case video
}

nonisolated public struct ProviderModelModalities: Sendable, Codable, Equatable {
    public var input: Set<ProviderModelModality>
    public var output: Set<ProviderModelModality>

    public init(input: Set<ProviderModelModality>, output: Set<ProviderModelModality>) {
        self.input = input
        self.output = output
    }

    public static let text = ProviderModelModalities(input: [.text], output: [.text])
}

nonisolated public struct ProviderModel: Sendable, Codable {
    public var id: String
    public var providerModelID: String?
    public var variant: ProviderModelVariant?
    public var displayName: String
    public var maxTokens: Int
    public var maxContext: Int
    public var supportsTools: Bool?
    public var reasoning: Bool
    public var reasoningEfforts: [String]
    public var reasoningEffort: String?
    public var modalities: ProviderModelModalities
    public var wireID: String { providerModelID ?? id }
    public var lowestReasoningEffort: String? { reasoningEfforts.first }
    public var selectedReasoningEffort: String? {
        reasoningEffort.flatMap { reasoningEfforts.contains($0) ? $0 : nil } ?? lowestReasoningEffort
    }

    public init(
        id: String,
        providerModelID: String? = nil,
        variant: ProviderModelVariant? = nil,
        displayName: String,
        maxTokens: Int,
        maxContext: Int,
        supportsTools: Bool? = nil,
        reasoning: Bool = false,
        reasoningEfforts: [String] = [],
        reasoningEffort: String? = nil,
        modalities: ProviderModelModalities = .text
    ) {
        self.id = id
        self.providerModelID = providerModelID
        self.variant = variant
        self.displayName = displayName
        self.maxTokens = maxTokens
        self.maxContext = maxContext
        self.supportsTools = supportsTools
        self.reasoning = reasoning
        self.reasoningEfforts = reasoningEfforts
        self.reasoningEffort = reasoningEffort
        self.modalities = modalities
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerModelID, variant, displayName, maxTokens, maxContext, supportsTools, reasoning, reasoningEfforts, reasoningEffort, modalities
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        providerModelID = try values.decodeIfPresent(String.self, forKey: .providerModelID)
        variant = try values.decodeIfPresent(ProviderModelVariant.self, forKey: .variant)
        displayName = try values.decode(String.self, forKey: .displayName)
        maxTokens = try values.decode(Int.self, forKey: .maxTokens)
        maxContext = try values.decode(Int.self, forKey: .maxContext)
        supportsTools = try values.decodeIfPresent(Bool.self, forKey: .supportsTools)
        reasoning = try values.decodeIfPresent(Bool.self, forKey: .reasoning) ?? false
        reasoningEfforts = try values.decodeIfPresent([String].self, forKey: .reasoningEfforts) ?? []
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        modalities = try values.decodeIfPresent(ProviderModelModalities.self, forKey: .modalities) ?? .text
    }
}
