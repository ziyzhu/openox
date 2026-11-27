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
        var returned: String?
        var failure: String?
        let started = ContinuousClock.now
        do {
            let out = try await session.virtualMachine.run(source: source, bridge: session) { attachment in
                try session.appendTransientAttachment(attachment)
            }
            logs = out.logs
            returned = out.value.map { $0.stringValue ?? $0.jsonString() }
        } catch {
            logs = (error as? VirtualMachine.Error)?.logs ?? []
            failure = error.localizedDescription
        }
        let wallTime = ContinuousClock.now - started
        let attachments = session.executionAttachments()
        let activatedSkills = session.executionActivatedSkills()
        let invocations = session.executionInvocations()
        if let error = failure, !invocations.isEmpty {
            failure = "\(error)\n\n\(try Self.failureReceipt(invocations, omittedCalls: session.executionOmittedInvocations()))"
        }
        do {
            output = try await modelOutput(logs: logs, returned: returned, error: failure, wallTime: wallTime, store: session.javaScriptOutputs)
        } catch {
            failure = error.localizedDescription
            output = ModelOutput(text: "[error] \(error.localizedDescription)\n\n\(try Self.failureReceipt(invocations, omittedCalls: session.executionOmittedInvocations()))", truncated: true)
        }
        diagnosticContent = output.truncated ? nil : await logOutput(logs: logs + (returned.map { [VirtualMachineLog(level: "log", message: $0)] } ?? []), error: failure)
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
    private func modelOutput(logs: [VirtualMachineLog], returned: String?, error: String?, wallTime: Duration, store: JavaScriptOutputStore) async throws -> ModelOutput {
        var items = returned.map { [$0] } ?? []
        if !logs.isEmpty {
            let console = logs.map { $0.level == "log" ? $0.message : "[\($0.level)] \($0.message)" }
            items.append("<console_output>\n\(console.joined(separator: "\n"))\n</console_output>")
        }
        if let error { items.append("Script error:\n\(error)") }
        let output = items.joined(separator: "\n")
        let seconds = Double(wallTime.components.seconds) + Double(wallTime.components.attoseconds) * 1e-18
        let header = "\(error == nil ? "Script completed" : "Script failed")\nWall time \(String(format: "%.1f", seconds)) seconds\nOutput:\n"
        guard let excerpt = JavaScriptOutputLimits.excerpt(output) else {
            return ModelOutput(text: header + output, truncated: false)
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
        return ModelOutput(text: header + text, truncated: true)
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
