import CryptoKit
import Foundation

nonisolated enum ChatProjection {
    private enum EmbedKey: Hashable {
        case artifact(String)
        case skill(String)
    }

    static func render(_ turns: [Turn]) -> [Block] {
        makeBlocks(from: turns)
    }

    static func renderWithSource(
        _ turns: [Turn],
        turnOffset: Int = 0,
        ordinalOffset: Int = 0
    ) -> [(Block, Int)] {
        makeBlocksWithTurn(from: turns, turnOffset: turnOffset, ordinalOffset: ordinalOffset)
    }

    static func wire(_ turns: [Turn]) -> [Message] {
        makeWireMessages(from: turns)
    }

    nonisolated static func makeWireMessages(from turns: [Turn]) -> [Message] {
        var out: [Message] = []
        for turnValue in turns {
            switch turnValue {
            case let .user(turn, _):
                var content: [ContentBlock] = [.text(TextContent(turn.intent))]
                content += turn.attachments.map { .attachment($0) }
                out.append(.user(UserMessage(content: content, timestamp: turn.at)))
            case let .agent(turn, _):
                for generation in turn.generations {
                    var content: [ContentBlock] = []
                    var results: [Message] = []
                    for step in turn.steps where step.generation == generation.id {
                        switch step.kind {
                        case let .reasoning(text): content.append(.thinking(ThinkingContent(text)))
                        case let .text(text): content.append(.text(TextContent(text)))
                        case .execute:
                            let callId = step.toolCall?.id ?? step.toolResult?.toolCallId ?? step.id.rawValue.uuidString
                            let (derivedCall, result) = wireAction(step, callId: callId, at: generation.at)
                            content.append(.toolCall(step.toolCall ?? derivedCall))
                            results.append(.toolResult(step.toolResult ?? result))
                        case .confirm, .choice:
                            guard step.toolCall != nil || generation.assistantMessage == nil else { continue }
                            let callId = step.toolCall?.id ?? step.toolResult?.toolCallId ?? step.id.rawValue.uuidString
                            let (derivedCall, result) = wireAction(step, callId: callId, at: generation.at)
                            content.append(.toolCall(step.toolCall ?? derivedCall))
                            results.append(.toolResult(step.toolResult ?? result))
                        case .contextCompaction:
                            break
                        case .wire:
                            if let call = step.toolCall ?? derivedWireCall(step.toolResult) {
                                content.append(.toolCall(call))
                            }
                            if let result = step.toolResult { results.append(.toolResult(result)) }
                        }
                    }
                    var assistant = generation.assistantMessage ?? AssistantMessage(model: generation.model, content: content)
                    if generation.assistantMessage == nil {
                        assistant.stopReason = .stop
                        assistant.timestamp = generation.at
                        assistant.errorMessage = generation.outcome.error
                    } else {
                        let existingCallIDs = Set(assistant.content.compactMap { block -> String? in
                            if case .toolCall(let call) = block { return call.id }
                            return nil
                        })
                        let missingCalls = content.compactMap { block -> ContentBlock? in
                            guard case .toolCall(let call) = block, !existingCallIDs.contains(call.id) else { return nil }
                            return block
                        }
                        if !missingCalls.isEmpty {
                            assistant.content.append(contentsOf: missingCalls)
                            Log.session.warning("ChatProjection repaired generation=\(generation.id.rawValue) missingToolCalls=\(missingCalls.count)")
                        }
                    }
                    out.append(.assistant(assistant))
                    out.append(contentsOf: results)
                }
            }
        }
        return out
    }

    nonisolated private static func derivedWireCall(_ result: ToolResultMessage?) -> ToolCall? {
        guard let result else { return nil }
        return ToolCall(
            id: result.toolCallId,
            name: result.toolName,
            arguments: .object([:]),
            providerCallID: result.providerCallID
        )
    }

    nonisolated private static func wireAction(_ step: Step, callId: String, at: Date) -> (ToolCall, ToolResultMessage) {
        func result(_ name: String, _ text: String, artifacts: [Artifact] = [], isError: Bool) -> ToolResultMessage {
            ToolResultMessage(toolCallId: callId, toolName: name,
                              content: [.text(TextContent(text))] + artifacts.map(ContentBlock.attachment), isError: isError, timestamp: at)
        }
        switch step.kind {
        case let .execute(exec):
            let call = ToolCall(id: callId, name: "execute", arguments: .object(["source": .string(exec.source)]))
            let artifacts = exec.effects.reduce(into: [Artifact]()) { artifacts, effect in
                let artifact: Artifact?
                switch effect {
                case let .artifact(value), let .media(value): artifact = value
                case .invocation, .progress, .serviceControl, .serviceInspector, .shoveler, .video, .skill: artifact = nil
                }
                guard let artifact, !artifacts.contains(where: {
                    $0.fileName.caseInsensitiveCompare(artifact.fileName) == .orderedSame
                }) else { return }
                artifacts.append(artifact)
            }
            return (call, result("execute", exec.output, artifacts: artifacts, isError: exec.isError))
        case let .confirm(prompt):
            let call = ToolCall(id: callId, name: "ask_user_confirmation", arguments: .object(["body": .string(prompt.prompt)]))
            return (call, result("ask_user_confirmation", prompt.answer ?? "", isError: false))
        case let .choice(prompt):
            let call = ToolCall(id: callId, name: "ask_user_choice", arguments: .object([
                "body": .string(prompt.prompt),
                "options": .array(prompt.options.map { .string($0) }),
            ]))
            return (call, result("ask_user_choice", prompt.answer ?? "", isError: false))
        case .reasoning, .text, .contextCompaction, .wire:
            preconditionFailure()
        }
    }

    static func makeBlocks(from turns: [Turn]) -> [Block] {
        makeBlocksWithTurn(from: turns).map(\.0)
    }

    static func makeBlocksWithTurn(
        from turns: [Turn],
        turnOffset: Int = 0,
        ordinalOffset: Int = 0
    ) -> [(Block, Int)] {
        var out: [(Block, Int)] = []
        var trace: [TraceEntry] = []
        var bubble: [ContentItem] = []
        var groupStart = Date.distantPast
        var groupEntry = 0
        var groupSealedAt: Date?
        var ordinal = ordinalOffset

        func slot() -> UUID { defer { ordinal += 1 }; return StableID.uuid("\(ordinal)") }
        func openGroup(at: Date, entry: Int) {
            guard trace.isEmpty, bubble.isEmpty else { return }
            groupStart = at
            groupEntry = entry
            groupSealedAt = nil
        }
        func flushTrace() {
            guard !trace.isEmpty else { return }
            var previous = out.count - 1
            while previous >= 0,
                  out[previous].1 == groupEntry,
                  case let .agentContent(items) = out[previous].0.kind,
                  !items.isEmpty,
                  items.allSatisfy({ item in
                      switch item {
                      case let .text(text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      case .progress: false
                      case .serviceControl, .serviceInspector, .shoveler, .video, .artifact, .skill: true
                      }
                  }) {
                previous -= 1
            }
            if previous >= 0,
               previous < out.count - 1,
               out[previous].1 == groupEntry,
               case .thinking(var existing) = out[previous].0.kind {
                existing.entries.append(contentsOf: trace)
                existing.completedAt = groupSealedAt
                out[previous].0.kind = .thinking(existing)
                trace = []
                return
            }
            out.append((Block(id: slot(), createdAt: groupStart,
                              kind: .thinking(ThinkingTrace(entries: trace, completedAt: groupSealedAt))), groupEntry))
            trace = []
        }
        func flushBubble() {
            guard !bubble.isEmpty else { return }
            out.append((Block(id: slot(), createdAt: groupStart, kind: .agentContent(bubble)), groupEntry))
            bubble = []
        }

        for (offset, turnValue) in turns.enumerated() {
            let entry = turnOffset + offset
            switch turnValue {
            case let .user(turn, _):
                flushTrace()
                flushBubble()
                let kind: Block.Kind = if let invocation = turn.skillInvocation {
                    .userSkill(invocation, attachments: turn.attachments)
                } else {
                    .userText(turn.intent, attachments: turn.attachments)
                }
                out.append((Block(id: slot(), createdAt: turn.at, kind: kind), entry))
            case let .agent(turn, _):
                var remainingEmbedCounts = embedCounts(in: turn)
                let answers = Set(turn.steps.compactMap { step -> String? in
                    if case let .text(text) = step.kind { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    return nil
                })
                let generations = Dictionary(uniqueKeysWithValues: turn.generations.map { ($0.id, $0) })
                for step in turn.steps {
                    let generation = generations[step.generation]
                    let createdAt = generation?.at ?? turn.at
                    switch step.kind {
                    case let .reasoning(text):
                        if answers.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) { continue }
                        flushBubble()
                        openGroup(at: createdAt, entry: entry)
                        for (sectionIndex, section) in Reasoning.paragraphs(text).enumerated() {
                            trace.append(.reasoning(Reasoning(id: StableID.uuid("\(step.id.rawValue.uuidString).r\(sectionIndex)"), text: section)))
                        }
                        groupSealedAt = generation?.completedAt
                    case let .text(text):
                        flushTrace()
                        openGroup(at: createdAt, entry: entry)
                        bubble.append(.text(text))
                    case let .execute(execution):
                        for effect in execution.effects {
                            switch effect {
                            case let .invocation(invocation):
                                flushBubble()
                                openGroup(at: createdAt, entry: entry)
                                trace.append(.invocation(invocation))
                                groupSealedAt = generation?.completedAt
                            case let .progress(message):
                                flushTrace()
                                flushBubble()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.progress(message))
                                flushBubble()
                            case let .serviceControl(control):
                                flushTrace()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.serviceControl(control))
                            case let .serviceInspector(link):
                                flushTrace()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.serviceInspector(link))
                            case let .shoveler(shoveler):
                                flushTrace()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.shoveler(shoveler))
                            case let .video(video):
                                flushTrace()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.video(video))
                            case let .artifact(artifact):
                                guard consumeEmbed(
                                    .artifact(artifact.fileName.lowercased()),
                                    from: &remainingEmbedCounts
                                ) else { continue }
                                flushTrace()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.artifact(artifact))
                            case let .skill(skill):
                                guard consumeEmbed(
                                    .skill(skill.name.lowercased()),
                                    from: &remainingEmbedCounts
                                ) else { continue }
                                flushTrace()
                                openGroup(at: createdAt, entry: entry)
                                bubble.append(.skill(skill))
                            case .media:
                                break
                            }
                        }
                    case let .confirm(prompt):
                        flushTrace()
                        flushBubble()
                        let kind: ChatPromptKind = step.toolCall?.name == "ask_user_confirmation" ? .choice : .permission
                        out.append((Block(id: slot(), createdAt: createdAt,
                                          kind: .prompt(kind: kind, prompt: prompt.prompt, options: prompt.options, answer: prompt.answer, resolution: prompt.resolution)), entry))
                    case let .choice(prompt):
                        flushTrace()
                        flushBubble()
                        out.append((Block(id: slot(), createdAt: createdAt,
                                          kind: .prompt(kind: .choice, prompt: prompt.prompt, options: prompt.options, answer: prompt.answer, resolution: prompt.resolution)), entry))
                    case let .contextCompaction(value):
                        flushTrace()
                        flushBubble()
                        out.append((Block(id: slot(), createdAt: value.at, kind: .contextCompaction(value)), entry))
                    case .wire:
                        break
                    }
                }
            }
        }
        flushTrace()
        flushBubble()
        return out
    }

    private static func embedCounts(in turn: AgentTurn) -> [EmbedKey: Int] {
        turn.steps.reduce(into: [:]) { counts, step in
            guard case let .execute(execution) = step.kind else { return }
            for effect in execution.effects {
                let key: EmbedKey?
                switch effect {
                case let .artifact(artifact): key = .artifact(artifact.fileName.lowercased())
                case let .skill(skill): key = .skill(skill.name.lowercased())
                case .invocation, .progress, .serviceControl, .serviceInspector, .shoveler, .video, .media: key = nil
                }
                if let key { counts[key, default: 0] += 1 }
            }
        }
    }

    private static func consumeEmbed(_ key: EmbedKey, from counts: inout [EmbedKey: Int]) -> Bool {
        guard let count = counts[key], count > 1 else {
            counts.removeValue(forKey: key)
            return true
        }
        counts[key] = count - 1
        return false
    }
}

nonisolated enum StableID {
    static func uuid(_ path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
