import Foundation

nonisolated struct Block: Identifiable, Equatable, Codable {
    let id: UUID
    let createdAt: Date
    var kind: Kind

    enum Kind: Equatable, Codable {
        case userText(String, attachments: [Artifact] = [])

        case userSkill(UserSkillInvocation, attachments: [Artifact] = [])

        case agentContent([ContentItem])

        case prompt(kind: ChatPromptKind, prompt: String, options: [String], answer: String?, resolution: String?)

        case thinking(ThinkingTrace)

        case contextCompaction(ContextCompaction)
    }

    init(_ kind: Kind, id: UUID = UUID()) {
        self.id = id
        self.createdAt = Date()
        self.kind = kind
    }

    init(id: UUID, createdAt: Date, kind: Kind) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
    }

    var isUserInitiated: Bool {
        switch kind {
        case .userText, .userSkill: return true
        default: return false
        }
    }
}

nonisolated enum ChatPromptKind: String, Equatable, Codable {
    case permission
    case choice
}

nonisolated enum ContentItem: Equatable, Codable {
    case text(String)
    case progress(String)
    case serviceControl(ServiceControl)
    case serviceInspector(ServiceInspectorLink)
    case shoveler(Shoveler)
    case video(VideoWidget)
    case artifact(Artifact)
    case skill(Skill)

    private enum CodingKeys: String, CodingKey { case text, progress, serviceControl, serviceInspector, shoveler, video, artifact, skill }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try c.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let progress = try c.decodeIfPresent(String.self, forKey: .progress) {
            self = .progress(progress)
        } else if c.contains(.skill) {
            self = .skill(try c.decode(Skill.self, forKey: .skill))
        } else if c.contains(.artifact) {
            self = .artifact(try c.decode(Artifact.self, forKey: .artifact))
        } else if c.contains(.shoveler) {
            self = .shoveler(try c.decode(Shoveler.self, forKey: .shoveler))
        } else if c.contains(.video) {
            self = .video(try c.decode(VideoWidget.self, forKey: .video))
        } else if c.contains(.serviceControl) {
            self = .serviceControl(try c.decode(ServiceControl.self, forKey: .serviceControl))
        } else if c.contains(.serviceInspector) {
            self = .serviceInspector(try c.decode(ServiceInspectorLink.self, forKey: .serviceInspector))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: c,
                debugDescription: "Content item must contain text, progress, shoveler, video, artifact, skill, or service control"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text): try c.encode(text, forKey: .text)
        case let .progress(progress): try c.encode(progress, forKey: .progress)
        case let .serviceControl(control): try c.encode(control, forKey: .serviceControl)
        case let .serviceInspector(link): try c.encode(link, forKey: .serviceInspector)
        case let .shoveler(shoveler): try c.encode(shoveler, forKey: .shoveler)
        case let .video(video): try c.encode(video, forKey: .video)
        case let .artifact(artifact): try c.encode(artifact, forKey: .artifact)
        case let .skill(skill): try c.encode(skill, forKey: .skill)
        }
    }
}

nonisolated struct ThinkingTrace: Equatable, Codable {
    var entries: [TraceEntry]
    var completedAt: Date?

    var invocations: [Invocation] { entries.compactMap { if case let .invocation(value) = $0 { value } else { nil } } }
    var isEmpty: Bool { entries.isEmpty }
}

nonisolated struct Reasoning: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { plain($0.joined(separator: " ")) }
            .filter { !$0.isEmpty }
    }

    private static func plain(_ source: String) -> String {
        let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let text = attributed.map { String($0.characters) } ?? source
        return text
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum TraceEntry: Identifiable, Equatable, Codable {
    case reasoning(Reasoning)
    case invocation(Invocation)

    var id: UUID {
        switch self {
        case let .reasoning(r): r.id
        case let .invocation(value): value.id
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, reasoning, invocation }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "reasoning": self = .reasoning(try c.decode(Reasoning.self, forKey: .reasoning))
        case "invocation": self = .invocation(try c.decode(Invocation.self, forKey: .invocation))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown trace entry kind '\(other)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .reasoning(r):
            try c.encode("reasoning", forKey: .kind)
            try c.encode(r, forKey: .reasoning)
        case let .invocation(value):
            try c.encode("invocation", forKey: .kind)
            try c.encode(value, forKey: .invocation)
        }
    }
}

nonisolated struct Invocation: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID
    let name: String
    let purpose: String
    let args: JSONValue
    var outcome: Outcome

    nonisolated enum Outcome: Equatable, Codable, Sendable {
        case running
        case succeeded(JSONValue?)
        case failed(String)
    }

    init(id: UUID = UUID(), name: String, purpose: String, args: JSONValue, outcome: Outcome = .running) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.args = args
        self.outcome = outcome
    }

    var isFailed: Bool { if case .failed = outcome { return true }; return false }
    var isRunning: Bool { if case .running = outcome { return true }; return false }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

nonisolated extension Block.Kind {
    private enum CodingKeys: String, CodingKey {
        case type, text, attachments, skillInvocation, promptKind, prompt, options, answer, resolution, items, trace, contextCompaction
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "userText":
            self = .userText(
                try c.decode(String.self, forKey: .text),
                attachments: try c.decode([Artifact].self, forKey: .attachments)
            )
        case "userSkill":
            self = .userSkill(
                try c.decode(UserSkillInvocation.self, forKey: .skillInvocation),
                attachments: try c.decode([Artifact].self, forKey: .attachments)
            )
        case "agentContent":
            self = .agentContent(try c.decode([ContentItem].self, forKey: .items))
        case "confirm":
            self = .prompt(
                kind: try c.decodeIfPresent(ChatPromptKind.self, forKey: .promptKind) ?? .choice,
                prompt: try c.decode(String.self, forKey: .prompt),
                options: try c.decode([String].self, forKey: .options),
                answer: try c.decodeIfPresent(String.self, forKey: .answer),
                resolution: try c.decodeIfPresent(String.self, forKey: .resolution)
            )
        case "thinking":
            self = .thinking(try c.decode(ThinkingTrace.self, forKey: .trace))
        case "contextCompaction":
            self = .contextCompaction(try c.decode(ContextCompaction.self, forKey: .contextCompaction))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown Block.Kind type '\(other)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .userText(text, attachments):
            try c.encode("userText", forKey: .type)
            try c.encode(text, forKey: .text)
            try c.encode(attachments, forKey: .attachments)
        case let .userSkill(invocation, attachments):
            try c.encode("userSkill", forKey: .type)
            try c.encode(invocation, forKey: .skillInvocation)
            try c.encode(attachments, forKey: .attachments)
        case let .agentContent(items):
            try c.encode("agentContent", forKey: .type)
            try c.encode(items, forKey: .items)
        case let .prompt(kind, prompt, options, answer, resolution):
            try c.encode("confirm", forKey: .type)
            try c.encode(kind, forKey: .promptKind)
            try c.encode(prompt, forKey: .prompt)
            try c.encode(options, forKey: .options)
            try c.encodeIfPresent(answer, forKey: .answer)
            try c.encodeIfPresent(resolution, forKey: .resolution)
        case let .thinking(trace):
            try c.encode("thinking", forKey: .type)
            try c.encode(trace, forKey: .trace)
        case let .contextCompaction(value):
            try c.encode("contextCompaction", forKey: .type)
            try c.encode(value, forKey: .contextCompaction)
        }
    }
}
