import Foundation

extension OxHostProtocol {
    struct EvalToolSchema: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    struct EvaluateAgentResult: Encodable {
        let messages: [Message]
        let systemPrompt: String
        let tools: [EvalToolSchema]
        let temperature: Double?
        let maxTokens: Int?
        let totalMs: Int
        let errors: [String]
        let executionError: String?
    }

    @MainActor
    static func handleEvaluateAgent(_ command: EvaluateAgentRequest, conversationManager: ConversationManager, reply: OxHostRPC.Reply) {
        Log.agent.warning("OxHostRPC.agents.evaluate refused: native post-turn eval limits unsupported by Pi Durable")
        reply.failure("This eval workflow requires a native post-turn stop hook that Pi Durable does not support. No input was submitted and no provider or tool was invoked.")
    }
}
