import Foundation

nonisolated public enum AgentToolExecutionMode: Sendable {
    case sequential
    case parallel
}

nonisolated public struct ToolResult: Sendable {
    public var content: [ContentBlock]
    public var diagnostics: ToolResultDiagnostics?
    public var isError: Bool
    public var truncated: Bool
    public var terminate: Bool
    public var transientAttachments: [TransientAttachment]
    public var activatedSkills: [ActivatedSkillContext]
    public init(
        text: String,
        diagnosticContent: JSONValue? = nil,
        isError: Bool = false,
        truncated: Bool = false,
        terminate: Bool = false,
        transientAttachments: [TransientAttachment] = [],
        activatedSkills: [ActivatedSkillContext] = []
    ) {
        self.content = [.text(TextContent(text))]
        self.diagnostics = diagnosticContent.map { ToolResultDiagnostics(structuredContent: $0) }
        self.isError = isError
        self.truncated = truncated
        self.terminate = terminate
        self.transientAttachments = transientAttachments
        self.activatedSkills = activatedSkills
    }
    public init(
        content: [ContentBlock],
        diagnosticContent: JSONValue? = nil,
        isError: Bool = false,
        truncated: Bool = false,
        terminate: Bool = false,
        transientAttachments: [TransientAttachment] = [],
        activatedSkills: [ActivatedSkillContext] = []
    ) {
        self.content = content
        self.diagnostics = diagnosticContent.map { ToolResultDiagnostics(structuredContent: $0) }
        self.isError = isError
        self.truncated = truncated
        self.terminate = terminate
        self.transientAttachments = transientAttachments
        self.activatedSkills = activatedSkills
    }
}

nonisolated public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: JSONValue { get }
    var strict: Bool { get }
    var executionMode: AgentToolExecutionMode { get }
    func execute(toolCallId: String, args: JSONValue) async throws -> ToolResult
}

nonisolated public extension AgentTool {
    var strict: Bool { true }
    var executionMode: AgentToolExecutionMode { .sequential }
}
