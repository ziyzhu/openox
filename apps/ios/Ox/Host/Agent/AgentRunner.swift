import Foundation

nonisolated enum AgentRunner {
    typealias EventSink = @Sendable (AgentEvent) async -> Void

    static func run(newMessages: [Message], config: AgentRunConfig, emit: EventSink) async -> AgentRunResult {
        var snapshot = config.snapshot
        var messages = snapshot.context.messages
        var pendingMessages = newMessages
        var runMessages: [Message] = []
        var lastCompletedTurn: PrepareNextTurnContext?
        var lastTurnTokens = config.priorTurnTokens
        var errorMessage: String?
        var failureKind: LLMFailureKind?
        var overflowRecoveryAttempted = false
        var preparedMessages: [Message]?
        var preparedIncludesPendingMessages = false

        LogContext.latency?.mark(.agentStarted)
        await emit(.agentStart(turnID: config.turnID))
        let protocolDiagnostics = snapshot.client.protocolDiagnostics
        let wireProtocol = snapshot.client.wireProtocol(for: snapshot.model)?.rawValue ?? "synthetic"
        Log.agent.info("Agent.run start client=\(snapshot.client.id) model=\(snapshot.model.id) protocol=\(wireProtocol) prompt=\(systemPromptFingerprint(snapshot.context.systemPrompt)) cacheRoute=\(protocolDiagnostics.promptCacheRouting ?? "n/a") maxTokensField=\(protocolDiagnostics.maxTokensField ?? "n/a")")

        let preparedPreflightMessages = await transformed(
            messages: messages + newMessages,
            model: snapshot.model,
            using: config.transformContext
        )
        if !newMessages.isEmpty,
           modelInputCompatibilityError(messages: preparedPreflightMessages, model: snapshot.model) == nil {
            let preflight = await compactIfNeeded(
                messages: messages,
                lastTurnTokens: lastTurnTokens,
                snapshot: snapshot,
                config: config,
                reason: .prePrompt,
                compatibilityMessages: preparedPreflightMessages,
                emit: emit
            )
            messages = preflight.messages
            lastTurnTokens = preflight.lastTurnTokens
            snapshot = preflight.snapshot
            preparedMessages = preflight.preparedMessages
            preparedIncludesPendingMessages = preparedMessages != nil
            if preflight.cancelled {
                Log.agent.info("Agent.run terminating: pre-prompt compaction cancelled")
                let retainedMessages = retained(messages)
                LogContext.latency?.mark(.agentCompleted)
                await emit(.agentEnd(messages: retainedMessages))
                return AgentRunResult(messages: retainedMessages, errorMessage: nil, failureKind: nil, lastTurnTokens: lastTurnTokens)
            }
        } else if !newMessages.isEmpty {
            preparedMessages = preparedPreflightMessages
            preparedIncludesPendingMessages = true
            Log.agent.info("Agent.compact skipped reason=unsupported-new-input model=\(snapshot.model.id)")
        } else {
            preparedMessages = preparedPreflightMessages
        }

        var iter = 0
        loop: while true {
            iter += 1
            if let lastCompletedTurn {
                let preparation = await prepareNextTurn(
                    lastCompletedTurn,
                    lastTurnTokens: lastTurnTokens,
                    snapshot: snapshot,
                    config: config,
                    emit: emit
                )
                messages = preparation.messages
                lastTurnTokens = preparation.lastTurnTokens
                snapshot = preparation.snapshot
                preparedMessages = preparation.preparedMessages
                preparedIncludesPendingMessages = false
                if preparation.cancelled {
                    Log.agent.info("Agent.run terminating: next-turn preparation cancelled")
                    break loop
                }
                if pendingMessages.isEmpty {
                    pendingMessages = await config.getSteeringMessages()
                }
            }
            snapshot.context.messages = messages
            Log.agent.info("Agent.run iter=\(iter) msgs=\(messages.count) streaming…")
            LogContext.latency?.mark(.modelStarted)
            await emit(.turnStart(model: snapshot.model.id, turnID: config.turnID))

            if !pendingMessages.isEmpty {
                if !preparedIncludesPendingMessages {
                    preparedMessages = nil
                }
                for message in pendingMessages {
                    messages.append(message)
                    runMessages.append(message)
                    await emit(.messageStart(message))
                    await emit(.messageEnd(message))
                }
                pendingMessages = []
                snapshot.context.messages = messages
            }

            let modelMessages = if let preparedMessages {
                preparedMessages
            } else {
                await transformed(
                    messages: messages,
                    model: snapshot.model,
                    using: config.transformContext
                )
            }
            preparedMessages = nil
            preparedIncludesPendingMessages = false
            snapshot.context.messages = modelMessages
            let assistant = await streamAssistantTurn(snapshot: snapshot, emit: emit)
            LogContext.latency?.recordModelCompleted(assistant.usage)
            let assistantText = text(of: assistant.content)
            Log.agent.info("Agent.run iter=\(iter) turn done stopReason=\(assistant.stopReason) rawReason=\(LogPrivacy.text(assistant.rawStopReason ?? "none", limit: 128)) failureKind=\(assistant.failureKind?.rawValue ?? "none") responseId=\(LogPrivacy.text(assistant.responseID ?? "none", limit: 128)) blocks=\(assistant.content.count) tokens(in/out)=\(assistant.usage.input)/\(assistant.usage.output) textChars=\(assistantText.count) err=\(LogPrivacy.text(assistant.errorMessage ?? "nil", limit: 2_048))")
            messages.append(.assistant(assistant))
            runMessages.append(.assistant(assistant))
            if assistant.stopReason != .error, assistant.stopReason != .aborted {
                lastTurnTokens = assistant.usage.totalTokens > 0
                    ? assistant.usage.totalTokens
                    : assistant.usage.input + assistant.usage.output
            }
            let contextOverflow = isContextOverflow(assistant, contextWindow: snapshot.model.maxContext)

            if contextOverflow, assistant.stopReason != .stop {
                errorMessage = assistant.errorMessage
                failureKind = assistant.failureKind
                await emit(.turnEnd(message: assistant, toolResults: []))
                if !overflowRecoveryAttempted {
                    overflowRecoveryAttempted = true
                    messages.removeLast()
                    let recovery = await compactIfNeeded(
                        messages: messages,
                        lastTurnTokens: lastTurnTokens,
                        snapshot: snapshot,
                        config: config,
                        reason: .overflow,
                        force: true,
                        emit: emit
                    )
                    messages = recovery.messages
                    lastTurnTokens = recovery.lastTurnTokens
                    snapshot = recovery.snapshot
                    if !recovery.cancelled, recovery.compacted {
                        errorMessage = nil
                        failureKind = nil
                        Log.agent.info("Agent.run retrying once after context overflow")
                        continue loop
                    }
                } else {
                    Log.agent.warning("Agent.run context overflow recovery exhausted after one retry")
                    errorMessage = errorMessage
                        ?? "Context overflow recovery failed after one compact-and-retry attempt."
                }
                break loop
            }

            if assistant.stopReason == .error || assistant.stopReason == .aborted {
                errorMessage = assistant.errorMessage
                failureKind = assistant.failureKind
                await emit(.turnEnd(message: assistant, toolResults: []))
                break loop
            }
            overflowRecoveryAttempted = false

            let toolCalls = assistant.content.compactMap { block -> ToolCall? in
                if case .toolCall(let toolCall) = block { return toolCall }
                return nil
            }
            Log.agent.info("Agent.run iter=\(iter) toolCalls=\(toolCalls.count) [\(toolCalls.map(\.name).joined(separator: ","))]")

            let executedToolCalls = if assistant.stopReason == .length {
                await failTruncatedToolCalls(toolCalls, emit: emit)
            } else {
                await executeToolCalls(
                    toolCalls,
                    assistant: assistant,
                    messages: messages,
                    snapshot: snapshot,
                    config: config,
                    emit: emit
                )
            }
            let shouldTerminate = executedToolCalls.shouldTerminate
            let toolResults = executedToolCalls.results
            for result in toolResults {
                let message = Message.toolResult(result)
                messages.append(message)
                runMessages.append(message)
                await emit(.messageStart(message))
                await emit(.messageEnd(message))
            }
            await emit(.turnEnd(message: assistant, toolResults: toolResults))

            let completedTurn = PrepareNextTurnContext(
                message: assistant,
                toolResults: toolResults,
                context: AgentContext(
                    systemPrompt: snapshot.context.systemPrompt,
                    messages: messages,
                    tools: snapshot.context.tools
                ),
                newMessages: runMessages
            )
            lastCompletedTurn = completedTurn
            let shouldStopAfterTurn = await config.shouldStopAfterTurn?(completedTurn) == true

            if Task.isCancelled { Log.agent.info("Agent.run terminating: cancelled"); break loop }

            if shouldStopAfterTurn {
                Log.agent.info("Agent.run terminating: shouldStopAfterTurn")
                break loop
            }

            let steeringMessages = await config.getSteeringMessages()
            if toolCalls.isEmpty || shouldTerminate {
                if !steeringMessages.isEmpty {
                    pendingMessages = steeringMessages
                    continue loop
                }
                let followUpMessages = await config.getFollowUpMessages()
                if !followUpMessages.isEmpty {
                    pendingMessages = followUpMessages
                    continue loop
                }
                Log.agent.info(shouldTerminate ? "Agent.run terminating: tool requested terminate" : "Agent.run terminating: no tool calls")
                break loop
            }

            if await config.shouldPause() {
                Log.agent.info("Agent.run paused at iter=\(iter) msgs=\(messages.count)")
                await emit(.paused)
                await config.waitForResume()
                Log.agent.info("Agent.run resumed at iter=\(iter)")
                await emit(.resumed)
                if Task.isCancelled { Log.agent.info("Agent.run terminating after resume: cancelled"); break loop }
            }

            if !steeringMessages.isEmpty {
                pendingMessages = steeringMessages
            }
        }

        let retainedMessages = retained(messages)
        LogContext.latency?.mark(.agentCompleted)
        await emit(.agentEnd(messages: retainedMessages))
        return AgentRunResult(messages: retainedMessages, errorMessage: errorMessage, failureKind: failureKind, lastTurnTokens: lastTurnTokens)
    }

    private struct CompactionApplication: Sendable {
        var messages: [Message]
        var lastTurnTokens: Int
        var snapshot: AgentTurnSnapshot
        var cancelled: Bool
        var compacted: Bool
        var preparedMessages: [Message]?
    }

    private static func prepareNextTurn(
        _ turn: PrepareNextTurnContext,
        lastTurnTokens: Int,
        snapshot: AgentTurnSnapshot,
        config: AgentRunConfig,
        emit: EventSink
    ) async -> CompactionApplication {
        var refreshed = await config.refreshSnapshot(turn.context.messages) ?? snapshot
        refreshed.context.messages = turn.context.messages
        return await compactIfNeeded(
            messages: turn.context.messages,
            lastTurnTokens: lastTurnTokens,
            snapshot: refreshed,
            config: config,
            reason: .continuation,
            emit: emit
        )
    }

    private static func compactIfNeeded(
        messages: [Message],
        lastTurnTokens: Int,
        snapshot: AgentTurnSnapshot,
        config: AgentRunConfig,
        reason: AgentCompactionReason,
        force: Bool = false,
        compatibilityMessages: [Message]? = nil,
        emit: EventSink
    ) async -> CompactionApplication {
        let preparedMessages = if let compatibilityMessages {
            compatibilityMessages
        } else {
            await transformed(
                messages: messages,
                model: snapshot.model,
                using: config.transformContext
            )
        }
        if modelInputCompatibilityError(messages: preparedMessages, model: snapshot.model) != nil {
            Log.agent.info("Agent.compact skipped reason=unsupported-input model=\(snapshot.model.id)")
            return CompactionApplication(
                messages: messages,
                lastTurnTokens: lastTurnTokens,
                snapshot: snapshot,
                cancelled: false,
                compacted: false,
                preparedMessages: preparedMessages
            )
        }
        let outcome = await AgentCompactor.compact(
            messages: messages,
            lastTurnTokens: lastTurnTokens,
            threshold: snapshot.compactionThreshold,
            client: snapshot.client,
            model: snapshot.model,
            options: snapshot.streamOptions,
            reason: reason,
            force: force,
            transformContext: config.transformContext,
            systemPrompt: snapshot.context.systemPrompt,
            tools: snapshot.context.tools
        )
        guard case .compacted(let compaction) = outcome else {
            let cancelled: Bool
            switch outcome {
            case .cancelled:
                cancelled = true
            default:
                cancelled = false
            }
            return CompactionApplication(
                messages: messages,
                lastTurnTokens: lastTurnTokens,
                snapshot: snapshot,
                cancelled: cancelled,
                compacted: false,
                preparedMessages: preparedMessages
            )
        }
        var refreshed = await config.refreshSnapshot(compaction.messages) ?? snapshot
        refreshed.context.messages = compaction.messages
        await emit(.compacted(
            beforeMessages: compaction.beforeMessages,
            afterMessages: compaction.messages.count,
            summaryChars: compaction.summaryChars,
            tokensBefore: compaction.tokensBefore
        ))
        return CompactionApplication(
            messages: compaction.messages,
            lastTurnTokens: 0,
            snapshot: refreshed,
            cancelled: false,
            compacted: true,
            preparedMessages: nil
        )
    }

    private static func retained(_ messages: [Message]) -> [Message] {
        messages.map { message -> Message in
            guard case .toolResult(var result) = message else { return message }
            result.transientAttachments = []
            return .toolResult(result)
        }
    }

    private static func transformed(
        messages: [Message],
        model: ProviderModel,
        using hook: TransformContextHook?
    ) async -> [Message] {
        await hook?(TransformContextRequest(messages: messages, model: model)) ?? messages
    }

    private struct ExecutedToolCalls: Sendable {
        var results: [ToolResultMessage]
        var shouldTerminate: Bool
    }

    private static func failTruncatedToolCalls(_ toolCalls: [ToolCall], emit: EventSink) async -> ExecutedToolCalls {
        var results: [ToolResultMessage] = []
        for toolCall in toolCalls {
            let text = "Tool call \"\(toolCall.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
            let result = ToolResultMessage(
                toolCallId: toolCall.id,
                providerCallID: toolCall.providerCallID,
                toolName: toolCall.name,
                content: ToolResult(text: text).content,
                isError: true
            )
            Log.agent.warning("Agent.run skipped truncated tool=\(toolCall.name) id=\(toolCall.id)")
            await emit(.toolExecutionStart(toolCall: toolCall))
            await emit(.toolExecutionEnd(toolCall: toolCall, result: result))
            results.append(result)
        }
        return ExecutedToolCalls(results: results, shouldTerminate: false)
    }

    private static func executeToolCalls(
        _ toolCalls: [ToolCall],
        assistant: AssistantMessage,
        messages: [Message],
        snapshot: AgentTurnSnapshot,
        config: AgentRunConfig,
        emit: EventSink
    ) async -> ExecutedToolCalls {
        let toolContext = AgentContext(systemPrompt: snapshot.context.systemPrompt, messages: messages, tools: snapshot.context.tools)
        let promptFingerprint = systemPromptFingerprint(snapshot.context.systemPrompt)
        let hasSequentialTool = toolCalls.contains { toolCall in
            snapshot.context.tools.first(where: { $0.name == toolCall.name })?.executionMode == .sequential
        }
        if config.toolExecutionMode == .parallel, !hasSequentialTool {
            for toolCall in toolCalls {
                Log.agent.debug("Agent.run executing tool=\(toolCall.name) id=\(toolCall.id)\n\(formatArgs(toolCall.arguments))")
                LogContext.latency?.mark(.toolStarted)
                await emit(.toolExecutionStart(toolCall: toolCall))
            }
            var entries: [(Int, ToolCall, ToolResultMessage, Bool)] = []
            await withTaskGroup(of: (Int, ToolCall, ToolResultMessage, Bool).self) { group in
                for (index, toolCall) in toolCalls.enumerated() {
                    group.addTask {
                        let (result, terminate) = await AgentToolExecutor.execute(
                            toolCall,
                            assistantMessage: assistant,
                            context: toolContext,
                            beforeToolCall: config.beforeToolCall,
                            afterToolCall: config.afterToolCall
                        )
                        LogContext.latency?.mark(.toolCompleted)
                        return (index, toolCall, result, terminate)
                    }
                }
                for await entry in group { entries.append(entry) }
            }
            entries.sort { $0.0 < $1.0 }
            for (_, toolCall, result, terminate) in entries {
                await emit(.toolExecutionEnd(toolCall: toolCall, result: result))
                logToolResult(
                    toolCall: toolCall,
                    result: result,
                    terminate: terminate,
                    promptFingerprint: promptFingerprint
                )
            }
            return ExecutedToolCalls(
                results: entries.map(\.2),
                shouldTerminate: !entries.isEmpty && entries.allSatisfy(\.3)
            )
        }

        var results: [ToolResultMessage] = []
        var terminates: [Bool] = []
        for toolCall in toolCalls {
            if Task.isCancelled {
                Log.agent.info("Agent.run stopped before sibling tool=\(toolCall.name) id=\(toolCall.id): cancelled")
                break
            }
            Log.agent.debug("Agent.run executing tool=\(toolCall.name) id=\(toolCall.id)\n\(formatArgs(toolCall.arguments))")
            LogContext.latency?.mark(.toolStarted)
            await emit(.toolExecutionStart(toolCall: toolCall))
            let (result, terminate) = await AgentToolExecutor.execute(
                toolCall,
                assistantMessage: assistant,
                context: toolContext,
                beforeToolCall: config.beforeToolCall,
                afterToolCall: config.afterToolCall
            )
            LogContext.latency?.mark(.toolCompleted)
            await emit(.toolExecutionEnd(toolCall: toolCall, result: result))
            logToolResult(
                toolCall: toolCall,
                result: result,
                terminate: terminate,
                promptFingerprint: promptFingerprint
            )
            results.append(result)
            terminates.append(terminate)
        }
        return ExecutedToolCalls(
            results: results,
            shouldTerminate: !terminates.isEmpty && terminates.allSatisfy { $0 }
        )
    }

    private static func logToolResult(
        toolCall: ToolCall,
        result: ToolResultMessage,
        terminate: Bool,
        promptFingerprint: String
    ) {
        let resultText = text(of: result.content)
        if result.isError {
            let summary = resultText.isEmpty ? "<no text>" : LogPrivacy.text(resultText)
            Log.agent.warning("Agent.run tool=\(toolCall.name) id=\(toolCall.id) done isError=true terminate=\(terminate) prompt=\(promptFingerprint) result=\(summary)")
            return
        }
        Log.agent.info("Agent.run tool=\(toolCall.name) id=\(toolCall.id) done isError=\(result.isError) terminate=\(terminate) resultChars=\(resultText.count)")
    }

    private static func streamAssistantTurn(snapshot: AgentTurnSnapshot, emit: EventSink) async -> AssistantMessage {
        let promptFingerprint = systemPromptFingerprint(snapshot.context.systemPrompt)
        if let error = modelInputCompatibilityError(messages: snapshot.context.messages, model: snapshot.model) {
            var message = AssistantMessage(model: snapshot.model.id)
            message.stopReason = .error
            message.errorMessage = error.message
            message.failureKind = .unsupportedInput
            Log.agent.error("Agent.streamAssistantTurn rejected unsupported input model=\(snapshot.model.id) required=[\(requiredInputModalities(in: snapshot.context.messages).map(\.rawValue).sorted().joined(separator: ","))]")
            await emit(.messageStart(.assistant(message)))
            await emit(.messageEnd(.assistant(message)))
            return message
        }
        let stream = snapshot.client.stream(
            model: snapshot.model,
            systemPrompt: snapshot.context.systemPrompt.isEmpty ? nil : snapshot.context.systemPrompt,
            messages: snapshot.context.messages,
            tools: snapshot.context.tools,
            options: snapshot.streamOptions
        )

        var current = AssistantMessage(model: snapshot.model.id)
        var receivedToken = false
        var receivedThinking = false
        var receivedText = false

        do {
            for try await event in stream {
                if Task.isCancelled {
                    var message = current
                    message.stopReason = .aborted
                    message.errorMessage = "aborted"
                    await emit(.messageEnd(.assistant(message)))
                    return message
                }
                switch event {
                case .start(let partial):
                    current = partial
                    await emit(.messageStart(.assistant(partial)))
                case .thinkingEnd(let index, let partial):
                    current = partial
                    await emit(.messageUpdate(partial, event: event))
                    if index < partial.content.count, case .thinking(let content) = partial.content[index], !content.thinking.isEmpty {
                        await emit(.reasoning(content.thinking))
                    }
                case .textDelta(_, _, let partial):
                    if !receivedToken {
                        receivedToken = true
                        LogContext.latency?.mark(.firstToken)
                    }
                    if !receivedText {
                        receivedText = true
                        LogContext.latency?.mark(.firstTextReceived)
                    }
                    current = partial
                    await emit(.messageUpdate(partial, event: event))
                case .thinkingDelta(_, _, let partial),
                     .toolCallDelta(_, let partial):
                    if !receivedToken {
                        receivedToken = true
                        LogContext.latency?.mark(.firstToken)
                    }
                    if case .thinkingDelta = event, !receivedThinking {
                        receivedThinking = true
                        LogContext.latency?.mark(.firstThinkingReceived)
                    }
                    current = partial
                    await emit(.messageUpdate(partial, event: event))
                case .textEnd(_, let partial),
                     .toolCallEnd(_, _, let partial):
                    current = partial
                    await emit(.messageUpdate(partial, event: event))
                case .done(let reason, let message):
                    if reason == .pending {
                        var failed = message
                        failed.stopReason = .error
                        failed.errorMessage = "stream emitted a terminal event without a provider stop reason"
                        failed.failureKind = .provider
                        Log.agent.error("Agent.streamAssistantTurn invalid pending terminal prompt=\(promptFingerprint)")
                        await emit(.messageEnd(.assistant(failed)))
                        return failed
                    }
                    Log.agent.info("Agent.streamAssistantTurn done reason=\(reason)")
                    await emit(.messageEnd(.assistant(message)))
                    return message
                case .failed(let reason, let message):
                    Log.agent.error("Agent.streamAssistantTurn failed reason=\(reason) failureKind=\(message.failureKind?.rawValue ?? "none") prompt=\(promptFingerprint) err=\(LogPrivacy.text(message.errorMessage ?? "nil", limit: 2_048))")
                    await emit(.messageEnd(.assistant(message)))
                    return message
                }
            }
        } catch {
            Log.agent.error("Agent.streamAssistantTurn threw prompt=\(promptFingerprint): \(LogPrivacy.text(error.localizedDescription, limit: 2_048)) cancelled=\(Task.isCancelled)")
            var message = current
            message.stopReason = Task.isCancelled ? .aborted : .error
            message.errorMessage = error.localizedDescription
            if !Task.isCancelled { message.failureKind = llmFailureKind(error: error) }
            await emit(.messageEnd(.assistant(message)))
            return message
        }

        var message = current
        if Task.isCancelled {
            message.stopReason = .aborted
            message.errorMessage = "aborted"
            Log.agent.info("Agent.streamAssistantTurn aborted blocks=\(message.content.count)")
        } else {
            message.stopReason = .error
            message.errorMessage = "stream ended without a terminal event"
            message.failureKind = .provider
            Log.agent.error("Agent.streamAssistantTurn ended without .done/.failed prompt=\(promptFingerprint) blocks=\(message.content.count)")
        }
        await emit(.messageEnd(.assistant(message)))
        return message
    }

    private static func text(of blocks: [ContentBlock]) -> String {
        blocks.compactMap { if case .text(let text) = $0 { return text.text }; return nil }
            .joined(separator: "\n")
    }

    private static func formatArgs(_ args: JSONValue) -> String {
        guard case .object(let object) = args, !object.isEmpty else { return prettyJSON(args) }
        return object.keys.sorted().map { key in
            let value = object[key]!
            if case .string(let string) = value, string.contains("\n") || string.count > 80 {
                let indented = string.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "  \($0)" }.joined(separator: "\n")
                return "\(key):\n\(indented)"
            }
            return "\(key): \(prettyJSON(value))"
        }.joined(separator: "\n")
    }

    private static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "<unencodable>"
        }
        return string
    }
}
