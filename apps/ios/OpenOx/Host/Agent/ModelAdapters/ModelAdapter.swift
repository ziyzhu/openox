import Foundation

nonisolated enum ModelAdapterOutcome: Sendable {
    case unchanged
    case transformed([Message])
    case failed
}

nonisolated protocol ModelAdapter: Sendable {
    var id: String { get }
    func transform(messages: [Message], model: ProviderModel) async -> ModelAdapterOutcome
}

nonisolated enum ModelAdapterPipeline {
    private static let adapters: [any ModelAdapter] = [ToolExchangeAdapter(), VisionImageAdapter()]

    static func transform(messages: [Message], model: ProviderModel) async -> [Message] {
        var transformed = messages
        for adapter in adapters {
            switch await adapter.transform(messages: transformed, model: model) {
            case .unchanged:
                continue
            case .transformed(let messages):
                transformed = messages
                Log.agent.info("ModelAdapter transformed adapter=\(adapter.id) model=\(model.id) messages=\(messages.count)")
            case .failed:
                Log.agent.error("ModelAdapter failed adapter=\(adapter.id) model=\(model.id)")
                return transformed
            }
        }
        return transformed
    }
}
