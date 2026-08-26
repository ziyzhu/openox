import Foundation

nonisolated public struct TextContent: Codable, Equatable, Sendable {
    public var text: String
    public var textSignature: String?
    public var thoughtSignature: String?
    public init(_ text: String, textSignature: String? = nil, thoughtSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
        self.thoughtSignature = thoughtSignature
    }
}

nonisolated public struct ThinkingContent: Codable, Equatable, Sendable {
    public var thinking: String
    public var thinkingSignature: String?
    public var thoughtSignature: String?
    public init(_ thinking: String, thinkingSignature: String? = nil, thoughtSignature: String? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.thoughtSignature = thoughtSignature
    }
}

nonisolated public struct TransientAttachment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case image
        case pdf
        case text
        case file
    }

    public let kind: Kind
    public let mimeType: String
    public let displayName: String
    public let data: Data

    public init(kind: Kind, mimeType: String, displayName: String, data: Data) {
        self.kind = kind
        self.mimeType = mimeType
        self.displayName = displayName
        self.data = data
    }
}

nonisolated public enum ContentBlock: Equatable, Sendable, Codable {
    case text(TextContent)
    case attachment(Artifact)
    case thinking(ThinkingContent)
    case toolCall(ToolCall)

    private enum CodingKeys: String, CodingKey { case type, text, attachment, thinking, toolCall }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(TextContent.self, forKey: .text))
        case "attachment": self = .attachment(try c.decode(Artifact.self, forKey: .attachment))
        case "thinking":
            if let value = try? c.decode(ThinkingContent.self, forKey: .thinking) {
                self = .thinking(value)
            } else {
                self = .thinking(ThinkingContent(try c.decode(String.self, forKey: .thinking)))
            }
        case "toolCall": self = .toolCall(try c.decode(ToolCall.self, forKey: .toolCall))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown ContentBlock type '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let v): try c.encode("text", forKey: .type); try c.encode(v, forKey: .text)
        case .attachment(let v): try c.encode("attachment", forKey: .type); try c.encode(v, forKey: .attachment)
        case .thinking(let v): try c.encode("thinking", forKey: .type); try c.encode(v, forKey: .thinking)
        case .toolCall(let v): try c.encode("toolCall", forKey: .type); try c.encode(v, forKey: .toolCall)
        }
    }
}

nonisolated public struct ToolCall: Equatable, Sendable, Codable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public var thoughtSignature: String?
    public var providerItemID: String?
    public var providerCallID: String?
    public init(
        id: String,
        name: String,
        arguments: JSONValue,
        thoughtSignature: String? = nil,
        providerItemID: String? = nil,
        providerCallID: String? = nil
    ) {
        self.id = id; self.name = name; self.arguments = arguments
        self.thoughtSignature = thoughtSignature
        self.providerItemID = providerItemID
        self.providerCallID = providerCallID
    }
}

nonisolated public struct Usage: Equatable, Sendable, Codable {
    public var input: Int = 0
    public var output: Int = 0
    public var cachedInput: Int = 0
    public var cacheWriteInput: Int?
    public var totalTokens: Int = 0
    public init() {}
}

nonisolated public enum StopReason: String, Sendable, Codable {
    case pending, stop, length, toolUse, error, aborted
}

nonisolated public struct UserMessage: Sendable, Codable {
    public var content: [ContentBlock]
    public var timestamp: Date
    public var transientContext: String?
    public init(
        text: String,
        attachments: [Artifact] = [],
        transientContext: String? = nil,
        timestamp: Date = Date()
    ) {
        var blocks: [ContentBlock] = [.text(TextContent(text))]
        blocks.append(contentsOf: attachments.map { .attachment($0) })
        self.content = blocks
        self.transientContext = transientContext
        self.timestamp = timestamp
    }
    public init(content: [ContentBlock], transientContext: String? = nil, timestamp: Date = Date()) {
        self.content = content
        self.transientContext = transientContext
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case content, timestamp
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        content = try values.decode([ContentBlock].self, forKey: .content)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        transientContext = nil
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(content, forKey: .content)
        try values.encode(timestamp, forKey: .timestamp)
    }
}

nonisolated public struct AssistantMessage: Sendable, Codable, Equatable {
    public var content: [ContentBlock]
    public var model: String
    public var usage: Usage = Usage()
    public var stopReason: StopReason = .pending
    public var errorMessage: String? = nil
    public var failureKind: LLMFailureKind? = nil
    public var responseID: String? = nil
    public var rawStopReason: String? = nil
    public var timestamp: Date = Date()
    public init(model: String, content: [ContentBlock] = []) {
        self.model = model; self.content = content
    }
}

nonisolated public struct ToolResultDiagnostics: Sendable, Codable, Equatable {
    public var structuredContent: JSONValue

    public init(structuredContent: JSONValue) {
        self.structuredContent = structuredContent
    }
}

nonisolated public struct ActivatedSkillContext: Sendable, Codable, Equatable {
    public var name: String
    public var path: String
    public var content: String

    public init(name: String, path: String, content: String) {
        self.name = name
        self.path = path
        self.content = content
    }
}

nonisolated public struct ToolResultMessage: Sendable, Codable, Equatable {
    public var toolCallId: String
    public var providerCallID: String?
    public var toolName: String
    public var content: [ContentBlock]
    public var diagnostics: ToolResultDiagnostics?
    public var isError: Bool
    public var truncated: Bool?
    public var timestamp: Date
    public var transientAttachments: [TransientAttachment]
    public var activatedSkills: [ActivatedSkillContext]
    public init(
        toolCallId: String,
        providerCallID: String? = nil,
        toolName: String,
        content: [ContentBlock],
        diagnostics: ToolResultDiagnostics? = nil,
        isError: Bool,
        truncated: Bool = false,
        timestamp: Date = Date(),
        transientAttachments: [TransientAttachment] = [],
        activatedSkills: [ActivatedSkillContext] = []
    ) {
        self.toolCallId = toolCallId
        self.providerCallID = providerCallID
        self.toolName = toolName
        self.content = content
        self.diagnostics = diagnostics
        self.isError = isError
        self.truncated = truncated ? true : nil
        self.timestamp = timestamp
        self.transientAttachments = transientAttachments
        self.activatedSkills = activatedSkills
    }

    private enum CodingKeys: String, CodingKey {
        case toolCallId, providerCallID, toolName, content, diagnostics, isError, truncated, timestamp, activatedSkills
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try values.decode(String.self, forKey: .toolCallId)
        providerCallID = try values.decodeIfPresent(String.self, forKey: .providerCallID)
        toolName = try values.decode(String.self, forKey: .toolName)
        content = try values.decode([ContentBlock].self, forKey: .content)
        diagnostics = try values.decodeIfPresent(ToolResultDiagnostics.self, forKey: .diagnostics)
        isError = try values.decode(Bool.self, forKey: .isError)
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        transientAttachments = []
        activatedSkills = try values.decodeIfPresent([ActivatedSkillContext].self, forKey: .activatedSkills) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(toolCallId, forKey: .toolCallId)
        try values.encodeIfPresent(providerCallID, forKey: .providerCallID)
        try values.encode(toolName, forKey: .toolName)
        try values.encode(content, forKey: .content)
        try values.encodeIfPresent(diagnostics, forKey: .diagnostics)
        try values.encode(isError, forKey: .isError)
        try values.encodeIfPresent(truncated, forKey: .truncated)
        try values.encode(timestamp, forKey: .timestamp)
        if !activatedSkills.isEmpty {
            try values.encode(activatedSkills, forKey: .activatedSkills)
        }
    }
}

nonisolated public enum Message: Sendable, Codable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    private enum CodingKeys: String, CodingKey { case type, user, assistant, toolResult }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "user": self = .user(try c.decode(UserMessage.self, forKey: .user))
        case "assistant": self = .assistant(try c.decode(AssistantMessage.self, forKey: .assistant))
        case "toolResult": self = .toolResult(try c.decode(ToolResultMessage.self, forKey: .toolResult))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Message type '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let v): try c.encode("user", forKey: .type); try c.encode(v, forKey: .user)
        case .assistant(let v): try c.encode("assistant", forKey: .type); try c.encode(v, forKey: .assistant)
        case .toolResult(let v): try c.encode("toolResult", forKey: .type); try c.encode(v, forKey: .toolResult)
        }
    }
}
