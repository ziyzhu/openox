#if targetEnvironment(simulator)
import Foundation

@MainActor
enum AgentRuntimeChecks {
    private enum Failure: Error {
        case assertion(String)
    }

    static func failures() async -> [String] {
        do {
            try await checkToolLoopAndSettlement()
            try await checkGenerationConfiguration()
            try await checkBusyAndCancellation()
            try await checkPausedCancellation()
            try await checkFailureAndContinuation()
            return []
        } catch Failure.assertion(let message) {
            return [message]
        } catch {
            return ["Agent runtime check failed: \(error.localizedDescription)"]
        }
    }

    private static func checkGenerationConfiguration() async throws {
        let calls = Calls()
        let client = client(Scenario(name: "runtime-model-switch") { context in
            context.turn == 0
                ? [.tool(name: "first", args: .object([:]))]
                : [.say(context.systemPrompt), .stop(.stop)]
        })
        let tools = [CheckTool(name: "first", calls: calls)]
        let agent = Agent(configuration: AgentConfiguration(client: client, model: client.models[0]))
        let next = AgentConfiguration(client: client, model: client.models[1], systemPrompt: "New configuration", tools: tools)
        await agent.configure(AgentConfiguration(
            client: client,
            model: client.models[0],
            systemPrompt: "Initial configuration",
            tools: tools,
            afterToolCall: { _ in
                await agent.configure(next)
                return nil
            }
        ))
        let result = try await agent.run(AgentRunRequest(text: "Switch"))
        let models = result.messages.compactMap { message -> String? in
            if case .assistant(let assistant) = message { assistant.model } else { nil }
        }
        try require(result.outcome == .completed && models == [client.models[0].id, client.models[1].id], "Live model changes must apply at the next generation boundary")
        let snapshot = await agent.snapshot()
        try require(snapshot.systemPrompt == next.systemPrompt, "Generation refresh must install the new configuration")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }

    private static func client(_ scenario: Scenario) -> MockLLMClient {
        var clock = MockLLMClient.Clock()
        clock.firstToken = .zero
        clock.betweenDeltas = .zero
        clock.beforeToolCall = .zero
        clock.beforeDone = .zero
        return MockLLMClient(scenarios: [:], fallback: scenario, clock: clock)
    }

    private static func checkToolLoopAndSettlement() async throws {
        let calls = Calls()
        let client = client(Scenario(name: "runtime-tool-loop") { context in
            context.turn == 0
                ? [.tool(name: "first", args: .object([:])), .tool(name: "second", args: .object([:]))]
                : [.say("Finished"), .stop(.stop)]
        })
        let agent = Agent(configuration: AgentConfiguration(
            client: client,
            model: client.models[0],
            systemPrompt: "Runtime check",
            tools: [CheckTool(name: "first", calls: calls), CheckTool(name: "second", calls: calls)],
            streamOptions: StreamOptions(sessionID: "runtime-check")
        ))
        let events = agent.events
        let observed = Task {
            var starts = 0
            var finishes = 0
            var generations = 0
            var completedGenerations = 0
            for await event in events {
                switch event {
                case .runStarted: starts += 1
                case .generationStarted: generations += 1
                case .generationFinished: completedGenerations += 1
                case .runFinished(let result):
                    finishes += 1
                    await agent.waitForIdle()
                    let snapshot = await agent.snapshot()
                    try require(snapshot.runState == .idle, "runFinished must expose idle runtime state")
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    try require(try encoder.encode(snapshot.messages) == encoder.encode(result.messages), "runFinished must expose installed final context")
                    try require(starts == 1 && finishes == 1, "A run must have exactly one start and finish")
                    try require(generations == 2 && completedGenerations == 2, "Tool loops must retain separate generation boundaries")
                    return result
                default: break
                }
            }
            throw Failure.assertion("Runtime events ended before runFinished")
        }
        let result = try await agent.run(AgentRunRequest(text: "Check tools", turnID: UUID()))
        let delivered = try await observed.value
        try require(result.outcome == .completed && delivered.outcome == result.outcome, "Successful runs must return their terminal result")
        try require(result.messages.count == 5, "Run results must contain the final retained model context")
        try require(await calls.names == ["first", "second"], "Ox tools must still default to sequential source order")
        let snapshot = await agent.snapshot()
        try require(snapshot.systemPrompt == "Runtime check" && snapshot.streamOptions.sessionID == "runtime-check", "Configuration must retain prompt and provider cache identity")
    }

    private static func checkBusyAndCancellation() async throws {
        let blocked = AsyncStream.makeStream(of: Void.self)
        let entered = AsyncStream.makeStream(of: Void.self)
        let client = client(Scenario(name: "runtime-cancel", steps: [.say("Finished"), .stop(.stop)]))
        let agent = Agent(configuration: AgentConfiguration(
            client: client,
            model: client.models[0],
            transformContext: { request in
                entered.continuation.yield(())
                for await _ in blocked.stream { break }
                return request.messages
            }
        ))
        let pending = Task { try await agent.run(AgentRunRequest(text: "First")) }
        defer {
            pending.cancel()
            blocked.continuation.finish()
            entered.continuation.finish()
        }
        var started = entered.stream.makeAsyncIterator()
        _ = await started.next()
        do {
            _ = try await agent.run(AgentRunRequest(text: "Must not be accepted"))
            throw Failure.assertion("Busy runs must be rejected explicitly")
        } catch AgentRunError.busy {}
        await agent.reset()
        let active = await agent.snapshot()
        try require(active.runState == .running, "Reset must not corrupt an active run")
        pending.cancel()
        let result = try await pending.value
        try require(result.outcome == .aborted && result.errorMessage == "aborted", "Caller cancellation must abort the accepted run")
        let idle = await agent.snapshot()
        try require(idle.runState == .idle && idle.pendingToolCalls.isEmpty, "Cancelled runs must settle to idle")
        try require(!result.messages.contains { message in
            if case .user(let user) = message { return user.content.contains(.text(TextContent("Must not be accepted"))) }
            return false
        }, "Rejected submissions must not enter model context")
        await agent.configure(AgentConfiguration(client: client, model: client.models[0]))
        let next = try await agent.run(AgentRunRequest(text: "Next"))
        try require(next.outcome == .completed, "A cancelled run must not prevent the next run")
    }

    private static func checkPausedCancellation() async throws {
        let calls = Calls()
        let ready = AsyncStream.makeStream(of: Void.self)
        let client = client(Scenario(name: "runtime-paused-cancel") { context in
            context.turn == 0
                ? [.tool(name: "first", args: .object([:]))]
                : [.say("Must not continue"), .stop(.stop)]
        })
        let agent = Agent(configuration: AgentConfiguration(
            client: client,
            model: client.models[0],
            tools: [CheckTool(name: "first", calls: calls)],
            transformContext: { request in
                for await _ in ready.stream {}
                return request.messages
            }
        ))
        let events = agent.events
        let observed = Task {
            for await event in events {
                if case .runStarted = event {
                    await agent.pause()
                    ready.continuation.finish()
                }
                if case .paused = event { return }
            }
            throw Failure.assertion("Pause must be observed at a safe generation boundary")
        }
        let pending = Task { try await agent.run(AgentRunRequest(text: "Pause")) }
        defer { pending.cancel() }
        try await observed.value
        pending.cancel()
        let result = try await pending.value
        try require(result.outcome == .aborted, "Cancelling a paused run must release its suspension")
        try require(await calls.names == ["first"], "Pause and cancellation must preserve completed tool effects")
    }

    private static func checkFailureAndContinuation() async throws {
        let client = client(Scenario(name: "runtime-failure", steps: [.fail(message: "Provider unavailable", reason: .error)]))
        let agent = Agent(configuration: AgentConfiguration(client: client, model: client.models[0]))
        do {
            _ = try await agent.continueFromContext()
            throw Failure.assertion("Empty continuation must be rejected explicitly")
        } catch AgentRunError.nothingToContinue {}
        let failed = try await agent.run(AgentRunRequest(text: "Failure"))
        try require(failed.outcome == .failed(message: "Provider unavailable", kind: .provider), "Provider failure must be represented by a typed terminal outcome")
        let snapshot = await agent.snapshot()
        try require(snapshot.errorMessage == failed.errorMessage && snapshot.failureKind == failed.failureKind, "Failure state and result must agree")
        let success = self.client(Scenario(name: "runtime-continue", steps: [.say("Continued"), .stop(.stop)]))
        await agent.configure(AgentConfiguration(client: success, model: success.models[0]))
        await agent.steer("Queued")
        let continued = try await agent.continueFromContext()
        try require(continued.outcome == .completed, "Continuation must process queued messages after an assistant")
    }

    private actor Calls {
        private(set) var names: [String] = []

        func record(_ name: String) {
            names.append(name)
        }
    }

    private struct CheckTool: AgentTool {
        let name: String
        let calls: Calls
        let description = "Record execution order"
        let parameters: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])

        func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult {
            await calls.record(name)
            return ToolResult(text: name)
        }
    }
}
#endif
