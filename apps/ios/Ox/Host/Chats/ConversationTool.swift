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

    private static let websiteDescription = """
    Run JavaScript inside an async function. `await` works. Print model-visible results with `console.log` or a top-level `return`. Use `ox.user` and service handoff helpers when the snippet must wait for the user.

    The `ox` namespace provides these built-in capabilities:

    \(OxFunctionCatalog.helpTree(includesSummaries: false))

    Signatures shown above are callable contracts. Every built-in also has a synchronous `.help()` method for its complete description, input schema, and output schema. Inspect unfamiliar or nested options before use. Every operational `ox.*` call requires a short `purpose` describing the visible step; `.help()` does not.

    Each execution is self-contained. The runtime waits for up to 60 seconds of active execution time; this does not forcibly stop an infinite JavaScript loop. Waiting for a service action or user handoff does not consume that time. Keep intermediate results in JavaScript and print or return only concise model-visible output. Use `Promise.allSettled` for independent reads when partial success is useful; serialize writes and approval-dependent operations. Calls are not rolled back on failure; inspect outcomes before retrying writes.
    """

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

    private static func executeDescription() -> String {
        return """
        Run JavaScript inside an async function. `await` works. Print model-visible results with `console.log` or a top-level `return`. Use `ox.user` and service handoff helpers when the snippet must wait for the user.

        The `ox` namespace provides these built-in capabilities:

        \(OxFunctionCatalog.helpTree())

        Built-in signatures printed in the tree are callable contracts. Every built-in function exposes a synchronous, non-enumerable `.help()` method that returns its complete description, input schema, and output schema as compact text. Call a built-in directly when the shown fields cover the task. For nested options or output details omitted from a compact signature, inspect that function first, for example `ox.web.fetch.help()`. Inspect several independent functions in one JavaScript object when useful. Never infer option names from another API.

        Every operational `ox.*` call requires a short `purpose` describing the visible step; `.help()` does not. Attached-service summaries intentionally omit actions. Use `ox.service.list({ kind?, purpose })` to list all available services, or `ox.service.listAttached({ kind?, purpose })` when current attachment state is needed; `kind` filters `web`, `api`, `ios`, or `mcp` services. Call `ox.service.inspect({ domain, purpose })` for a compact exposed-action index and any user-controlled payment contract, then request the full action contracts needed with `ox.service.inspect({ domain, actions: ["<action-id>"], purpose })` before invoking them. Invoke only backend-qualified names returned by service inspection: `web:<domain>:<action>`, `api:<service>:<action>`, `ios:<app>:<action>`, or `mcp:<server>:<action>`. Use `ox.service.solve` only for a service-declared human-verification handoff, and `ox.service.pay` only after preparing and pricing the transaction through exposed actions. Copy returned identifiers and option shapes exactly. Never guess omitted fields or probe with intentionally invalid calls. If a built-in error includes `Full help`, correct the call directly from that schema.

        The runtime waits for up to 60 seconds of active execution time; this does not forcibly stop an infinite JavaScript loop. Use bounded loops. Waiting for a service action, sign-in, verification, payment, or user choice does not consume that time. Each execution may call `ox.web.fetch` at most eight times and add at most four transient attachments to model context; presented artifacts do not count toward that attachment limit. Every execution is self-contained: never store state on `globalThis`. Batch larger work across executions and print concise progress, cursors, or partial results so the next execution can continue, or persist continuation state through an authorized virtual file.

        Combine dependent operations in one snippet when they fit these budgets. Parallelize independent reads with `Promise.allSettled` when partial success is useful; an uncaught `Promise.all` rejection ends the execution and cancels pending calls. Serialize writes and approval-dependent operations. Await every call whose outcome matters; pending unawaited calls are cancelled when the snippet ends. Keep intermediate results in JavaScript; filter, aggregate, project fields, and limit rows before printing or returning only what the next reasoning step needs. Print caught errors as `error.message` or `console.error(error)`, not JSON. Calls are real and are not rolled back on script failure. Use the failure receipt and inspect external state before retrying a write; failed or incomplete calls may still have had an effect.

        File reads return complete text into JavaScript by default. Combined console and return output is limited to the last \(JavaScriptOutputLimits.maxLines) lines or \(JavaScriptOutputLimits.maxBytes / 1024) KiB, whichever is reached first, independent of the model. Oversized output includes a reference for `ox.output.read`; retrieve the complete string, then print the relevant slice or filtered result. Do not treat a truncated preview as the complete record. Output references are chat-local and expire when the chat is unloaded.
        """
    }

    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
        guard let source = args.objectValue?["source"]?.stringValue else {
            Log.session.warning("tool.execute rejected: missing 'source' (id=\(toolCallId))")
            return ToolResult(text: "missing 'source'", isError: true)
        }
        Log.session.info("tool.execute id=\(toolCallId) source=\(LogPrivacy.text(source, limit: 4_096))")
        return await execute(source: source)
    }

    @MainActor
    private func execute(source: String) async -> ToolResult {
        guard let session = chat else { return ToolResult(text: "Conversation is no longer available", isError: true) }
        session.beginExecution(source: source)
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
            failure = "\(error)\n\n\(Self.failureReceipt(invocations))"
        }
        do {
            output = try modelOutput(logs: logs, error: failure, store: session.javaScriptOutputs)
        } catch {
            failure = error.localizedDescription
            output = ModelOutput(text: "[error] \(error.localizedDescription)\n\n\(Self.failureReceipt(invocations))", truncated: true)
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

    private static func failureReceipt(_ invocations: [Invocation]) -> String {
        func status(_ invocation: Invocation) -> String {
            switch invocation.outcome {
            case .succeeded: "succeeded"
            case .failed: "failed"
            case .running: "incomplete/unknown outcome"
            }
        }
        let rows = invocations.count <= 20 ? invocations : Array(invocations.prefix(10)) + Array(invocations.suffix(10))
        let counts = invocations.reduce(into: [String: Int]()) { $0[status($1), default: 0] += 1 }
        let summary = counts.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        var lines = ["Execution receipt (\(invocations.count) calls; \(summary)):"]
        lines += rows.map { invocation in
            let name = invocation.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "- \(String(name.prefix(160))) [\(invocation.id.uuidString)]: \(status(invocation))"
        }
        if invocations.count > rows.count { lines.append("\(invocations.count - rows.count) middle calls omitted from this receipt.") }
        lines.append("Calls are not rolled back. Verify external state before retrying writes, including failed or incomplete calls.")
        return lines.joined(separator: "\n")
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
        let marker = "\n[Tool output truncated: showing the tail (\(JavaScriptOutputLimits.maxLines) lines or \(JavaScriptOutputLimits.maxBytes / 1024) KiB limit). Full output id: \(id). Read with ox.output.read({ id: '\(id)', purpose: 'Read remaining output' }), then filter or slice before printing. Reference expires when this chat is unloaded.]"
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
