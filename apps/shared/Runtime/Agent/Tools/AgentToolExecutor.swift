import Foundation

nonisolated enum AgentToolExecutor {
    static func execute(
        _ toolCall: ToolCall,
        assistantMessage: AssistantMessage,
        context: AgentContext,
        beforeToolCall: BeforeToolCallHook?,
        afterToolCall: AfterToolCallHook?
    ) async -> (ToolResultMessage, Bool) {
        guard let tool = context.tools.first(where: { $0.name == toolCall.name }) else {
            Log.agent.error("executeTool: unknown tool=\(toolCall.name) id=\(toolCall.id)")
            return (errorResult(toolCall, "Tool \(toolCall.name) not found"), false)
        }

        let definitions = tool.parameters.objectValue?["$defs"]?.objectValue ?? [:]
        let violations = JSONSchemaValidator.validate(
            toolCall.arguments,
            against: tool.parameters,
            definitions: definitions
        )
        if !violations.isEmpty {
            let detail = violations.map { "\($0.path) \($0.message)" }.joined(separator: "; ")
            Log.agent.warning("executeTool: invalid arguments tool=\(toolCall.name) id=\(toolCall.id) detail=\(detail)")
            return (errorResult(toolCall, "Invalid arguments for \(toolCall.name): \(detail)"), false)
        }

        if let before = await beforeToolCall?(BeforeToolCallContext(
            assistantMessage: assistantMessage,
            toolCall: toolCall,
            context: context
        )), before.block {
            return (errorResult(toolCall, before.reason ?? "Tool execution was blocked"), false)
        }

        let executed: (ToolResultMessage, Bool)
        do {
            let result = try await tool.execute(toolCallId: toolCall.id, args: toolCall.arguments)
            executed = (ToolResultMessage(
                toolCallId: toolCall.id,
                providerCallID: toolCall.providerCallID,
                toolName: toolCall.name,
                content: result.content,
                diagnostics: result.diagnostics,
                isError: result.isError,
                truncated: result.truncated,
                transientAttachments: result.transientAttachments,
                activatedSkills: result.activatedSkills
            ), result.terminate)
        } catch {
            Log.agent.error("executeTool: tool=\(toolCall.name) id=\(toolCall.id) threw: \(error.localizedDescription)")
            executed = (errorResult(toolCall, error.localizedDescription), false)
        }

        guard let after = await afterToolCall?(AfterToolCallContext(
            assistantMessage: assistantMessage,
            toolCall: toolCall,
            context: context,
            result: executed.0,
            terminate: executed.1
        )) else { return executed }

        var message = executed.0
        if let content = after.content {
            message.content = content
            message.diagnostics = nil
        }
        if let isError = after.isError { message.isError = isError }
        return (message, after.terminate ?? executed.1)
    }

    private static func errorResult(_ toolCall: ToolCall, _ text: String) -> ToolResultMessage {
        ToolResultMessage(
            toolCallId: toolCall.id,
            providerCallID: toolCall.providerCallID,
            toolName: toolCall.name,
            content: ToolResult(text: text).content,
            isError: true
        )
    }
}
