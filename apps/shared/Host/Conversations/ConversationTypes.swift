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
