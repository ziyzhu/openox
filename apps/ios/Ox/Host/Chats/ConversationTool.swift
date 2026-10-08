import Foundation

nonisolated final class ConversationTool: AgentTool, @unchecked Sendable {
    private struct ModelOutput {
        let text: String
        let truncated: Bool
    }

    weak var chat: Conversation?
    init(chat: Conversation) { self.chat = chat }

    var name: String { Self.schema.name }
    var description: String { Self.schema.description }
    var websiteDescription: String { Self.websiteDescription }
    var parameters: JSONValue { Self.schema.parameters }

    private static let websiteDescription = executeDescription(website: true)

    static let schema = ToolSchema(
        name: "execute",
        description: executeDescription(),
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "source": .object([
                    "type": .string("string"),
                    "description": .string("JavaScript snippet body. Use `await`; print model-visible data with `console.log` or a top-level `return`."),
                    "minLength": .int(1),
                    "maxLength": .int(100_000),
                ])
            ]),
            "required": .array([.string("source")]),
            "additionalProperties": .bool(false),
        ])
    )

    private static func executeDescription(website: Bool = false) -> String {
        ModelGuidance.execute(
            catalog: OxFunctionCatalog.helpTree(),
            website: website,
            timeoutSeconds: Int(VirtualMachine.defaultTimeout),
            maxLines: JavaScriptOutputLimits.maxLines,
            maxBytes: JavaScriptOutputLimits.maxBytes,
            maxFetches: WebExecutionLimits.maxFetches,
            maxTransientAttachments: WebExecutionLimits.maxTransientAttachments
        )
    }

    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
        guard let source = args.objectValue?["source"]?.stringValue else {
            Log.session.warning("tool.execute rejected: missing 'source' (id=\(toolCallId))")
            return ToolResult(text: "missing 'source'", isError: true)
        }
        Log.session.info("tool.execute id=\(toolCallId) source=\(LogPrivacy.text(source, limit: 4_096))")
        return try await execute(source: source)
    }

    @MainActor
    private func execute(source: String) async throws -> ToolResult {
        guard let session = chat else { return ToolResult(text: "Conversation is no longer available", isError: true) }
        session.beginExecution(source: source)
        do {
            return try await execute(source: source, in: session)
        } catch {
            session.finishExecution(output: error.localizedDescription, isError: true)
            throw error
        }
    }

    @MainActor
    private func execute(source: String, in session: Conversation) async throws -> ToolResult {
        let output: ModelOutput
        let diagnosticContent: JSONValue?
        var logs: [VirtualMachineLog]
        var failure: String?
        do {
            let out = try await session.virtualMachine.run(source: source, bridge: session)
            logs = out.logs
            if let value = out.value {
                logs.append(VirtualMachineLog(level: "log", message: value.stringValue ?? value.jsonString()))
            }
        } catch {
            logs = (error as? VirtualMachine.Error)?.logs ?? []
            failure = error.localizedDescription
        }
        let attachments = session.executionAttachments()
        let activatedSkills = session.executionActivatedSkills()
        let invocations = session.executionInvocations()
        if let error = failure, !invocations.isEmpty {
            failure = "\(error)\n\n\(try Self.failureReceipt(invocations, omittedCalls: session.executionOmittedInvocations()))"
        }
        do {
            output = try modelOutput(logs: logs, error: failure, store: session.javaScriptOutputs)
        } catch {
            failure = error.localizedDescription
            output = ModelOutput(text: "[error] \(error.localizedDescription)\n\n\(try Self.failureReceipt(invocations, omittedCalls: session.executionOmittedInvocations()))", truncated: true)
        }
        diagnosticContent = output.truncated ? nil : logOutput(logs: logs, error: failure)
        let failed = failure != nil
        Log.session.info("tool.output maxBytes=\(JavaScriptOutputLimits.maxBytes) maxLines=\(JavaScriptOutputLimits.maxLines) outputBytes=\(output.text.utf8.count) truncated=\(output.truncated)")
        session.finishExecution(output: output.text, isError: failed)
        return ToolResult(
            content: [.text(TextContent(output.text))] + attachments.artifacts.map(ContentBlock.attachment),
            diagnosticContent: diagnosticContent,
            isError: failed,
            truncated: output.truncated,
            transientAttachments: attachments.transient,
            activatedSkills: activatedSkills
        )
    }

    private static func failureReceipt(_ invocations: [Invocation], omittedCalls: Int) throws -> String {
        let facts = invocations.map { invocation -> JSONValue in
            let state: String = switch invocation.outcome {
            case .succeeded: "succeeded"
            case .failed: "failed"
            case .running: "running"
            }
            return .object(["id": .string(invocation.id.uuidString), "name": .string(invocation.name), "state": .string(state)])
        }
        return try ModelPromptRenderer.shared.render(.failureReceipt, input: .object(["invocations": .array(facts), "omittedCalls": .int(omittedCalls)]))
    }

    @MainActor
    private func modelOutput(logs: [VirtualMachineLog], error: String?, store: JavaScriptOutputStore) throws -> ModelOutput {
        var lines = logs.map { log in
            log.level == "log" ? log.message : "[\(log.level)] \(log.message)"
        }
        if let error { lines.append("[error] \(error)") }
        let output = lines.joined(separator: "\n")
        guard !output.isEmpty else { return ModelOutput(text: "(no output)", truncated: false) }
        let preview = JavaScriptOutputLimits.preview(output)
        guard preview != output else {
            return ModelOutput(text: output, truncated: false)
        }
        let id = try store.save(output)
        let marker = try ModelPromptRenderer.shared.render(.outputTruncation, input: .object([
            "id": .string(id), "maxLines": .int(JavaScriptOutputLimits.maxLines), "maxBytes": .int(JavaScriptOutputLimits.maxBytes),
        ]))
        return ModelOutput(text: preview + marker, truncated: true)
    }

    private func logOutput(logs: [VirtualMachineLog], error: String?) -> JSONValue {
        var entries = logs.map { log in
            JSONValue.object([
                "level": .string(log.level),
                "text": .string(log.message),
            ])
        }
        if let error {
            entries.append(.object([
                "level": .string("error"),
                "text": .string(error),
            ]))
        }
        return .array(entries)
    }
}
