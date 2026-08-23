import Foundation

nonisolated struct Shoveler: Codable, Equatable, Sendable {
    let cards: [ShovelerCard]
}

nonisolated struct ShovelerCard: Codable, Equatable, Sendable {
    let image: String?
    let title: String?
    let description: String?
    let badge: String?
    let artifact: Artifact?
}
