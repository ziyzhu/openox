import Foundation

nonisolated struct BundledProviderDefinition: Sendable, Codable {
    var definition: ProviderDefinition
    var presentation: ProviderPresentation
    var legacyID: String
    var legacyRegion: LLMRegion?
    var legacyCredentialID: String
    var discovery: ProviderModelDiscovery?
}
