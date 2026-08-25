import Foundation

nonisolated struct ChatID: Hashable, Codable, Sendable, CustomStringConvertible {
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

nonisolated enum ChatSubmissionOutcome: Equatable, Sendable {
    case completed(String)
    case failed(String)
    case cancelled

    var logLabel: String {
        switch self {
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }
}

nonisolated extension ChatID {
    static func == (lhs: ChatID, rhs: UUID) -> Bool { lhs.rawValue == rhs }
    static func == (lhs: UUID, rhs: ChatID) -> Bool { lhs == rhs.rawValue }
}

nonisolated struct ChatState: Equatable, Sendable {
    let meta: ChatMeta
    let turns: [Turn]
    let context: AgentContextCheckpoint?

    init(meta: ChatMeta, turns: [Turn], context: AgentContextCheckpoint? = nil) {
        self.meta = meta
        self.turns = turns
        self.context = context
    }

    var chatID: ChatID { ChatID(meta.id) }
}

nonisolated struct ChatLoadResult: Sendable {
    let state: ChatState
    let needsPersistence: Bool

    func replacingMeta(_ meta: ChatMeta) -> Self {
        Self(
            state: ChatState(meta: meta, turns: state.turns, context: state.context),
            needsPersistence: needsPersistence
        )
    }
}

nonisolated struct ChatSaveRequest: Sendable {
    enum Payload: Sendable {
        case metadata(ChatMeta)
        case chat(ChatState)
    }

    let saveID: SaveID
    let payload: Payload

    init(saveID: SaveID = SaveID(), payload: Payload) {
        self.saveID = saveID
        self.payload = payload
    }

    var chatID: ChatID {
        switch payload {
        case .metadata(let meta): ChatID(meta.id)
        case .chat(let state): state.chatID
        }
    }
}

nonisolated struct ChatSaveReceipt: Sendable {
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
