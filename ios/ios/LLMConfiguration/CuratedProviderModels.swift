import Foundation

nonisolated enum CuratedProviderModels {
    static let arkGlobal = [
        ProviderModel(
            id: "dola-seed-2-1-turbo-260628",
            displayName: "Dola Seed 2.1 Turbo",
            maxTokens: 16_384,
            maxContext: 262_144,
            supportsTools: true
        ),
    ]

    static let arkChina = [
        ProviderModel(
            id: "doubao-seed-2-0-lite-260428",
            displayName: "Doubao Seed 2.0 Lite",
            maxTokens: 16_384,
            maxContext: 262_144,
            supportsTools: true
        ),
    ]
}
