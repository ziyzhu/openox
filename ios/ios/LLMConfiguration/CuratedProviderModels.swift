import Foundation

nonisolated enum CuratedProviderModels {
    static let arkGlobal = [
        seedModel(
            id: "dola-seed-2-1-turbo-260628",
            displayName: "Dola Seed 2.1 Turbo",
            maxTokens: 256_000,
            maxContext: 256_000
        ),
        seedModel(
            id: "seed-2-0-code-preview-260328",
            displayName: "Dola Seed 2.0 Code",
            maxTokens: 131_072,
            maxContext: 262_144,
            reasoningEfforts: standardReasoningEfforts
        ),
        seedModel(
            id: "seed-2-0-pro-260328",
            displayName: "Dola Seed 2.0 Pro",
            maxTokens: 128_000,
            maxContext: 256_000,
            reasoningEfforts: standardReasoningEfforts
        ),
        seedModel(
            id: "seed-2-0-lite-260428",
            displayName: "Dola Seed 2.0 Lite",
            maxTokens: 32_000,
            maxContext: 256_000,
            reasoningEfforts: standardReasoningEfforts
        ),
        seedModel(
            id: "seed-2-0-mini-260428",
            displayName: "Dola Seed 2.0 Mini",
            maxTokens: 32_000,
            maxContext: 256_000,
            reasoningEfforts: standardReasoningEfforts
        ),
    ]

    static let arkChina = [
        seedModel(
            id: "doubao-seed-2-1-pro",
            displayName: "Doubao Seed 2.1 Pro",
            maxTokens: 256_000,
            maxContext: 256_000
        ),
        seedModel(
            id: "doubao-seed-2-1-turbo",
            displayName: "Doubao Seed 2.1 Turbo",
            maxTokens: 256_000,
            maxContext: 256_000
        ),
        seedModel(
            id: "doubao-seed-character",
            displayName: "Doubao Seed Character",
            maxTokens: 256_000,
            maxContext: 256_000
        ),
        seedModel(
            id: "doubao-seed-evolving",
            displayName: "Doubao Seed Evolving",
            maxTokens: 256_000,
            maxContext: 256_000
        ),
        seedModel(
            id: "doubao-seed-2-0-code-preview-260328",
            displayName: "Doubao Seed 2.0 Code",
            maxTokens: 131_072,
            maxContext: 262_144,
            reasoningEfforts: standardReasoningEfforts
        ),
        seedModel(
            id: "doubao-seed-2-0-pro-260328",
            displayName: "Doubao Seed 2.0 Pro",
            maxTokens: 128_000,
            maxContext: 256_000,
            reasoningEfforts: standardReasoningEfforts
        ),
        seedModel(
            id: "doubao-seed-2-0-lite-260428",
            displayName: "Doubao Seed 2.0 Lite",
            maxTokens: 32_000,
            maxContext: 256_000,
            reasoningEfforts: standardReasoningEfforts
        ),
        seedModel(
            id: "doubao-seed-2-0-mini-260428",
            displayName: "Doubao Seed 2.0 Mini",
            maxTokens: 32_000,
            maxContext: 256_000,
            reasoningEfforts: standardReasoningEfforts
        ),
    ]

    static let arkReasoningReplayModelIDs = Set((arkGlobal + arkChina).map(\.wireID))

    private static let standardReasoningEfforts = ["minimal", "low", "medium", "high"]
    private static let multimodal = ProviderModelModalities(input: [.text, .image, .video], output: [.text])

    private static func seedModel(
        id: String,
        displayName: String,
        maxTokens: Int,
        maxContext: Int,
        reasoningEfforts: [String] = []
    ) -> ProviderModel {
        ProviderModel(
            id: id,
            displayName: displayName,
            maxTokens: maxTokens,
            maxContext: maxContext,
            supportsTools: true,
            reasoning: true,
            reasoningEfforts: reasoningEfforts,
            modalities: multimodal
        )
    }
}
