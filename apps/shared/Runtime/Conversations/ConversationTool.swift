import Foundation

nonisolated final class ConversationTool: AgentTool, @unchecked Sendable {
    private struct ModelOutput: Sendable {
        let text: String
        let truncated: Bool
    }

    weak var conversation: Conversation?
    init(conversation: Conversation) { self.conversation = conversation }

    var name: String { Self.schema.name }
    var description: String { Self.schema.description }
    var parameters: JSONValue { Self.schema.parameters }

    static let schema = ToolSchema(
        name: "execute",
        description: executeDescription(),
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "purpose": .object([
                    "type": .string("string"),
                    "description": .string("Short (<10 words) description of this execution."),
                    "minLength": .int(1),
                    "maxLength": .int(80),
                ]),
                "source": .object([
                    "type": .string("string"),
                    "description": .string("JavaScript snippet body. Use `await`; emit text with `console.log` or `return`, and images with `await image(block)`."),
                    "minLength": .int(1),
                    "maxLength": .int(100_000),
                ])
            ]),
            "required": .array([.string("purpose"), .string("source")]),
            "additionalProperties": .bool(false),
        ])
    )

    private static func executeDescription() -> String {
        ModelGuidance.execute(
            catalog: OxFunctionCatalog.descriptions(),
            timeoutSeconds: Int(VirtualMachine.defaultTimeout),
            maxOutputTokens: JavaScriptOutputLimits.maxOutputTokens,
            maxFetches: WebExecutionLimits.maxFetches,
            maxTransientAttachments: WebExecutionLimits.maxTransientAttachments
        )
    }

    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
        try await execute(toolCallId: toolCallId, args: args, failureNote: nil)
    }

    func execute(toolCallId: String, args: JSONValue, failureNote: (@MainActor (String) -> String?)?) async throws -> ToolResult {
        guard let source = args.objectValue?["source"]?.stringValue else {
            Log.session.warning("tool.execute rejected: missing 'source' (id=\(toolCallId))")
            return ToolResult(text: "missing 'source'", isError: true)
        }
        Log.session.info("tool.execute id=\(toolCallId) purpose=\(LogPrivacy.text(args.objectValue?["purpose"]?.stringValue ?? "", limit: 80)) source=\(LogPrivacy.text(source, limit: 4_096))")
        return try await execute(source: source, failureNote: failureNote)
    }

    @MainActor
    private func execute(source: String, failureNote: (@MainActor (String) -> String?)?) async throws -> ToolResult {
        guard let session = conversation else { return ToolResult(text: "Conversation is no longer available", isError: true) }
        session.beginExecution(source: source)
        do {
            return try await execute(source: source, in: session, failureNote: failureNote)
        } catch {
            session.finishExecution(output: error.localizedDescription, isError: true)
            throw error
        }
    }

    @MainActor
    private func execute(source: String, in session: Conversation, failureNote: (@MainActor (String) -> String?)?) async throws -> ToolResult {
        let output: ModelOutput
        let diagnosticContent: JSONValue?
        var logs: [VirtualMachineLog]
        var failure: String?
        do {
            let out = try await session.virtualMachine.run(source: source, bridge: session) { attachment in
                try session.appendTransientAttachment(attachment)
            }
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
            output = try await modelOutput(logs: logs, error: failure, store: session.javaScriptOutputs)
        } catch {
            failure = error.localizedDescription
            output = ModelOutput(text: "[error] \(error.localizedDescription)\n\n\(try Self.failureReceipt(invocations, omittedCalls: session.executionOmittedInvocations()))", truncated: true)
        }
        diagnosticContent = output.truncated ? nil : await logOutput(logs: logs, error: failure)
        let failed = failure != nil
        Log.session.info("tool.output maxOutputTokens=\(JavaScriptOutputLimits.maxOutputTokens) outputBytes=\(output.text.utf8.count) truncated=\(output.truncated)")
        if failed, let note = failureNote?(failure ?? output.text) { try? session.appendReportedProgress(note) }
        session.finishExecution(output: output.text, isError: failed)
        return ToolResult(
            content: [.text(TextContent(output.text))] + attachments.files.map(ContentBlock.attachment),
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

    @concurrent
    private func modelOutput(logs: [VirtualMachineLog], error: String?, store: JavaScriptOutputStore) async throws -> ModelOutput {
        var lines = logs.map { log in
            log.level == "log" ? log.message : "[\(log.level)] \(log.message)"
        }
        if let error { lines.append("[error] \(error)") }
        let output = lines.joined(separator: "\n")
        guard !output.isEmpty else { return ModelOutput(text: "(no output)", truncated: false) }
        guard let excerpt = JavaScriptOutputLimits.excerpt(output) else {
            return ModelOutput(text: output, truncated: false)
        }
        var path = JSONValue.null
        var saveError = JSONValue.null
        do {
            path = .string(try await store.save(output))
        } catch {
            Log.session.error("tool.output save failed outputBytes=\(output.utf8.count) error=\(error.localizedDescription)")
            saveError = .string(error.localizedDescription)
        }
        let characters = output.utf16.count
        let omitted = characters - excerpt.head.utf16.count - excerpt.tail.utf16.count
        let text = try ModelPromptRenderer.shared.render(.outputTruncation, input: .object([
            "head": .string(String(excerpt.head)), "tail": .string(String(excerpt.tail)),
            "originalTokens": .int(JavaScriptOutputLimits.tokens(characters: characters)),
            "totalLines": .int(output.utf8.reduce(1) { $0 + ($1 == 10 ? 1 : 0) }),
            "truncatedTokens": .int(JavaScriptOutputLimits.tokens(characters: omitted)),
            "path": path, "saveError": saveError,
        ]))
        return ModelOutput(text: text, truncated: true)
    }

    @concurrent
    private func logOutput(logs: [VirtualMachineLog], error: String?) async -> JSONValue {
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
