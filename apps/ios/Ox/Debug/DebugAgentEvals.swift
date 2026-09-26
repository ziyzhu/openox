#if targetEnvironment(simulator)
import Foundation

extension OxHostProtocol {
    struct EvaluateAgentRequest: Decodable {
        let sessionId: String
        let clientId: String
        let modelId: String
        let prompts: [String]
        let fixtures: [AgentEvalFixture]
        let maxTurns: Int
        let timeoutMs: Int
    }

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
    static func handleEvaluateAgent(_ command: EvaluateAgentRequest, chatManager: ChatManager, reply: OxHostRPC.Reply) {
        guard (1...10).contains(command.prompts.count), command.prompts.allSatisfy({ !$0.isEmpty }),
              (1...20).contains(command.maxTurns), (1...300_000).contains(command.timeoutMs),
              command.fixtures.count <= 40 else {
            reply.failure("Invalid eval bounds")
            return
        }
        guard case .found(let session?) = resolveSession(chatManager, command.sessionId),
              let snapshot = session.agentSnapshot, snapshot.messages.isEmpty, !session.isBusy else {
            reply.failure("Evals require an idle, empty chat as the prompt and tool template")
            return
        }
        guard let client = ProviderRegistry.shared.client(id: command.clientId),
              client.id != "mock", let model = client.models.first(where: { $0.id == command.modelId }) else {
            reply.failure("Evals require a configured real provider and model")
            return
        }
        let schemas = snapshot.tools.map { ToolSchema(name: $0.name, description: $0.description, parameters: $0.parameters, strict: $0.strict) }
        guard command.fixtures.allSatisfy({ fixture in schemas.contains(where: { $0.name == fixture.tool }) }) else {
            reply.failure("Fixture refers to an unknown tool")
            return
        }
        let state = AgentEvalState(fixtures: command.fixtures, maxTurns: command.maxTurns)
        let tools = schemas.map { AgentEvalTool(schema: $0, state: state) }
        let agent = Agent(configuration: AgentConfiguration(
            client: client, model: model, systemPrompt: snapshot.systemPrompt,
            tools: tools, streamOptions: snapshot.streamOptions,
            shouldStopAfterTurn: { context in await state.endTurn(needsMore: !context.toolResults.isEmpty) }
        ))
        let started = Date()
        Log.agent.info("OxHostRPC.agents.evaluate client=\(client.id) model=\(model.id) prompts=\(command.prompts.count) fixtures=\(command.fixtures.count)")
        Task {
            let watchdog = Task {
                try await Task.sleep(for: .milliseconds(command.timeoutMs))
                await state.fail("Eval timed out")
                await agent.abort()
            }
            defer { watchdog.cancel() }
            for prompt in command.prompts {
                if await state.hasFailed { break }
                guard await state.canStart else { await state.fail("Eval reached its model-turn limit"); break }
                do {
                    let result = try await agent.run(AgentRunRequest(text: prompt))
                    switch result.outcome {
                    case .completed: break
                    case .aborted: await state.fail("Agent aborted")
                    case .failed(let message, _): await state.failExecution(message)
                    }
                } catch { await state.failExecution(error.localizedDescription) }
            }
            let result = await agent.snapshot()
            let errors = await state.finish()
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Log.agent.info("OxHostRPC.agents.evaluate complete ms=\(elapsed) messages=\(result.messages.count) errors=\(errors.count)")
            reply.success(EvaluateAgentResult(messages: result.messages, systemPrompt: snapshot.systemPrompt,
                                              tools: schemas.map { EvalToolSchema(name: $0.name, description: $0.description, parameters: $0.parameters) },
                                              temperature: snapshot.streamOptions.temperature, maxTokens: snapshot.streamOptions.maxTokens, totalMs: elapsed, errors: errors, executionError: await state.executionError))
        }
    }
}

nonisolated struct AgentEvalFixture: Decodable, Sendable {
    let tool: String
    let sourceIncludes: [String]
    let text: String
    let isError: Bool
    let terminate: Bool
}

private actor AgentEvalState {
    let fixtures: [AgentEvalFixture]
    let maxTurns: Int
    var index = 0
    var turns = 0
    var terminated = false
    var errors: [String] = []
    var executionError: String?
    var hasFailed: Bool { !errors.isEmpty }
    var canStart: Bool { turns < maxTurns }

    init(fixtures: [AgentEvalFixture], maxTurns: Int) {
        self.fixtures = fixtures
        self.maxTurns = maxTurns
    }

    func fail(_ message: String) { errors.append(message) }

    func failExecution(_ message: String) {
        executionError = message
        fail(message)
    }

    func execute(name: String, args: JSONValue) -> ToolResult {
        guard index < fixtures.count else {
            fail("Unexpected tool call: \(name)")
            return ToolResult(text: "Unexpected tool call", isError: true, terminate: true)
        }
        let fixture = fixtures[index]
        let source = args.objectValue?["source"]?.stringValue ?? ""
        guard fixture.tool == name, fixture.sourceIncludes.allSatisfy({ source.contains($0) }) else {
            fail("Tool call did not match fixture \(index + 1)")
            return ToolResult(text: "Tool call did not match fixture", isError: true, terminate: true)
        }
        index += 1
        terminated = fixture.terminate
        return ToolResult(text: fixture.text, isError: fixture.isError, terminate: fixture.terminate)
    }

    func endTurn(needsMore: Bool) -> Bool {
        turns += 1
        if turns >= maxTurns && needsMore && !terminated { fail("Eval reached its model-turn limit") }
        return hasFailed
    }

    func finish() -> [String] {
        if index != fixtures.count { fail("Unused tool fixtures: \(fixtures.count - index)") }
        return errors
    }
}

private nonisolated struct AgentEvalTool: AgentTool {
    let schema: ToolSchema
    let state: AgentEvalState
    var name: String { schema.name }
    var description: String { schema.description }
    var parameters: JSONValue { schema.parameters }
    var strict: Bool { schema.strict }

    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
        await state.execute(name: name, args: args)
    }
}
#endif
