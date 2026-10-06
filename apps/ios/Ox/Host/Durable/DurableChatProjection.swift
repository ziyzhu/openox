import Foundation

nonisolated enum DurableChatProjection {
    private struct Decoration {
        let assistant: AssistantMessage
        let steps: [Step]
    }

    static func turns(from entries: [JSONValue], scope: ProfileScope) throws -> [Turn] {
        let annotations = annotations(from: entries, scope: scope)
        let decorations = annotations.flatMap { turn -> [Decoration] in
            guard case .agent(let agent, let id) = turn else { return [] }
            return agent.generations.compactMap { generation in
                let steps = agent.steps.filter { $0.generation == generation.id }
                let projection = AgentTurn(at: generation.at, generations: [generation], steps: steps, outcome: agent.outcome)
                guard let message = ChatProjection.wire([.agent(projection, id: id)]).first,
                      case .assistant(let assistant) = message else { return nil }
                return Decoration(assistant: assistant, steps: steps)
            }
        }
        var builder = Builder(annotations: annotations, decorations: decorations)
        var seen = Set<Int>()
        for entry in entries {
            guard let fields = entry.objectValue else { throw RuntimeError.bridge("Invalid Pi presentation entry") }
            let kind = fields["kind"]?.stringValue ?? ""
            guard kind != "pi.reset", kind != "pi.compaction" else { continue }
            let models = fields["model"]?.arrayValue ?? []
            guard !models.isEmpty else { continue }
            guard let id = fields["id"]?.intValue, seen.insert(id).inserted else {
                throw RuntimeError.bridge("Pi presentation entry identity is missing or duplicated")
            }
            let namespace = "pi:\(scope.profileID?.uuidString ?? "scope"):\(fields["conversationId"]?.intValue ?? 0):\(id)"
            let data = fields["data"]?.objectValue
            let turnID = data?["turn"]?.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map { TurnID($0) }
            for (index, value) in models.enumerated() where value.objectValue?["role"]?.stringValue != "system" {
                let message = try DurableMessageCodec.decode(value, scope: scope, includeTransientReferences: false)
                try builder.append(message, namespace: "\(namespace):\(index)", turnID: turnID)
            }
        }
        builder.finishAgent()
        return builder.turns
    }

    private static func annotations(from entries: [JSONValue], scope: ProfileScope) -> [Turn] {
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        var order: [TurnID] = []
        var latest: [TurnID: Turn] = [:]
        for entry in entries {
            guard let fields = entry.objectValue,
                  ["ox.native.turn", "ox.native.presentation"].contains(fields["kind"]?.stringValue ?? ""),
                  let value = fields["data"]?.objectValue?["turn"] else { continue }
            do {
                let turn = try decoder.decode(Turn.self, from: Data(value.jsonString().utf8))
                order.removeAll { $0 == turn.id }
                order.append(turn.id)
                latest[turn.id] = turn
            } catch {
                Log.session.warning("PiDurable presentation annotation ignored entry=\(fields["id"]?.intValue ?? -1) error=\(error.localizedDescription)")
            }
        }
        return order.compactMap { latest[$0] }
    }

    private struct Builder {
        let annotations: [Turn]
        let decorations: [Decoration]
        var turns: [Turn] = []
        var agent: AgentTurn?
        var agentID: TurnID?
        var toolDecorations: [StepID: [Step]] = [:]

        mutating func append(_ message: Message, namespace: String, turnID: TurnID?) throws {
            switch message {
            case .user(let user):
                finishAgent()
                let intent = user.content.concatenatedText
                let attachments = user.content.compactMap { block -> Artifact? in
                    if case .attachment(let artifact) = block { return artifact }
                    return nil
                }
                let rich = annotations.compactMap { turn -> (UserTurn, TurnID)? in
                    guard case .user(let candidate, let id) = turn,
                          turnID == nil || turnID == id,
                          candidate.intent == intent,
                          candidate.attachments.map(\.fileName) == attachments.map(\.fileName) else { return nil }
                    return (candidate, id)
                }
                let exact = rich.filter { abs($0.0.at.timeIntervalSince(user.timestamp)) < 0.001 }
                let matched = exact.last ?? (rich.count == 1 ? rich.first : nil)
                let skill = matched?.0.skillInvocation.flatMap { $0.expandedIntent == intent ? $0 : nil }
                let id = turnID ?? TurnID(StableID.uuid(namespace + ":user"))
                turns.append(.user(UserTurn(intent: intent, attachments: attachments, at: user.timestamp,
                                            submissionID: matched?.0.submissionID, skillInvocation: skill), id: id))
            case .assistant(let assistant):
                appendAssistant(assistant, namespace: namespace, turnID: turnID)
            case .toolResult(let result):
                try appendResult(result)
            }
        }

        mutating func appendAssistant(_ assistant: AssistantMessage, namespace: String, turnID: TurnID?) {
            let candidates = decorations.filter { decoration in
                guard decoration.assistant.model == assistant.model,
                      abs(decoration.assistant.timestamp.timeIntervalSince(assistant.timestamp)) < 0.001 else { return false }
                let calls = assistant.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let call) = block { return call }
                    return nil
                }
                let richCalls = decoration.assistant.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let call) = block { return call }
                    return nil
                }
                return calls.isEmpty ? decoration.assistant.content == assistant.content : calls == richCalls
            }
            let rich = candidates.last
            if agent == nil {
                agent = AgentTurn(at: assistant.timestamp, generations: [], steps: [], outcome: .running)
                agentID = turnID ?? TurnID(StableID.uuid(namespace + ":agent"))
            }
            let generationID = AgentGenerationID(StableID.uuid(namespace + ":generation"))
            agent?.generations.append(ModelGeneration(id: generationID, at: assistant.timestamp, model: assistant.model,
                                                     outcome: DurableChatProjection.outcome(for: assistant), assistantMessage: assistant))
            for (index, block) in assistant.content.enumerated() {
                let stepID = StepID(StableID.uuid(namespace + ":block:\(index)"))
                switch block {
                case .text(let text):
                    agent?.steps.append(Step(id: stepID, generation: generationID, kind: .text(text.text)))
                case .thinking(let thinking):
                    agent?.steps.append(Step(id: stepID, generation: generationID, kind: .reasoning(thinking.thinking)))
                case .toolCall(let call):
                    let matching = candidates.flatMap(\.steps).filter { step in
                        if let recorded = step.toolCall { return recorded == call }
                        if let result = step.toolResult { return result.toolCallId == call.id && result.toolName == call.name }
                        if step.id.rawValue.uuidString == call.id { return true }
                        guard case .execute(let execution) = step.kind else { return false }
                        return call.arguments.objectValue?["source"]?.stringValue == execution.source
                    }
                    toolDecorations[stepID] = matching
                    let kind = DurableChatProjection.action(for: call, decoration: matching.last, id: stepID)
                    agent?.steps.append(Step(id: stepID, generation: generationID, kind: kind, toolCall: call))
                case .attachment(let artifact):
                    agent?.steps.append(Step(id: stepID, generation: generationID,
                                            kind: .execute(Execution(source: "", effects: [.artifact(artifact)], outcome: .succeeded(output: "")))))
                }
            }
            for step in rich?.steps ?? [] where step.toolCall == nil && step.toolResult == nil {
                let kind: Step.Kind
                switch step.kind {
                case .confirm(let prompt): kind = .confirm(DurableChatProjection.sealed(prompt))
                case .choice(let prompt): kind = .choice(DurableChatProjection.sealed(prompt))
                case .contextCompaction(let value): kind = .contextCompaction(value)
                default: continue
                }
                agent?.steps.append(Step(id: StepID(StableID.uuid(namespace + ":decoration:\(step.id.rawValue.uuidString)")),
                                        generation: generationID, kind: kind))
            }
        }

        mutating func appendResult(_ result: ToolResultMessage) throws {
            guard var current = agent, let index = current.steps.lastIndex(where: {
                $0.toolCall?.id == result.toolCallId && $0.toolResult == nil
            }) else { throw RuntimeError.bridge("Pi tool result has no matching canonical call") }
            guard let call = current.steps[index].toolCall, call.name == result.toolName else {
                throw RuntimeError.bridge("Pi tool result does not match its canonical capability")
            }
            let matching = toolDecorations.removeValue(forKey: current.steps[index].id) ?? []
            let decoration = matching.last { step in
                guard let recorded = step.toolResult else { return false }
                return recorded.toolCallId == result.toolCallId && recorded.toolName == result.toolName &&
                    recorded.isError == result.isError && recorded.content == result.content
            } ?? matching.last { $0.toolResult == nil }
            current.steps[index].kind = DurableChatProjection.action(for: call, decoration: decoration, id: current.steps[index].id)
            current.steps[index].toolResult = result
            switch current.steps[index].kind {
            case .execute(var execution):
                execution.outcome = result.isError ? .failed(output: result.content.concatenatedText) : .succeeded(output: result.content.concatenatedText)
                for effectIndex in execution.effects.indices {
                    guard case .invocation(var invocation) = execution.effects[effectIndex],
                          invocation.id == StableID.uuid(DurableChatProjection.invocationNamespace(for: current.steps[index])) else { continue }
                    invocation.outcome = result.isError ? .failed(result.content.concatenatedText) : .succeeded(result.diagnostics?.structuredContent)
                    execution.effects[effectIndex] = .invocation(invocation)
                }
                for block in result.content {
                    guard case .attachment(let artifact) = block,
                          !execution.effects.contains(.artifact(artifact)) else { continue }
                    execution.effects.append(.artifact(artifact))
                }
                for activated in result.activatedSkills {
                    guard !execution.effects.contains(where: {
                        if case .skill(let skill) = $0 { return skill.name == activated.name }
                        return false
                    }) else { continue }
                    execution.effects.append(.skill(Skill(name: activated.name, description: "", instructions: activated.content)))
                }
                current.steps[index].kind = .execute(execution)
            case .confirm(var prompt):
                prompt.outcome = DurableChatProjection.promptOutcome(for: result, decoration: prompt)
                current.steps[index].kind = .confirm(prompt)
            case .choice(var prompt):
                prompt.outcome = DurableChatProjection.promptOutcome(for: result, decoration: prompt)
                current.steps[index].kind = .choice(prompt)
            case .reasoning, .text, .contextCompaction, .wire:
                break
            }
            agent = current
        }

        mutating func finishAgent() {
            guard var current = agent, let id = agentID else { return }
            for index in current.generations.indices {
                let generation = current.generations[index]
                if current.steps.contains(where: { $0.generation == generation.id && $0.toolCall != nil && $0.toolResult == nil }) {
                    current.generations[index].outcome = .cancelled(at: generation.at)
                }
            }
            if let last = current.generations.last {
                current.outcome = last.assistantMessage?.stopReason == .toolUse ? .cancelled(at: last.at) : last.outcome
            } else { current.outcome = .cancelled(at: current.at) }
            turns.append(.agent(current, id: id))
            agent = nil
            agentID = nil
            toolDecorations.removeAll()
        }
    }

    private static func action(for call: ToolCall, decoration: Step?, id: StepID) -> Step.Kind {
        switch decoration?.kind {
        case .confirm(let prompt): return .confirm(sealed(prompt))
        case .choice(let prompt): return .choice(sealed(prompt))
        case .execute(let execution):
            return .execute(Execution(source: call.arguments.objectValue?["source"]?.stringValue ?? "",
                                      effects: sealed(execution.effects), outcome: .failed(output: "Interrupted")))
        default:
            let invocation = Invocation(id: StableID.uuid("pi:invocation:\(id.rawValue.uuidString)"), name: call.name,
                                        purpose: call.arguments.objectValue?["purpose"]?.stringValue ?? call.name,
                                        args: call.arguments, outcome: .failed("Interrupted"))
            return .execute(Execution(source: call.arguments.objectValue?["source"]?.stringValue ?? "",
                                      effects: [.invocation(invocation)], outcome: .failed(output: "Interrupted")))
        }
    }

    private static func outcome(for assistant: AssistantMessage) -> TurnOutcome {
        if let error = assistant.errorMessage {
            return error == "aborted" ? .cancelled(at: assistant.timestamp) : .failed(at: assistant.timestamp, message: error)
        }
        return switch assistant.stopReason {
        case .stop, .toolUse: .completed(at: assistant.timestamp)
        case .pending, .aborted: .cancelled(at: assistant.timestamp)
        case .error: .failed(at: assistant.timestamp, message: assistant.errorMessage ?? "Model generation failed")
        case .length: .failed(at: assistant.timestamp, message: assistant.errorMessage ?? "Model output token limit reached")
        }
    }

    private static func promptOutcome(for result: ToolResultMessage, decoration: AgentPrompt) -> PromptOutcome {
        let answer = result.content.concatenatedText
        let resolution = decoration.answer == answer ? decoration.resolution : nil
        return result.isError ? .cancelled(answer: answer, resolution: resolution) : .answered(answer: answer, resolution: resolution)
    }

    private static func sealed(_ prompt: AgentPrompt) -> AgentPrompt {
        var value = prompt
        if value.outcome == .pending { value.outcome = .cancelled(answer: "Interrupted", resolution: "Stopped") }
        return value
    }

    private static func sealed(_ effects: [ExecutionEffect]) -> [ExecutionEffect] {
        effects.map { effect in
            guard case .invocation(var invocation) = effect, invocation.outcome == .running else { return effect }
            invocation.outcome = .failed("Interrupted")
            return .invocation(invocation)
        }
    }

    private static func invocationNamespace(for step: Step) -> String {
        "pi:invocation:\(step.id.rawValue.uuidString)"
    }
}
