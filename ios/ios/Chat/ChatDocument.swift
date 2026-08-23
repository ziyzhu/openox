import Foundation

nonisolated enum ChatDocumentEvent {
    case appendUser(intent: String, attachments: [Artifact], skillInvocation: UserSkillInvocation? = nil, at: Date, submissionID: SubmissionID? = nil, id: TurnID = TurnID())
    case beginAgentTurn(at: Date, id: TurnID = TurnID())
    case resumeAgentTurn(id: TurnID)
    case beginGeneration(model: String, at: Date, id: AgentGenerationID = AgentGenerationID())
    case setGenerationAssistant(AssistantMessage)
    case finishGeneration(TurnOutcome)
    case appendText(String, id: StepID = StepID())
    case replaceGenerationText(String, id: StepID = StepID())
    case beginExecution(source: String, id: StepID = StepID())
    case finishExecution(output: String, isError: Bool)
    case recordToolExchange(ToolCall, ToolResultMessage, id: StepID = StepID())
    case embedServiceControl(ServiceControl)
    case embedServiceInspector(ServiceInspectorLink)
    case embedShoveler(Shoveler)
    case embedVideo(VideoWidget)
    case embedArtifact(Artifact)
    case embedSkill(Skill)
    case attachMedia(Artifact)
    case appendInvocation(Invocation)
    case appendProgress(String)
    case resolveInvocation(id: UUID, outcome: Invocation.Outcome)
    case appendReasoning(String, id: StepID = StepID())
    case appendContextCompaction(ContextCompaction, id: StepID = StepID())
    case appendPrompt(AgentPrompt, choice: Bool, id: StepID = StepID())
    case resolvePrompt(id: StepID, answer: String, resolution: String?)
    case cancelPrompt(id: StepID, answer: String, resolution: String?)
    case finishAgentTurn(TurnOutcome)
    case sealLastTurn(at: Date)
    case sealAllTurns
    case truncate(beforeTurn: Int)
}

nonisolated struct ChatDocument {
    private(set) var turns: [Turn]
    private(set) var projection: [Block]
    private(set) var sourceTurnIDs: [RenderBlockID: TurnID]
    private var nextBlockOrdinal: Int

    init(turns: [Turn] = []) {
        var normalized = ChatFormat.normalize(turns)
        Self.reconcileMaterializedContent(in: &normalized)
        self.turns = normalized
        let projected = ChatProjection.renderWithSource(normalized)
        projection = projected.map(\.0)
        sourceTurnIDs = Dictionary(uniqueKeysWithValues: projected.map { block, turnIndex in
            (RenderBlockID(block.id), normalized[turnIndex].id)
        })
        nextBlockOrdinal = projection.count
        validateIDs()
    }

    static func replaying(_ turns: [Turn]) -> ChatDocument {
        var state = ChatDocument()
        for turnValue in ChatFormat.normalize(turns) {
            switch turnValue {
            case let .user(turn, id):
                state.apply(.appendUser(intent: turn.intent, attachments: turn.attachments, skillInvocation: turn.skillInvocation, at: turn.at, submissionID: turn.submissionID, id: id))
            case let .agent(turn, id):
                state.apply(.beginAgentTurn(at: turn.at, id: id))
                for generation in turn.generations {
                    state.apply(.beginGeneration(model: generation.model, at: generation.at, id: generation.id))
                    for step in turn.steps where step.generation == generation.id {
                        switch step.kind {
                        case let .reasoning(text):
                            state.apply(.appendReasoning(text, id: step.id))
                        case let .contextCompaction(value):
                            state.apply(.appendContextCompaction(value, id: step.id))
                        case let .text(text):
                            state.apply(.appendText(text, id: step.id))
                        case let .execute(execution):
                            state.apply(.beginExecution(source: execution.source, id: step.id))
                            for effect in execution.effects {
                                switch effect {
                                case let .invocation(invocation): state.apply(.appendInvocation(invocation))
                                case let .progress(message): state.apply(.appendProgress(message))
                                case let .serviceControl(control): state.apply(.embedServiceControl(control))
                                case let .serviceInspector(link): state.apply(.embedServiceInspector(link))
                                case let .shoveler(shoveler): state.apply(.embedShoveler(shoveler))
                                case let .video(video): state.apply(.embedVideo(video))
                                case let .artifact(artifact): state.apply(.embedArtifact(artifact))
                                case let .skill(skill): state.apply(.embedSkill(skill))
                                case let .media(artifact): state.apply(.attachMedia(artifact))
                                }
                            }
                            if execution.outcome != .running {
                                state.apply(.finishExecution(output: execution.output, isError: execution.isError))
                            }
                        case let .confirm(prompt):
                            state.replayPrompt(prompt, choice: false, id: step.id)
                        case let .choice(prompt):
                            state.replayPrompt(prompt, choice: true, id: step.id)
                        case .wire:
                            break
                        }
                        if let toolCall = step.toolCall, let toolResult = step.toolResult {
                            state.recordToolExchange(toolCall, result: toolResult, id: step.id)
                        }
                    }
                    if let assistant = generation.assistantMessage { state.setGenerationAssistant(assistant) }
                    if generation.outcome != .running { state.apply(.finishGeneration(generation.outcome)) }
                }
                if turn.outcome != .running { state.apply(.finishAgentTurn(turn.outcome)) }
            }
        }
        state.validateIDs()
        return state
    }

    var hasOpenAgentTurn: Bool {
        guard case let .agent(turn, _) = turns.last else { return false }
        return turn.outcome == .running
    }

    var hasOpenGeneration: Bool {
        guard case let .agent(turn, _) = turns.last, turn.outcome == .running else { return false }
        return turn.generations.last?.outcome == .running
    }

    var hasOpenExecution: Bool {
        guard let generation = openGeneration,
              case let .agent(turn, _) = turns.last,
              Self.openExecutionIndex(in: turn, generation: generation.id) != nil else { return false }
        return true
    }

    var lastAgentTurnID: TurnID? {
        guard case let .agent(_, id) = turns.last else { return nil }
        return id
    }

    var lastGenerationID: AgentGenerationID? {
        guard case let .agent(turn, _) = turns.last else { return nil }
        return turn.generations.last?.id
    }

    var preview: String? {
        for case let .user(turn, _) in turns {
            let trimmed = (turn.skillInvocation?.displayTitle ?? turn.intent).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        }
        return nil
    }

    var currentAgentTurnAt: Date {
        guard case let .agent(turn, _) = turns.last else { return Date() }
        return turn.at
    }

    var currentGenerationAt: Date {
        guard case let .agent(turn, _) = turns.last else { return currentAgentTurnAt }
        return turn.generations.last?.at ?? turn.at
    }

    var tailTextLength: Int {
        guard case let .agentContent(items) = projection.last?.kind else { return 0 }
        return items.reduce(0) { sum, item in
            if case let .text(text) = item { return sum + text.count }
            return sum
        }
    }

    func toWire() -> [Message] { ChatProjection.wire(turns) }
    func blocksWithTurn() -> [(Block, Int)] {
        let turnsByID = Dictionary(uniqueKeysWithValues: turns.enumerated().map { ($0.element.id, $0.offset) })
        return projection.compactMap { block in
            sourceTurnIDs[RenderBlockID(block.id)].flatMap { turnsByID[$0] }.map { (block, $0) }
        }
    }

    func blocksWithTurnID() -> [(block: Block, turnID: TurnID)] {
        projection.compactMap { block in
            sourceTurnIDs[RenderBlockID(block.id)].map { (block, $0) }
        }
    }

    mutating func renameArtifactReferences(from oldName: String, to newName: String, directory: URL) {
        let updated = turns.map { $0.replacingArtifact(named: oldName, with: newName, directory: directory) }
        guard updated != turns else { return }
        turns = updated
        reproject()
    }

    mutating func apply(_ event: ChatDocumentEvent) {
        switch event {
        case let .appendUser(intent, attachments, skillInvocation, at, submissionID, id):
            let entry = turns.count
            guard appendUser(intent: intent, attachments: attachments, skillInvocation: skillInvocation, at: at, submissionID: submissionID, id: id) else { return }
            let kind: Block.Kind = if let skillInvocation {
                .userSkill(skillInvocation, attachments: attachments)
            } else {
                .userText(intent, attachments: attachments)
            }
            appendBlock(Block(id: nextBlockID(), createdAt: at, kind: kind), entry: entry)
        case let .beginAgentTurn(at, id):
            beginAgentTurn(at: at, id: id)
        case let .resumeAgentTurn(id):
            resumeAgentTurn(id: id)
            reconcileTail()
        case let .beginGeneration(model, at, id):
            beginGeneration(model: model, at: at, id: id)
        case let .setGenerationAssistant(assistant):
            setGenerationAssistant(assistant)
        case let .finishGeneration(outcome):
            finishGeneration(outcome)
            reconcileTail()
        case let .appendText(delta, id):
            appendText(delta, id: id)
            let entry = turns.count - 1
            appendText(delta, entry: entry)
        case let .replaceGenerationText(text, id):
            replaceGenerationText(text, id: id)
            reconcileTail()
        case let .beginExecution(source, id):
            beginExecution(source: source, id: id)
        case let .finishExecution(output, isError):
            finishExecution(output: output, isError: isError)
            reconcileTail()
        case let .recordToolExchange(toolCall, result, id):
            recordToolExchange(toolCall, result: result, id: id)
        case let .embedServiceControl(control):
            embedServiceControl(control)
            reconcileTail()
        case let .embedServiceInspector(link):
            embedServiceInspector(link)
            reconcileTail()
        case let .embedShoveler(shoveler):
            embedShoveler(shoveler)
            reconcileTail()
        case let .embedVideo(video):
            embedVideo(video)
            reconcileTail()
        case let .embedArtifact(artifact):
            embedArtifact(artifact)
            reconcileTail()
        case let .embedSkill(skill):
            embedSkill(skill)
            reconcileTail()
        case let .attachMedia(artifact):
            attachMedia(artifact)
        case let .appendInvocation(invocation):
            appendInvocation(invocation)
            reconcileTail()
        case let .appendProgress(message):
            appendProgress(message)
            reconcileTail()
        case let .resolveInvocation(id, outcome):
            _ = resolveInvocation(id: id, outcome: outcome)
            reconcileTail()
        case let .appendReasoning(text, id):
            appendReasoning(text, id: id)
            reconcileTail()
        case let .appendContextCompaction(value, id):
            appendContextCompaction(value, id: id)
            reconcileTail()
        case let .appendPrompt(prompt, choice, id):
            appendPrompt(prompt, choice: choice, id: id)
            reconcileTail()
        case let .resolvePrompt(id, answer, resolution):
            resolvePrompt(id: id, answer: answer, resolution: resolution)
            reconcileTail()
        case let .cancelPrompt(id, answer, resolution):
            cancelPrompt(id: id, answer: answer, resolution: resolution)
            reconcileTail()
        case let .finishAgentTurn(outcome):
            finishAgentTurn(outcome)
            reconcileTail()
        case let .sealLastTurn(at):
            sealLastTurn(at: at)
            reconcileTail()
        case .sealAllTurns:
            sealAllTurns()
            reproject()
        case let .truncate(beforeTurn):
            turns = ChatFormat.normalize(Array(turns.prefix(beforeTurn)))
            reproject()
        }
    }

    private mutating func replayPrompt(_ prompt: AgentPrompt, choice: Bool, id: StepID) {
        let pending = AgentPrompt(prompt: prompt.prompt, options: prompt.options, outcome: .pending)
        apply(.appendPrompt(pending, choice: choice, id: id))
        switch prompt.outcome {
        case .pending:
            break
        case let .answered(answer, resolution):
            apply(.resolvePrompt(id: id, answer: answer, resolution: resolution))
        case let .cancelled(answer, resolution):
            apply(.cancelPrompt(id: id, answer: answer, resolution: resolution))
        }
    }

    private mutating func appendUser(
        intent: String,
        attachments: [Artifact],
        skillInvocation: UserSkillInvocation?,
        at: Date,
        submissionID: SubmissionID?,
        id: TurnID
    ) -> Bool {
        guard !hasOpenAgentTurn else {
            Self.reject("user-append-during-agent-turn")
            return false
        }
        turns.append(.user(UserTurn(
            intent: intent,
            attachments: attachments,
            at: at,
            submissionID: submissionID,
            skillInvocation: skillInvocation
        ), id: id))
        return true
    }

    private mutating func beginAgentTurn(at: Date, id: TurnID = TurnID()) {
        guard !hasOpenAgentTurn else {
            Self.reject("turn-begin-invalid")
            return
        }
        turns.append(.agent(AgentTurn(at: at, generations: [], steps: [], outcome: .running), id: id))
    }

    private mutating func resumeAgentTurn(id: TurnID) {
        guard case .agent(var turn, let existingID) = turns.last,
              existingID == id,
              turn.outcome != .running else {
            Self.reject("turn-resume-invalid")
            return
        }
        turn.outcome = .running
        turns[turns.count - 1] = .agent(turn, id: existingID)
    }

    private mutating func beginGeneration(model: String, at: Date, id: AgentGenerationID = AgentGenerationID()) {
        guard !hasOpenGeneration else {
            Self.reject("generation-begin-invalid")
            return
        }
        mutateTurn { turn in
            turn.generations.append(ModelGeneration(id: id, at: at, model: model, outcome: .running))
        }
    }

    private mutating func setGenerationAssistant(_ assistant: AssistantMessage) {
        mutateTurn { turn in
            guard let index = turn.generations.indices.last,
                  turn.generations[index].outcome == .running else {
                Self.reject("generation-assistant-invalid")
                return
            }
            turn.generations[index].assistantMessage = assistant
        }
    }

    private mutating func finishGeneration(_ outcome: TurnOutcome) {
        guard outcome != .running else {
            Self.reject("generation-finish-running")
            return
        }
        mutateTurn { turn in
            guard let index = turn.generations.indices.last,
                  turn.generations[index].outcome == .running else {
                Self.reject("generation-finish-invalid")
                return
            }
            Self.recoverInterruptedContent(in: &turn, generation: turn.generations[index].id)
            turn.generations[index].outcome = outcome
        }
    }

    private mutating func sealLastTurn(at: Date) {
        if hasOpenGeneration { finishGeneration(.completed(at: at)) }
        finishAgentTurn(.completed(at: at))
    }

    private mutating func sealAllTurns() {
        for index in turns.indices {
            guard case .agent(var turn, let id) = turns[index], turn.outcome == .running else { continue }
            for generationIndex in turn.generations.indices where turn.generations[generationIndex].outcome == .running {
                Self.recoverInterruptedContent(in: &turn, generation: turn.generations[generationIndex].id)
                turn.generations[generationIndex].outcome = .cancelled(at: turn.generations[generationIndex].at)
            }
            turn.outcome = .cancelled(at: turn.at)
            turns[index] = .agent(turn, id: id)
        }
    }

    private mutating func appendReasoning(_ text: String, id: StepID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let generation = openGeneration else {
            if !trimmed.isEmpty { Self.reject("step-append-invalid") }
            return
        }
        mutateTurn { $0.steps.append(Step(id: id, generation: generation.id, kind: .reasoning(trimmed))) }
    }

    private mutating func appendContextCompaction(_ value: ContextCompaction, id: StepID) {
        guard case let .agent(turn, _) = turns.last, let generation = turn.generations.last else {
            Self.reject("context-compaction-append-invalid")
            return
        }
        mutateTurn { $0.steps.append(Step(id: id, generation: generation.id, kind: .contextCompaction(value))) }
    }

    private mutating func appendText(_ delta: String, id: StepID = StepID()) {
        guard !delta.isEmpty, let generation = openGeneration else {
            if !delta.isEmpty { Self.reject("step-append-invalid") }
            return
        }
        mutateTurn { turn in
            if let index = turn.steps.indices.last,
               turn.steps[index].generation == generation.id,
               case let .text(previous) = turn.steps[index].kind {
                turn.steps[index].kind = .text(previous + delta)
            } else {
                turn.steps.append(Step(id: id, generation: generation.id, kind: .text(delta)))
            }
        }
    }

    private mutating func replaceGenerationText(_ text: String, id: StepID) {
        guard let generation = openGeneration else {
            Self.reject("step-replace-invalid")
            return
        }
        mutateTurn { turn in
            let textIndexes = turn.steps.indices.filter { index in
                guard turn.steps[index].generation == generation.id else { return false }
                if case .text = turn.steps[index].kind { return true }
                return false
            }
            let insertionIndex = textIndexes.first ?? turn.steps.endIndex
            let textID = textIndexes.first.map { turn.steps[$0].id } ?? id
            turn.steps.removeAll { step in
                guard step.generation == generation.id else { return false }
                if case .text = step.kind { return true }
                return false
            }
            if !text.isEmpty {
                turn.steps.insert(Step(id: textID, generation: generation.id, kind: .text(text)), at: min(insertionIndex, turn.steps.endIndex))
            }
        }
    }

    private mutating func beginExecution(source: String, id: StepID) {
        appendStep(id: id, kind: .execute(Execution(source: source, effects: [], outcome: .running)))
    }

    private mutating func recordToolExchange(_ toolCall: ToolCall, result: ToolResultMessage, id: StepID) {
        guard let generation = openGeneration else {
            Self.reject("tool-exchange-invalid")
            return
        }
        mutateTurn { turn in
            let candidates = turn.steps.indices.reversed().filter {
                guard turn.steps[$0].generation == generation.id,
                      turn.steps[$0].toolCall == nil else { return false }
                switch turn.steps[$0].kind {
                case .execute, .confirm, .choice: return true
                case .reasoning, .text, .contextCompaction, .wire: return false
                }
            }
            let matching = candidates.first { index in
                switch (toolCall.name, turn.steps[index].kind) {
                case ("execute", .execute), ("run_javascript", .execute), ("ask_user_confirmation", .confirm), ("ask_user_choice", .choice): true
                default: false
                }
            }
            if let index = matching ?? candidates.first {
                turn.steps[index].toolCall = toolCall
                turn.steps[index].toolResult = result
                return
            }
            turn.steps.append(Step(
                id: id,
                generation: generation.id,
                kind: .wire,
                toolCall: toolCall,
                toolResult: result
            ))
        }
    }

    private mutating func appendInvocation(_ invocation: Invocation) {
        mutateExecution { $0.effects.append(.invocation(invocation)) }
    }

    private mutating func appendProgress(_ message: String) {
        mutateExecution { $0.effects.append(.progress(message)) }
    }

    private mutating func resolveInvocation(id: UUID, outcome: Invocation.Outcome) -> Bool {
        guard let generation = openGeneration else {
            Log.session.info("ChatDocument.resolveInvocation ignored id=\(id) reason=no-open-generation")
            return false
        }
        var resolved = false
        mutateTurn { turn in
            for stepIndex in turn.steps.indices.reversed() where turn.steps[stepIndex].generation == generation.id {
                guard case .execute(var execution) = turn.steps[stepIndex].kind else { continue }
                for effectIndex in execution.effects.indices {
                    guard case .invocation(var invocation) = execution.effects[effectIndex],
                          invocation.id == id,
                          invocation.outcome == .running else { continue }
                    invocation.outcome = outcome
                    execution.effects[effectIndex] = .invocation(invocation)
                    turn.steps[stepIndex].kind = .execute(execution)
                    resolved = true
                    return
                }
            }
        }
        if !resolved {
            Log.session.info("ChatDocument.resolveInvocation ignored id=\(id) reason=settled")
        }
        return resolved
    }

    private mutating func embedServiceControl(_ control: ServiceControl) {
        mutateExecution { $0.effects.append(.serviceControl(control)) }
    }

    private mutating func embedServiceInspector(_ link: ServiceInspectorLink) {
        mutateExecution { $0.effects.append(.serviceInspector(link)) }
    }

    private mutating func embedShoveler(_ shoveler: Shoveler) {
        mutateExecution { $0.effects.append(.shoveler(shoveler)) }
    }

    private mutating func embedVideo(_ video: VideoWidget) {
        mutateExecution { $0.effects.append(.video(video)) }
    }

    private mutating func embedArtifact(_ artifact: Artifact) {
        upsertExecutionEffect(.artifact(artifact)) { effect in
            guard case let .artifact(existing) = effect else { return false }
            return existing.fileName.caseInsensitiveCompare(artifact.fileName) == .orderedSame
        }
    }

    private mutating func embedSkill(_ skill: Skill) {
        upsertExecutionEffect(.skill(skill)) { effect in
            guard case let .skill(existing) = effect else { return false }
            return existing.name.caseInsensitiveCompare(skill.name) == .orderedSame
        }
    }

    private mutating func upsertExecutionEffect(
        _ effect: ExecutionEffect,
        matching isMatch: (ExecutionEffect) -> Bool
    ) {
        mutateExecution { execution in
            if let index = execution.effects.lastIndex(where: isMatch) {
                execution.effects[index] = effect
            } else {
                execution.effects.append(effect)
            }
        }
    }

    private mutating func attachMedia(_ artifact: Artifact) {
        mutateExecution { $0.effects.append(.media(artifact)) }
    }

    private mutating func finishExecution(output: String, isError: Bool) {
        mutateExecution { execution in
            for index in execution.effects.indices {
                guard case .invocation(var invocation) = execution.effects[index], invocation.outcome == .running else { continue }
                let outcome = Invocation.Outcome.failed("Execution finished before the invocation completed")
                invocation.outcome = outcome
                execution.effects[index] = .invocation(invocation)
            }
            execution.outcome = isError ? .failed(output: output) : .succeeded(output: output)
        }
    }

    private mutating func appendPrompt(_ prompt: AgentPrompt, choice: Bool, id: StepID) {
        appendStep(id: id, kind: choice ? .choice(prompt) : .confirm(prompt))
    }

    private mutating func resolvePrompt(id: StepID, answer: String, resolution: String? = nil) {
        finishPrompt(id: id, outcome: .answered(answer: answer, resolution: resolution))
    }

    private mutating func cancelPrompt(id: StepID, answer: String, resolution: String?) {
        finishPrompt(id: id, outcome: .cancelled(answer: answer, resolution: resolution))
    }

    private mutating func finishAgentTurn(_ outcome: TurnOutcome) {
        guard outcome != .running else {
            Self.reject("turn-finish-running")
            return
        }
        guard !hasOpenGeneration else {
            Self.reject("turn-finish-generation-open")
            return
        }
        guard case .agent(var turn, let id) = turns.last, turn.outcome == .running else {
            Self.reject("turn-finish-invalid")
            return
        }
        turn.outcome = outcome
        turns[turns.count - 1] = .agent(turn, id: id)
    }

    private var openGeneration: ModelGeneration? {
        guard case let .agent(turn, _) = turns.last,
              turn.outcome == .running,
              let generation = turn.generations.last,
              generation.outcome == .running else { return nil }
        return generation
    }

    private mutating func appendStep(id: StepID, kind: Step.Kind) {
        guard let generation = openGeneration else {
            Self.reject("step-append-invalid")
            return
        }
        mutateTurn { $0.steps.append(Step(id: id, generation: generation.id, kind: kind)) }
    }

    private mutating func finishPrompt(id: StepID, outcome: PromptOutcome) {
        mutateTurn { turn in
            guard let index = turn.steps.firstIndex(where: { $0.id == id }) else {
                Self.reject("prompt-finish-invalid")
                return
            }
            switch turn.steps[index].kind {
            case var .confirm(prompt) where prompt.outcome == .pending:
                prompt.outcome = outcome
                turn.steps[index].kind = .confirm(prompt)
            case var .choice(prompt) where prompt.outcome == .pending:
                prompt.outcome = outcome
                turn.steps[index].kind = .choice(prompt)
            case .reasoning, .text, .execute, .confirm, .choice, .contextCompaction, .wire:
                Self.reject("prompt-finish-invalid")
            }
        }
    }

    private mutating func mutateTurn(_ body: (inout AgentTurn) -> Void) {
        guard case .agent(var turn, let id) = turns.last, turn.outcome == .running else {
            Self.reject("turn-mutation-invalid")
            return
        }
        body(&turn)
        turns[turns.count - 1] = .agent(turn, id: id)
    }

    private mutating func mutateExecution(_ body: (inout Execution) -> Void) {
        guard let generation = openGeneration else {
            Self.reject("execution-mutation-invalid")
            return
        }
        mutateTurn { turn in
            guard let index = Self.openExecutionIndex(in: turn, generation: generation.id),
                  case .execute(var execution) = turn.steps[index].kind else {
                Self.reject("execution-mutation-invalid")
                return
            }
            body(&execution)
            turn.steps[index].kind = .execute(execution)
        }
    }

    private static func openExecutionIndex(in turn: AgentTurn, generation: AgentGenerationID) -> Int? {
        turn.steps.lastIndex { step in
            guard step.generation == generation,
                  case let .execute(execution) = step.kind else { return false }
            return execution.outcome == .running
        }
    }

    private static func recoverInterruptedContent(in turn: inout AgentTurn, generation: AgentGenerationID) {
        reconcileMaterializedContent(in: &turn, generation: generation)
        for index in turn.steps.indices where turn.steps[index].generation == generation {
            switch turn.steps[index].kind {
            case .execute(var execution):
                if execution.outcome == .running {
                    execution.outcome = .failed(output: "Interrupted")
                }
                for effectIndex in execution.effects.indices {
                    guard case .invocation(var invocation) = execution.effects[effectIndex], invocation.outcome == .running else { continue }
                    invocation.outcome = .failed("Interrupted")
                    execution.effects[effectIndex] = .invocation(invocation)
                }
                turn.steps[index].kind = .execute(execution)
            case .confirm(var prompt):
                if prompt.outcome == .pending {
                    prompt.outcome = .cancelled(answer: "The user stopped before answering.", resolution: "Stopped")
                }
                turn.steps[index].kind = .confirm(prompt)
            case .choice(var prompt):
                if prompt.outcome == .pending {
                    prompt.outcome = .cancelled(answer: "The user stopped before answering.", resolution: "Stopped")
                }
                turn.steps[index].kind = .choice(prompt)
            case .reasoning, .text, .contextCompaction, .wire:
                break
            }
        }
    }

    private struct Materialization {
        let completesExecution: Bool
    }

    private static func reconcileMaterializedContent(in turns: inout [Turn]) {
        for index in turns.indices {
            guard case .agent(var turn, let id) = turns[index] else { continue }
            for generation in turn.generations {
                reconcileMaterializedContent(in: &turn, generation: generation.id)
            }
            turns[index] = .agent(turn, id: id)
        }
    }

    private static func reconcileMaterializedContent(in turn: inout AgentTurn, generation: AgentGenerationID) {
        let steps = turn.steps
        for stepIndex in turn.steps.indices where turn.steps[stepIndex].generation == generation {
            guard case .execute(var execution) = turn.steps[stepIndex].kind else { continue }
            var completesExecution = false
            for effectIndex in execution.effects.indices {
                guard case .invocation(var invocation) = execution.effects[effectIndex] else { continue }
                let materialization = materialization(
                    for: invocation,
                    after: effectIndex,
                    in: stepIndex,
                    generation: generation,
                    steps: steps
                )
                if let materialization { completesExecution = completesExecution || materialization.completesExecution }
                if materialization != nil {
                    switch invocation.outcome {
                    case .running:
                        invocation.outcome = .succeeded(nil)
                        Log.session.info("ChatDocument.recover materialized invocation=\(invocation.name) id=\(invocation.id)")
                    case let .failed(error) where error == "Interrupted":
                        invocation.outcome = .succeeded(nil)
                        Log.session.info("ChatDocument.recover materialized invocation=\(invocation.name) id=\(invocation.id)")
                    case .succeeded, .failed:
                        break
                    }
                }
                execution.effects[effectIndex] = .invocation(invocation)
            }
            let invocations = execution.effects.compactMap { effect -> Invocation? in
                if case let .invocation(invocation) = effect { return invocation }
                return nil
            }
            let allSucceeded = !invocations.isEmpty && invocations.allSatisfy {
                if case .succeeded = $0.outcome { return true }
                return false
            }
            let interrupted: Bool
            switch execution.outcome {
            case .running: interrupted = true
            case let .failed(output): interrupted = output == "Interrupted"
            case .succeeded: interrupted = false
            }
            if interrupted, completesExecution, allSucceeded {
                execution.outcome = .succeeded(output: "[]")
                Log.session.info("ChatDocument.recover materialized execution step=\(turn.steps[stepIndex].id)")
            }
            turn.steps[stepIndex].kind = .execute(execution)
        }
    }

    private static func materialization(
        for invocation: Invocation,
        after effectIndex: Int,
        in stepIndex: Int,
        generation: AgentGenerationID,
        steps: [Step]
    ) -> Materialization? {
        guard let name = InvocationName(rawValue: invocation.name) else { return nil }
        let filename = invocation.args.objectValue?["filename"]?.stringValue
        let domain = invocation.args.objectValue?["domain"]?.stringValue
        for index in stepIndex..<steps.count where steps[index].generation == generation {
            guard case let .execute(execution) = steps[index].kind else { continue }
            let start = index == stepIndex ? effectIndex + 1 : 0
            for effect in execution.effects.dropFirst(start) {
                switch effect {
                case let .artifact(artifact):
                    guard name == .artifactPresent,
                          let filename,
                          artifact.fileName.caseInsensitiveCompare(filename) == .orderedSame else { continue }
                    let completed: Bool
                    if index != stepIndex, execution.source.isEmpty, case .succeeded = execution.outcome {
                        completed = true
                    } else {
                        completed = false
                    }
                    return Materialization(completesExecution: completed)
                case let .serviceControl(control):
                    guard let domain else { continue }
                    if name == .serviceSignIn, case .signIn(let controlDomain, _) = control, controlDomain == domain {
                        return Materialization(completesExecution: true)
                    }
                    if name == .serviceSolve, case .botControl(let controlDomain, _, _) = control, controlDomain == domain {
                        return Materialization(completesExecution: true)
                    }
                    if name == .servicePayment, case .payment(let controlDomain, _, _) = control, controlDomain == domain {
                        return Materialization(completesExecution: true)
                    }
                case .serviceInspector:
                    continue
                case .shoveler:
                    guard name == .widgetShoveler else { continue }
                    return Materialization(completesExecution: true)
                case .video:
                    guard name == .widgetVideo else { continue }
                    return Materialization(completesExecution: true)
                case .invocation:
                    return nil
                case .progress:
                    continue
                case .media:
                    continue
                case .skill:
                    continue
                }
            }
        }
        return nil
    }

    private mutating func nextBlockID() -> UUID {
        defer { nextBlockOrdinal += 1 }
        return StableID.uuid("\(nextBlockOrdinal)")
    }

    private mutating func appendText(_ delta: String, entry: Int) {
        guard let block = projection.indices.last else {
            projection.append(Block(id: nextBlockID(), createdAt: currentGenerationAt, kind: .agentContent([.text(delta)])))
            sourceTurnIDs[RenderBlockID(projection.last!.id)] = turns[entry].id
            return
        }
        guard case .agentContent(var items) = projection[block].kind else {
            projection.append(Block(id: nextBlockID(), createdAt: currentGenerationAt, kind: .agentContent([.text(delta)])))
            sourceTurnIDs[RenderBlockID(projection.last!.id)] = turns[entry].id
            return
        }
        if let item = items.indices.last, case let .text(text) = items[item] {
            items[item] = .text(text + delta)
        } else {
            items.append(.text(delta))
        }
        projection[block].kind = .agentContent(items)
    }

    private mutating func reproject() {
        let projected = ChatProjection.renderWithSource(turns)
        projection = projected.map(\.0)
        sourceTurnIDs = Dictionary(uniqueKeysWithValues: projected.map { block, entry in
            (RenderBlockID(block.id), turns[entry].id)
        })
        nextBlockOrdinal = projection.count
    }

    private mutating func reconcileTail() {
        guard !turns.isEmpty else { return }
        var entryStart = turns.count - 1
        while entryStart > 0 {
            guard case .agent(_, _) = turns[entryStart - 1] else { break }
            entryStart -= 1
        }
        let entryIndexes = Dictionary(uniqueKeysWithValues: turns.enumerated().map { ($0.element.id, $0.offset) })
        let blockStart = projection.firstIndex { block in
            sourceTurnIDs[RenderBlockID(block.id)].flatMap { entryIndexes[$0] }.map { $0 >= entryStart } ?? false
        } ?? projection.count
        let projected = ChatProjection.renderWithSource(
            Array(turns[entryStart...]),
            turnOffset: entryStart,
            ordinalOffset: blockStart
        )
        projection.replaceSubrange(blockStart..<projection.endIndex, with: projected.map(\.0))
        sourceTurnIDs = sourceTurnIDs.filter { id, _ in projection.prefix(blockStart).contains(where: { $0.id == id.rawValue }) }
        for (block, entry) in projected { sourceTurnIDs[RenderBlockID(block.id)] = turns[entry].id }
        nextBlockOrdinal = projection.count
    }

    private mutating func appendBlock(_ block: Block, entry: Int) {
        projection.append(block)
        sourceTurnIDs[RenderBlockID(block.id)] = turns[entry].id
    }

    private func validateIDs() {
        var ids = Set<UUID>()
        var count = 0
        for turnValue in turns {
            count += 1
            ids.insert(turnValue.id.rawValue)
            guard case let .agent(turn, _) = turnValue else { continue }
            for step in turn.steps {
                count += 1
                ids.insert(step.id.rawValue)
            }
        }
        guard ids.count != count else { return }
        Log.session.error("ChatDocument.duplicate-id ids=\(ids.count) records=\(count)")
    }

    private static func reject(_ event: String) {
        Log.session.error("ChatDocument.reject event=\(event)")
    }
}
