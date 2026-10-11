import Foundation

extension OxHostProtocol {
    /// The public contract is platform-independent; experimental cache execution
    /// remains unavailable outside explicitly opted-in DEBUG Simulator campaigns.
    @MainActor
    static func handleDurableExperiment(_ method: Method, params: JSONValue, chats: ConversationManager, reply: OxHostRPC.Reply) throws {
        #if DEBUG && targetEnvironment(simulator)
        let data = try JSONEncoder().encode(params)
        switch method {
        case .durableStorage: handleDurableStorage(try JSONDecoder().decode(DurableStorageRequest.self, from: data), reply: reply)
        case .durableChat: handleDurableConversation(try JSONDecoder().decode(DurableConversationRequest.self, from: data), conversations: chats, reply: reply)
        default: reply.failure("Unknown Pi Durable experiment")
        }
        #else
        reply.failure("Pi Durable experiments require a DEBUG Simulator build")
        #endif
    }
}
