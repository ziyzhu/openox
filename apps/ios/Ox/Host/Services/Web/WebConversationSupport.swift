import Foundation

nonisolated struct WebsiteProviderError: ProviderClientError {
    let message: String
    let failureKind: LLMFailureKind

    init(_ message: String, kind: LLMFailureKind = .provider) {
        self.message = message
        failureKind = kind
    }
}

nonisolated struct WebsiteAttachment: Sendable {
    let name: String
    let mimeType: String
    let data: Data
}
