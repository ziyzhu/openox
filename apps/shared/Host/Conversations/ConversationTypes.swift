import Foundation

nonisolated struct ConversationID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var description: String { rawValue.uuidString }
}

nonisolated struct HydrationGeneration: Hashable, Sendable {
    let rawValue: UInt64
}

nonisolated struct SaveID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    var description: String { rawValue.uuidString }
}

nonisolated struct SubmissionID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(rawValue)
    }
}

nonisolated struct TurnID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(rawValue)
    }
}

nonisolated struct StepID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(rawValue)
    }
}

nonisolated struct AgentGenerationID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.singleValueContainer()
        try values.encode(rawValue)
    }
}

nonisolated struct RenderBlockID: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

nonisolated struct RunID: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum ConversationSubmissionOutcome: Equatable, Sendable {
    case completed(String)
    case failed(String)
    case cancelled
    case needsAttention

    var logLabel: String {
        switch self {
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .needsAttention: "needsAttention"
        }
    }
}

nonisolated extension ConversationID {
    static func == (lhs: ConversationID, rhs: UUID) -> Bool { lhs.rawValue == rhs }
    static func == (lhs: UUID, rhs: ConversationID) -> Bool { lhs == rhs.rawValue }
}

nonisolated struct ConversationState: Equatable, Sendable {
    let meta: ConversationMeta
    let turns: [Turn]
    let context: AgentContextCheckpoint?

    init(meta: ConversationMeta, turns: [Turn], context: AgentContextCheckpoint? = nil) {
        self.meta = meta
        self.turns = turns
        self.context = context
    }

    var conversationID: ConversationID { ConversationID(meta.id) }
}

nonisolated struct ConversationLoadResult: Sendable {
    let state: ConversationState
    let needsPersistence: Bool
    let document: ConversationDocument?

    init(state: ConversationState, needsPersistence: Bool, document: ConversationDocument? = nil) {
        self.state = state
        self.needsPersistence = needsPersistence
        self.document = document
    }

    @concurrent
    func preparingDocument() async -> Self {
        Self(state: state, needsPersistence: needsPersistence,
             document: document ?? ConversationDocument.restoring(state.turns))
    }

    func replacingMeta(_ meta: ConversationMeta) -> Self {
        Self(
            state: ConversationState(meta: meta, turns: state.turns, context: state.context),
            needsPersistence: needsPersistence,
            document: document
        )
    }
}

nonisolated struct ConversationSaveRequest: Sendable {
    enum Payload: Sendable {
        case metadata(ConversationMeta)
        case conversation(ConversationState)
    }

    let saveID: SaveID
    let payload: Payload

    init(saveID: SaveID = SaveID(), payload: Payload) {
        self.saveID = saveID
        self.payload = payload
    }

    var conversationID: ConversationID {
        switch payload {
        case .metadata(let meta): ConversationID(meta.id)
        case .conversation(let state): state.conversationID
        }
    }
}

nonisolated struct ConversationSaveReceipt: Sendable {
    let saveID: SaveID
    let succeeded: Bool
}

enum RuntimeError: LocalizedError {
    case bridge(String)

    var errorDescription: String? {
        switch self {
        case .bridge(let message): return message
        }
    }
}

enum ConversationRetention: Equatable {
    case persisted
    case temporary
}

nonisolated struct FollowIntent: Equatable, Identifiable, Sendable {
    let label: String
    let message: String

    static func parse(_ value: JSONValue) throws -> [Self] {
        guard let entries = value.arrayValue, entries.count <= 2 else {
            throw RuntimeError.bridge("ox.user.follow: provide at most 2 intents")
        }
        let intents = try entries.map { entry -> Self in
            guard let fields = entry.objectValue,
                  let kind = fields["kind"]?.stringValue else {
                throw RuntimeError.bridge("ox.user.follow: each intent needs a kind")
            }
            switch kind {
            case "send":
                let label = fields["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let message = fields["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !label.isEmpty, label.count <= 80,
                      !message.isEmpty, message.count <= 1_000 else {
                    throw RuntimeError.bridge("ox.user.follow: send needs a short label and message")
                }
                return Self(label: label, message: message)
            default: throw RuntimeError.bridge("ox.user.follow: unsupported intent kind")
            }
        }
        guard Set(intents.map(\.id)).count == intents.count else {
            throw RuntimeError.bridge("ox.user.follow: intents must be unique")
        }
        return intents
    }

    var id: String { "send:\(label.lowercased())" }
}

struct ConversationContinuation {
    let meta: ConversationMeta
    let turns: [Turn]
    let intent: String
    let attachments: [FileItem]
    let skillInvocation: UserSkillInvocation?
}

nonisolated enum ConversationPromptPresentation: Equatable, Sendable {
    case conversation
    case application
}

nonisolated struct ConversationPendingPrompt: Equatable, Sendable {
    let id: UUID
    let prompt: String
    let options: [String]
    let presentation: ConversationPromptPresentation
}

extension Conversation {
    enum ExecutionLease {
        case userInitiated
        case externallyManaged
    }

    struct PendingServiceControl: Identifiable, Equatable {
        struct Source: Equatable {
            let blockID: UUID
            let itemIndex: Int
        }

        let id: UUID
        let control: ServiceControl
        var source: Source?
        var accessPreflight: UUID? = nil
    }

    struct PendingPrompt: Identifiable, Equatable {
        struct AutoApproval: Equatable {
            let action: String
            let defaultPolicy: ActionPolicy
            let approve: String
            let alwaysApprove: String
            let deny: String
        }

        let id: UUID
        let kind: ConversationPromptKind
        let prompt: String
        let options: [String]
        let presentation: ConversationPromptPresentation
        let allowsCustomAnswer: Bool
        let autoApproval: AutoApproval?
        let secretEntry: SecretEntryRequest?
        let permission: PermissionPresentation?
    }

    enum Interaction: Equatable {
        case prompt(PendingPrompt)
        case serviceControl(PendingServiceControl)
    }

    enum Activity: Equatable {
        enum Idle: Equatable {
            case read
            case unread
            case stopped
        }

        enum AwaitingAction: Equatable {
            case approval
            case reply
            case signIn
            case verification
            case payment
        }

        enum Running: Equatable {
            case thinking
            case streaming
            case awaiting(AwaitingAction)
        }

        case idle(Idle)
        case running(Running)

        var isThinking: Bool {
            self == .running(.thinking)
        }

        var isAwaitingUser: Bool {
            if case .running(.awaiting) = self { true } else { false }
        }
    }

    enum Notice: Equatable {
        case none
        case error(String)

        var errorMessage: String? {
            if case .error(let message) = self { message } else { nil }
        }
    }

    struct ThinkingActivity: Equatable {
        let turnID: TurnID
        let startedAt: Date
    }

    struct QueuedMessage: Identifiable {
        let id: UUID
        let text: String
        let attachments: [FileItem]
        let skillInvocation: UserSkillInvocation?
    }

    struct SubmissionReceipt: Equatable {
        enum Disposition: String {
            case posted
            case queued
        }

        let id: UUID
        let disposition: Disposition
    }

    enum SubmissionAnchor: Equatable {
        case queued(UUID)
        case turn(blockID: UUID, submissionID: UUID?)

        var id: UUID {
            switch self {
            case .queued(let id): id
            case .turn(let blockID, _): blockID
            }
        }
    }
}
