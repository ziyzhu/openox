import Foundation

nonisolated public struct VirtualFileSystem: Sendable {
    static let hostRoots = ["MEMORY.md", "artifacts", "skills", "repositories", "conversations", "tmp"]
    static let maximumReadBytes = FileLimits.textBytes
    static let maximumSearchFiles = 1_000

    enum Location: Equatable, Sendable {
        case root
        case memory
        case artifacts
        case artifact(String)
        case resource(String)
        case skills
        case skill(String)
        case skillFile(String)
        case skillDirectory(String, String)
        case skillResource(String, String)
        case repositories
        case repository(String)
        case repositoryItem(String, [String])
        case conversations
        case conversation(ConversationID)
        case conversationMetadata(ConversationID)
        case conversationTurns(ConversationID)
        case files
        case deviceFolder(String)
        case deviceItem(String, [String])

        var path: String {
            switch self {
            case .root: "."
            case .memory: "MEMORY.md"
            case .artifacts: "artifacts"
            case .artifact(let name): "artifacts/\(name)"
            case .resource(let path): path
            case .skills: "skills"
            case .skill(let name): "skills/\(name)"
            case .skillFile(let name): "skills/\(name)/SKILL.md"
            case .skillDirectory(let name, let path): "skills/\(name)/\(path)"
            case .skillResource(let name, let path): "skills/\(name)/\(path)"
            case .repositories: "repositories"
            case .repository(let id): "repositories/\(id)"
            case .repositoryItem(let id, let components):
                "repositories/\(id)/\(components.joined(separator: "/"))"
            case .conversations: "conversations"
            case .conversation(let id): "conversations/\(id)"
            case .conversationMetadata(let id): "conversations/\(id)/conversation.json"
            case .conversationTurns(let id): "conversations/\(id)/turns.jsonl"
            case .files: "mounts"
            case .deviceFolder(let id): "mounts/\(id)"
            case .deviceItem(let id, let components): "mounts/\(id)/\(components.joined(separator: "/"))"
            }
        }

        var isDirectory: Bool {
            switch self {
            case .root, .artifacts, .skills, .skill, .skillDirectory, .repositories, .repository, .conversations, .conversation, .files, .deviceFolder: true
            case .resource, .memory, .artifact, .skillFile, .skillResource, .repositoryItem, .conversationMetadata, .conversationTurns, .deviceItem: false
            }
        }

        var area: Area {
            switch self {
            case .memory: .memory
            case .artifacts, .artifact: .artifacts
            case .resource: .resources
            case .skills, .skill, .skillFile, .skillDirectory, .skillResource: .skills
            case .repositories, .repository, .repositoryItem: .repositories
            case .conversations, .conversation, .conversationMetadata, .conversationTurns: .conversations
            case .files: .files
            case .deviceFolder(let id), .deviceItem(let id, _): .deviceFolder(id)
            case .root: .root
            }
        }

    }

    enum Area: Equatable, Sendable {
        case root
        case memory
        case artifacts
        case resources
        case skills
        case repositories
        case conversations
        case files
        case deviceFolder(String)
    }

    enum Error: LocalizedError, Sendable {
        case invalidPath(String)
        case notDirectory(String)
        case notFile(String)
        case unsupportedMutation(String)
        case notEmpty(String)
        case crossFolderTransfer(String)
        case intoSourceTree(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let path): "Invalid Profile file path: \(path)"
            case .notDirectory(let path): "Not a directory: \(path)"
            case .notFile(let path): "Not a file: \(path)"
            case .unsupportedMutation(let path): "This operation isn't supported for \(path)."
            case .notEmpty(let path): "Directory is not empty: \(path)"
            case .crossFolderTransfer(let path): "Moves and copies must stay within one chosen folder: \(path)"
            case .intoSourceTree(let path): "Cannot move or copy into the source tree: \(path)"
            }
        }
    }

    func location(_ rawPath: String, defaultRoot: Bool = false, resources: ReadOnlyFiles) throws -> Location {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if defaultRoot, path.isEmpty || path == "." { return .root }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\") else { throw Error.invalidPath(rawPath) }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let root = parts.first, ["history", "chats"].contains(root) { parts[0] = "conversations" }
        if parts.first == "files" { parts[0] = "mounts" }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Error.invalidPath(rawPath)
        }
        if let legacy = try ProfileMigrator.legacyWorkflowLocation(parts) { return legacy }
        if resources.owns(path) { return .resource(path) }
        switch parts {
        case ["MEMORY.md"]: return .memory
        case ["artifacts"]: return .artifacts
        case let parts where parts.count == 2 && parts[0] == "artifacts":
            let name = parts[1]
            _ = try FileStore.validatedFilename(name)
            return .artifact(name)
        case ["skills"]: return .skills
        case let parts where parts.count == 2 && parts[0] == "skills":
            let name = parts[1]
            guard SkillsMount.isPathName(name) else { throw Error.invalidPath(rawPath) }
            return .skill(name)
        case let parts where parts.count == 3 && parts[0] == "skills" && parts[2] == "SKILL.md":
            let name = parts[1]
            guard SkillsMount.isPathName(name) else { throw Error.invalidPath(rawPath) }
            return .skillFile(name)
        case let parts where parts.count >= 3 && parts[0] == "skills":
            let name = parts[1]
            let path = parts.dropFirst(2).joined(separator: "/")
            guard SkillsMount.isPathName(name) else { throw Error.invalidPath(rawPath) }
            if ["references", "scripts"].contains(path) { return .skillDirectory(name, path) }
            guard SkillFiles.isResourcePath(path) || SkillFiles.isResourcePath(path + "/file.js") else { throw Error.invalidPath(rawPath) }
            return .skillResource(name, path)
        case ["repositories"]: return .repositories
        case let parts where parts.count == 2 && parts[0] == "repositories":
            return .repository(parts[1])
        case let parts where parts.count > 2 && parts[0] == "repositories":
            return .repositoryItem(parts[1], Array(parts.dropFirst(2)))
        case ["conversations"]: return .conversations
        case let parts where parts.count == 2 && parts[0] == "conversations":
            guard let id = UUID(uuidString: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .conversation(ConversationID(id))
        case let parts where parts.count == 3 && parts[0] == "conversations" && parts[2] == "conversation.json":
            guard let id = UUID(uuidString: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .conversationMetadata(ConversationID(id))
        case let parts where parts.count == 3 && parts[0] == "conversations" && parts[2] == "turns.jsonl":
            guard let id = UUID(uuidString: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .conversationTurns(ConversationID(id))
        case ["mounts"]: return .files
        case let parts where parts.count == 2 && parts[0] == "mounts":
            return .deviceFolder(parts[1])
        case let parts where parts.count > 2 && parts[0] == "mounts":
            return .deviceItem(parts[1], Array(parts.dropFirst(2)))
        default: throw Error.invalidPath(rawPath)
        }
    }

}
