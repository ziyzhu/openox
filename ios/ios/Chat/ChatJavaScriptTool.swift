import Foundation

nonisolated final class ChatJavaScriptTool: AgentTool, @unchecked Sendable {
    private static let maximumModelOutputCharacters = 16_000
    private static let retainedModelOutputTailCharacters = 4_000

    private struct ModelOutput {
        let text: String
        let truncated: Bool
    }

    let chat: Chat
    init(chat: Chat) { self.chat = chat }

    var name: String { Self.schema.name }
    var description: String { Self.schema.description }
    var parameters: JSONValue { Self.schema.parameters }

    static let schema = ToolSchema(
        name: "execute",
        description: executeDescription(),
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "source": .object([
                    "type": .string("string"),
                    "description": .string("JavaScript snippet body. Use `await`; print model-visible data with `console.log`. Return values are discarded."),
                    "minLength": .int(1),
                    "maxLength": .int(100_000),
                ])
            ]),
            "required": .array([.string("source")]),
            "additionalProperties": .bool(false),
        ])
    )

    private static func executeDescription() -> String {
        return """
        Run JavaScript inside an async function. `await` works. Print model-visible results with `console.log`; return values are discarded. Use `ox.user` and service handoff helpers when the snippet must wait for the user.

        The `ox` namespace provides these built-in capabilities:

        \(OxFunctionCatalog.helpTree())

        Built-in signatures printed in the tree are callable contracts. Every built-in function exposes a synchronous, non-enumerable `.help()` method that returns its complete description, input schema, and output schema as compact text. Call a built-in directly when the shown fields cover the task. For nested options or output details omitted from a compact signature, inspect that function first, for example `ox.web.fetch.help()`. Inspect several independent functions in one JavaScript object when useful. Never infer option names from another API.

        Every operational `ox.*` call requires a short `purpose` describing the visible step; `.help()` does not. Attached-service summaries intentionally omit actions. Use `ox.service.listAttached({ kind?, purpose })` when current attachment state is needed; `kind` filters `web`, `ios`, or `mcp` services. Call `ox.service.inspect({ domain, purpose })` for a compact exposed-action index and any user-controlled payment contract, then request the full action contracts needed with `ox.service.inspect({ domain, actions: ["<action-id>"], purpose })` before invoking them. Invoke only backend-qualified names returned by service inspection: `web:<domain>:<action>`, `ios:<app>:<action>`, or `mcp:<server>:<action>`. Use `ox.service.solve` only for a service-declared human-verification handoff, and `ox.service.pay` only after preparing and pricing the transaction through exposed actions. Copy returned identifiers and option shapes exactly. Never guess omitted fields or probe with intentionally invalid calls. If a built-in error includes `Full help`, correct the call directly from that schema.

        JavaScript has 60 seconds of active execution time. Waiting for a service action, sign-in, verification, payment, or user choice does not consume that time. Each execution may call `ox.web.fetch` at most eight times and add at most four transient attachments to model context; presented artifacts do not count toward that attachment limit. Every execution is self-contained: never store state on `globalThis`. Batch larger work across executions and print concise progress, cursors, or partial results so the next execution can continue, or persist continuation state through an authorized virtual file.

        Combine dependent operations in one snippet when they fit these budgets; parallelize independent operations within the same limits. Keep intermediate results in JavaScript; filter, aggregate, project fields, and limit rows before printing only what the next reasoning step needs. For web research, avoid fetching the same URL twice in one run and stop gathering when authoritative evidence answers the request. Surface thrown errors instead of retrying blindly.
        """
    }

    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
        guard let source = args.objectValue?["source"]?.stringValue else {
            Log.session.warning("tool.execute rejected: missing 'source' (id=\(toolCallId))")
            let output = logOutput(logs: [], error: "missing 'source'")
            let modelOutput = modelOutput(logs: [], error: "missing 'source'")
            return ToolResult(text: modelOutput.text, diagnosticContent: output, isError: true, truncated: modelOutput.truncated)
        }
        Log.session.info("tool.execute id=\(toolCallId) source=\(LogPrivacy.text(source, limit: 4_096))")
        return await execute(source: source)
    }

    @MainActor
    private func execute(source: String) async -> ToolResult {
        let session = chat
        session.beginExecution(source: source)
        let output: ModelOutput
        let diagnosticContent: JSONValue?
        let failed: Bool
        do {
            let out = try await session.virtualMachine.run(source: source, bridge: session)
            diagnosticContent = logOutput(logs: out.logs, error: nil)
            output = modelOutput(logs: out.logs, error: nil)
            failed = false
        } catch {
            let logs: [VirtualMachineLog] = (error as? VirtualMachine.Error)?.logs ?? []
            diagnosticContent = logOutput(logs: logs, error: error.localizedDescription)
            output = modelOutput(logs: logs, error: error.localizedDescription)
            failed = true
        }
        let attachments = session.executionAttachments()
        let activatedSkills = session.executionActivatedSkills()
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

    private func modelOutput(logs: [VirtualMachineLog], error: String?) -> ModelOutput {
        var lines = logs.map { log in
            log.level == "log" ? log.message : "[\(log.level)] \(log.message)"
        }
        if let error { lines.append("[error] \(error)") }
        let output = lines.joined(separator: "\n")
        guard !output.isEmpty else { return ModelOutput(text: "(no output)", truncated: false) }
        guard output.count > Self.maximumModelOutputCharacters else {
            return ModelOutput(text: output, truncated: false)
        }
        let omittedCharacters = output.count - Self.maximumModelOutputCharacters
        let marker = "\n[Tool output truncated: omitted \(omittedCharacters) characters]\n"
        let tailCount = min(Self.retainedModelOutputTailCharacters, Self.maximumModelOutputCharacters - marker.count)
        let headCount = Self.maximumModelOutputCharacters - marker.count - tailCount
        let text = String(output.prefix(headCount)) + marker + String(output.suffix(tailCount))
        return ModelOutput(text: text, truncated: true)
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
