import Foundation

extension OxHostProtocol {
    /// The public contract is platform-independent; experimental cache execution
    /// remains unavailable outside explicitly opted-in DEBUG Simulator campaigns.
    @MainActor
    static func handleDurableExperiment(_ method: Method, params: JSONValue, chats: ChatManager, reply: OxHostRPC.Reply) throws {
        #if DEBUG && targetEnvironment(simulator)
        let data = try JSONEncoder().encode(params)
        switch method {
        case .durableStorage: handleDurableStorage(try JSONDecoder().decode(DurableStorageRequest.self, from: data), reply: reply)
        case .durableChat: handleDurableChat(try JSONDecoder().decode(DurableChatRequest.self, from: data), chats: chats, reply: reply)
        default: reply.failure("Unknown Pi Durable experiment")
        }
        #else
        reply.failure("Pi Durable experiments require a DEBUG Simulator build")
        #endif
    }
}
