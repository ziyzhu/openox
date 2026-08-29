import Foundation

nonisolated enum ChatFormat {
    static let currentSchemaVersion = 1
}

nonisolated enum Turn: Equatable, Identifiable, Sendable {
    case user(UserTurn, id: TurnID = TurnID())
    case agent(AgentTurn, id: TurnID = TurnID())

    var id: TurnID {
        switch self {
        case let .user(_, id), let .agent(_, id): id
        }
    }

    var at: Date {
        switch self {
        case let .user(turn, _): turn.at
        case let .agent(turn, _): turn.at
        }
    }
}

nonisolated struct UserTurn: Codable, Equatable, Sendable {
    var intent: String
    var attachments: [Artifact]
    var at: Date
    var submissionID: SubmissionID? = nil
    var skillInvocation: UserSkillInvocation? = nil
}

nonisolated struct UserSkillInvocation: Codable, Equatable, Sendable {
    let skill: Skill
    let argument: String

    var expandedIntent: String {
        argument.isEmpty ? skill.instructions : "\(skill.instructions)\n\n\(argument)"
    }

    var displayTitle: String {
        argument.isEmpty ? "/\(skill.displayName)" : argument
    }
}

nonisolated struct AgentTurn: Codable, Equatable, Sendable {
    var at: Date
    var generations: [ModelGeneration]
    var steps: [Step]
    var outcome: TurnOutcome
}

nonisolated struct ModelGeneration: Codable, Equatable, Identifiable, Sendable {
    let id: AgentGenerationID
    var at: Date
    var model: String
    var outcome: TurnOutcome
    var assistantMessage: AssistantMessage? = nil

    var completedAt: Date? { outcome.completedAt }
}

nonisolated enum TurnOutcome: Equatable, Codable, Sendable {
    case running
    case completed(at: Date)
    case failed(at: Date, message: String)
    case cancelled(at: Date)

    var completedAt: Date? {
        switch self {
        case .running: nil
        case let .completed(at), let .failed(at, _), let .cancelled(at): at
        }
    }

    var error: String? {
        switch self {
        case .running, .completed: nil
        case let .failed(_, message): message
        case .cancelled: "aborted"
        }
    }
}

nonisolated extension Collection where Element == Turn {
    var latestContextCompaction: ContextCompaction? {
        for turn in reversed() {
            guard case let .agent(agent, _) = turn else { continue }
            for step in agent.steps.reversed() {
                if case let .contextCompaction(compaction) = step.kind { return compaction }
            }
        }
        return nil
    }

    var requiresContextCheckpoint: Bool { latestContextCompaction != nil }

    var latestCompletedResponse: String? {
        for turn in reversed() {
            guard case let .agent(agent, _) = turn,
                  case .completed = agent.outcome else { continue }
            let response = agent.steps.compactMap { step in
                if case let .text(text) = step.kind { return text }
                return nil
            }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            if !response.isEmpty { return response }
        }
        return nil
    }
}

nonisolated struct Step: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case reasoning(String)
        case text(String)
        case execute(Execution)
        case confirm(AgentPrompt)
        case choice(AgentPrompt)
        case contextCompaction(ContextCompaction)
        case wire
    }

    let id: StepID
    let generation: AgentGenerationID
    var kind: Kind
    var toolCall: ToolCall?
    var toolResult: ToolResultMessage?

    init(
        id: StepID = StepID(),
        generation: AgentGenerationID,
        kind: Kind,
        toolCall: ToolCall? = nil,
        toolResult: ToolResultMessage? = nil
    ) {
        self.id = id
        self.generation = generation
        self.kind = kind
        self.toolCall = toolCall
        self.toolResult = toolResult
    }
}

nonisolated struct ContextCompaction: Codable, Equatable, Sendable {
    let at: Date
    let tokensBefore: Int
}

nonisolated struct Execution: Codable, Equatable, Sendable {
    var source: String
    var effects: [ExecutionEffect]
    var outcome: ExecutionOutcome

    var output: String {
        switch outcome {
        case .running: ""
        case let .succeeded(output), let .failed(output): output
        }
    }

    var isError: Bool { if case .failed = outcome { true } else { false } }
}

nonisolated enum ExecutionOutcome: Equatable, Codable, Sendable {
    case running
    case succeeded(output: String)
    case failed(output: String)
}

nonisolated enum ExecutionEffect: Equatable, Sendable {
    case invocation(Invocation)
    case progress(String)
    case serviceControl(ServiceControl)
    case serviceInspector(ServiceInspectorLink)
    case shoveler(Shoveler)
    case video(VideoWidget)
    case artifact(Artifact)
    case skill(Skill)
    case media(Artifact)
}

nonisolated struct AgentPrompt: Codable, Equatable, Sendable {
    var prompt: String
    var options: [String]
    var outcome: PromptOutcome

    var answer: String? {
        switch outcome {
        case .pending: nil
        case let .answered(answer, _), let .cancelled(answer, _): answer
        }
    }

    var resolution: String? {
        switch outcome {
        case .pending: nil
        case let .answered(_, resolution), let .cancelled(_, resolution): resolution
        }
    }
}

nonisolated enum PromptOutcome: Equatable, Codable, Sendable {
    case pending
    case answered(answer: String, resolution: String?)
    case cancelled(answer: String, resolution: String?)
}

nonisolated struct ChatMeta: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion: Int
    let id: UUID
    let createdAt: Date
    var lastActivity: Date?
    var title: String?
    var isFavorite: Bool
    var modelID: String?
    var clientID: String?
    var reasoningEffort: String?
    var monoRepositoryHash: String?
    var attachedServiceDomains: [String]
    var preview: String?
    var hasUnreadResponse: Bool
    var scheduledSkillID: UUID?

    init(
        schemaVersion: Int = ChatFormat.currentSchemaVersion,
        id: UUID,
        createdAt: Date,
        lastActivity: Date?,
        title: String?,
        isFavorite: Bool,
        modelID: String?,
        clientID: String?,
        reasoningEffort: String? = nil,
        monoRepositoryHash: String?,
        attachedServiceDomains: [String],
        preview: String?,
        hasUnreadResponse: Bool = false,
        scheduledSkillID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.lastActivity = lastActivity
        self.title = title
        self.isFavorite = isFavorite
        self.modelID = modelID
        self.clientID = clientID
        self.reasoningEffort = reasoningEffort
        self.monoRepositoryHash = monoRepositoryHash
        self.attachedServiceDomains = attachedServiceDomains
        self.preview = preview
        self.hasUnreadResponse = hasUnreadResponse
        self.scheduledSkillID = scheduledSkillID
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return SkillFiles.displayTitle(preview) }
        return "New chat"
    }

    var activityDate: Date { lastActivity ?? createdAt }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case lastActivity
        case title
        case isFavorite
        case modelID
        case clientID
        case reasoningEffort
        case monoRepositoryHash
        case attachedServiceDomains
        case preview
        case hasUnreadResponse
        case scheduledSkillID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastActivity = try values.decodeIfPresent(Date.self, forKey: .lastActivity)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        modelID = try values.decodeIfPresent(String.self, forKey: .modelID)
        clientID = try values.decodeIfPresent(String.self, forKey: .clientID)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        monoRepositoryHash = try values.decodeIfPresent(String.self, forKey: .monoRepositoryHash)
        attachedServiceDomains = try values.decode([String].self, forKey: .attachedServiceDomains)
        preview = try values.decodeIfPresent(String.self, forKey: .preview)
        hasUnreadResponse = try values.decodeIfPresent(Bool.self, forKey: .hasUnreadResponse) ?? false
        scheduledSkillID = try values.decodeIfPresent(UUID.self, forKey: .scheduledSkillID)
    }
}

nonisolated extension TurnOutcome {
    private enum CodingKeys: String, CodingKey { case type, at, message }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "running": self = .running
        case "completed": self = .completed(at: try values.decode(Date.self, forKey: .at))
        case "failed": self = .failed(
            at: try values.decode(Date.self, forKey: .at),
            message: try values.decode(String.self, forKey: .message)
        )
        case "cancelled": self = .cancelled(at: try values.decode(Date.self, forKey: .at))
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown turn outcome '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try values.encode("running", forKey: .type)
        case let .completed(at):
            try values.encode("completed", forKey: .type)
            try values.encode(at, forKey: .at)
        case let .failed(at, message):
            try values.encode("failed", forKey: .type)
            try values.encode(at, forKey: .at)
            try values.encode(message, forKey: .message)
        case let .cancelled(at):
            try values.encode("cancelled", forKey: .type)
            try values.encode(at, forKey: .at)
        }
    }
}

nonisolated extension ExecutionOutcome {
    private enum CodingKeys: String, CodingKey { case type, output }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "running": self = .running
        case "succeeded": self = .succeeded(output: try values.decode(String.self, forKey: .output))
        case "failed": self = .failed(output: try values.decode(String.self, forKey: .output))
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown execution outcome '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try values.encode("running", forKey: .type)
        case let .succeeded(output):
            try values.encode("succeeded", forKey: .type)
            try values.encode(output, forKey: .output)
        case let .failed(output):
            try values.encode("failed", forKey: .type)
            try values.encode(output, forKey: .output)
        }
    }
}

nonisolated extension PromptOutcome {
    private enum CodingKeys: String, CodingKey { case type, answer, resolution }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "pending": self = .pending
        case "answered": self = .answered(
            answer: try values.decode(String.self, forKey: .answer),
            resolution: try values.decodeIfPresent(String.self, forKey: .resolution)
        )
        case "cancelled": self = .cancelled(
            answer: try values.decode(String.self, forKey: .answer),
            resolution: try values.decodeIfPresent(String.self, forKey: .resolution)
        )
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown prompt outcome '\(type)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try values.encode("pending", forKey: .type)
        case let .answered(answer, resolution):
            try values.encode("answered", forKey: .type)
            try values.encode(answer, forKey: .answer)
            try values.encodeIfPresent(resolution, forKey: .resolution)
        case let .cancelled(answer, resolution):
            try values.encode("cancelled", forKey: .type)
            try values.encode(answer, forKey: .answer)
            try values.encodeIfPresent(resolution, forKey: .resolution)
        }
    }
}

nonisolated extension Turn: Codable {
    private enum CodingKeys: String, CodingKey { case id, type, user, agent }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(TurnID.self, forKey: .id)
        switch try c.decode(String.self, forKey: .type) {
        case "user": self = .user(try c.decode(UserTurn.self, forKey: .user), id: id)
        case "agent": self = .agent(try c.decode(AgentTurn.self, forKey: .agent), id: id)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown chat turn type '\(other)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .user(v, id): try c.encode(id, forKey: .id); try c.encode("user", forKey: .type); try c.encode(v, forKey: .user)
        case let .agent(v, id): try c.encode(id, forKey: .id); try c.encode("agent", forKey: .type); try c.encode(v, forKey: .agent)
        }
    }
}

nonisolated extension ChatFormat {
    static func normalize(_ turns: [Turn]) -> [Turn] {
        var normalized: [Turn] = []
        for turn in turns {
            guard case let .agent(incoming, _) = turn,
                  case let .agent(existing, existingID) = normalized.last else {
                normalized.append(turn)
                continue
            }
            normalized[normalized.count - 1] = .agent(
                AgentTurn(
                    at: existing.at,
                    generations: existing.generations + incoming.generations,
                    steps: existing.steps + incoming.steps,
                    outcome: incoming.outcome
                ),
                id: existingID
            )
        }
        return normalized
    }
}

nonisolated extension Turn {
    func replacingArtifact(named oldName: String, with newName: String, directory: URL) -> Turn {
        func replace(_ artifact: Artifact) -> Artifact {
            artifact.fileName.caseInsensitiveCompare(oldName) == .orderedSame
                ? Artifact(fileName: newName, directory: directory)
                : artifact
        }
        func replace(_ content: [ContentBlock]) -> [ContentBlock] {
            content.map { block in
                guard case .attachment(let artifact) = block else { return block }
                return .attachment(replace(artifact))
            }
        }
        switch self {
        case .user(var turn, let id):
            turn.attachments = turn.attachments.map(replace)
            return .user(turn, id: id)
        case .agent(var turn, let id):
            for index in turn.steps.indices {
                if var result = turn.steps[index].toolResult {
                    result.content = replace(result.content)
                    turn.steps[index].toolResult = result
                }
                guard case var .execute(execution) = turn.steps[index].kind else { continue }
                execution.effects = execution.effects.map { effect in
                    switch effect {
                    case let .artifact(artifact): return .artifact(replace(artifact))
                    case let .media(artifact): return .media(replace(artifact))
                    case let .shoveler(shoveler):
                        return .shoveler(Shoveler(
                            cards: shoveler.cards.map { card in
                                ShovelerCard(
                                    image: card.image,
                                    title: card.title,
                                    description: card.description,
                                    badge: card.badge,
                                    artifact: card.artifact.map(replace)
                                )
                            }
                        ))
                    case let .video(video):
                        guard case let .artifact(artifact) = video.source else { return effect }
                        return .video(VideoWidget(
                            source: .artifact(replace(artifact))
                        ))
                    case .invocation, .progress, .serviceControl, .serviceInspector, .skill: return effect
                    }
                }
                turn.steps[index].kind = .execute(execution)
            }
            for index in turn.generations.indices {
                guard var assistant = turn.generations[index].assistantMessage else { continue }
                assistant.content = replace(assistant.content)
                turn.generations[index].assistantMessage = assistant
            }
            return .agent(turn, id: id)
        }
    }
}

nonisolated extension Step: Codable {
    private enum CodingKeys: String, CodingKey { case id, generation, type, reasoning, text, contextCompaction, action, toolCall, toolResult }
    private enum ActionCodingKeys: String, CodingKey { case type, execute, confirm, choice }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(StepID.self, forKey: .id)
        let generation = try c.decode(AgentGenerationID.self, forKey: .generation)
        let kind: Kind
        switch try c.decode(String.self, forKey: .type) {
        case "reasoning": kind = .reasoning(try c.decode(String.self, forKey: .reasoning))
        case "text": kind = .text(try c.decode(String.self, forKey: .text))
        case "contextCompaction": kind = .contextCompaction(try c.decode(ContextCompaction.self, forKey: .contextCompaction))
        case "wire": kind = .wire
        case "action":
            let action = try c.nestedContainer(keyedBy: ActionCodingKeys.self, forKey: .action)
            switch try action.decode(String.self, forKey: .type) {
            case "execute": kind = .execute(try action.decode(Execution.self, forKey: .execute))
            case "confirm": kind = .confirm(try action.decode(AgentPrompt.self, forKey: .confirm))
            case "choice": kind = .choice(try action.decode(AgentPrompt.self, forKey: .choice))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: action, debugDescription: "Unknown step action type '\(other)'")
            }
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown step type '\(other)'")
        }
        self.init(
            id: id,
            generation: generation,
            kind: kind,
            toolCall: try c.decodeIfPresent(ToolCall.self, forKey: .toolCall),
            toolResult: try c.decodeIfPresent(ToolResultMessage.self, forKey: .toolResult)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(generation, forKey: .generation)
        try c.encodeIfPresent(toolCall, forKey: .toolCall)
        try c.encodeIfPresent(toolResult, forKey: .toolResult)
        switch kind {
        case let .reasoning(value):
            try c.encode("reasoning", forKey: .type)
            try c.encode(value, forKey: .reasoning)
        case let .text(value):
            try c.encode("text", forKey: .type)
            try c.encode(value, forKey: .text)
        case let .contextCompaction(value):
            try c.encode("contextCompaction", forKey: .type)
            try c.encode(value, forKey: .contextCompaction)
        case let .execute(value):
            try c.encode("action", forKey: .type)
            var action = c.nestedContainer(keyedBy: ActionCodingKeys.self, forKey: .action)
            try action.encode("execute", forKey: .type)
            try action.encode(value, forKey: .execute)
        case let .confirm(value):
            try c.encode("action", forKey: .type)
            var action = c.nestedContainer(keyedBy: ActionCodingKeys.self, forKey: .action)
            try action.encode("confirm", forKey: .type)
            try action.encode(value, forKey: .confirm)
        case let .choice(value):
            try c.encode("action", forKey: .type)
            var action = c.nestedContainer(keyedBy: ActionCodingKeys.self, forKey: .action)
            try action.encode("choice", forKey: .type)
            try action.encode(value, forKey: .choice)
        case .wire:
            try c.encode("wire", forKey: .type)
        }
    }
}

nonisolated extension ExecutionEffect: Codable {
    private enum CodingKeys: String, CodingKey { case type, invocation, progress, serviceControl, serviceInspector, shoveler, video, artifact, skill, media }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "invocation": self = .invocation(try c.decode(Invocation.self, forKey: .invocation))
        case "progress": self = .progress(try c.decode(String.self, forKey: .progress))
        case "serviceControl": self = .serviceControl(try c.decode(ServiceControl.self, forKey: .serviceControl))
        case "serviceInspector": self = .serviceInspector(try c.decode(ServiceInspectorLink.self, forKey: .serviceInspector))
        case "shoveler": self = .shoveler(try c.decode(Shoveler.self, forKey: .shoveler))
        case "video": self = .video(try c.decode(VideoWidget.self, forKey: .video))
        case "artifact": self = .artifact(try c.decode(Artifact.self, forKey: .artifact))
        case "skill": self = .skill(try c.decode(Skill.self, forKey: .skill))
        case "media": self = .media(try c.decode(Artifact.self, forKey: .media))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown execution effect type '\(other)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .invocation(v): try c.encode("invocation", forKey: .type); try c.encode(v, forKey: .invocation)
        case let .progress(v): try c.encode("progress", forKey: .type); try c.encode(v, forKey: .progress)
        case let .serviceControl(v): try c.encode("serviceControl", forKey: .type); try c.encode(v, forKey: .serviceControl)
        case let .serviceInspector(v): try c.encode("serviceInspector", forKey: .type); try c.encode(v, forKey: .serviceInspector)
        case let .shoveler(v): try c.encode("shoveler", forKey: .type); try c.encode(v, forKey: .shoveler)
        case let .video(v): try c.encode("video", forKey: .type); try c.encode(v, forKey: .video)
        case let .artifact(v): try c.encode("artifact", forKey: .type); try c.encode(v, forKey: .artifact)
        case let .skill(v): try c.encode("skill", forKey: .type); try c.encode(v, forKey: .skill)
        case let .media(v): try c.encode("media", forKey: .type); try c.encode(v, forKey: .media)
        }
    }
}
