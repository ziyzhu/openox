import Foundation

nonisolated public struct VirtualFileSystem: Sendable {
    static let maximumReadBytes = ArtifactLimits.textBytes
    static let maximumSearchBytes = 2 * 1024 * 1024
    static let maximumChatSearchBytes = 16 * 1024 * 1024
    static let maximumSearchFiles = 1_000
    static let maximumLineCharacters = 500

    enum Location: Equatable, Sendable {
        case root
        case memory
        case soul
        case artifacts
        case artifact(String)
        case guidance(String)
        case skills
        case skill(String)
        case skillFile(String)
        case skillDirectory(String, String)
        case skillResource(String, String)
        case services
        case serviceKind(ServicesMount.Kind)
        case service(ServicesMount.Kind, String)
        case serviceItem(ServicesMount.Kind, String, [String])
        case chats
        case chat(ChatID)
        case chatMetadata(ChatID)
        case chatTurns(ChatID)
        case files
        case deviceFolder(String)
        case deviceItem(String, [String])

        var path: String {
            switch self {
            case .root: "."
            case .memory: "MEMORY.md"
            case .soul: "SOUL.md"
            case .artifacts: "artifacts"
            case .artifact(let name): "artifacts/\(name)"
            case .guidance(let path): path.isEmpty ? "guidance" : "guidance/\(path)"
            case .skills: "skills"
            case .skill(let name): "skills/\(name)"
            case .skillFile(let name): "skills/\(name)/SKILL.md"
            case .skillDirectory(let name, let path): "skills/\(name)/\(path)"
            case .skillResource(let name, let path): "skills/\(name)/\(path)"
            case .services: "services"
            case .serviceKind(let kind): "services/\(kind.rawValue)"
            case .service(let kind, let domain): "services/\(kind.rawValue)/\(domain)"
            case .serviceItem(let kind, let domain, let components):
                "services/\(kind.rawValue)/\(domain)/\(components.joined(separator: "/"))"
            case .chats: "conversations"
            case .chat(let id): "conversations/\(id)"
            case .chatMetadata(let id): "conversations/\(id)/conversation.json"
            case .chatTurns(let id): "conversations/\(id)/turns.jsonl"
            case .files: "files"
            case .deviceFolder(let id): "files/\(id)"
            case .deviceItem(let id, let components): "files/\(id)/\(components.joined(separator: "/"))"
            }
        }

        var isDirectory: Bool {
            switch self {
            case .root, .artifacts, .skills, .skill, .skillDirectory, .services, .serviceKind, .service, .chats, .chat, .files, .deviceFolder: true
            case .guidance, .memory, .soul, .artifact, .skillFile, .skillResource, .serviceItem, .chatMetadata, .chatTurns, .deviceItem: false
            }
        }

        var area: Area {
            switch self {
            case .memory: .memory
            case .soul: .soul
            case .artifacts, .artifact: .artifacts
            case .guidance: .guidance
            case .skills, .skill, .skillFile, .skillDirectory, .skillResource: .skills
            case .services, .serviceKind, .service, .serviceItem: .services
            case .chats, .chat, .chatMetadata, .chatTurns: .chats
            case .files: .files
            case .deviceFolder(let id), .deviceItem(let id, _): .deviceFolder(id)
            case .root: .root
            }
        }

    }

    enum Area: Equatable, Sendable {
        case root
        case memory
        case soul
        case artifacts
        case guidance
        case skills
        case services
        case chats
        case files
        case deviceFolder(String)
    }

    enum Error: LocalizedError, Sendable {
        case invalidPath(String)
        case notDirectory(String)
        case notFile(String)
        case unsupportedMutation(String)
        case invalidPattern(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath(let path): "Invalid Profile file path: \(path)"
            case .notDirectory(let path): "Not a directory: \(path)"
            case .notFile(let path): "Not a file: \(path)"
            case .unsupportedMutation(let path): "This operation isn't supported for \(path)."
            case .invalidPattern(let pattern): "Invalid search pattern: \(pattern)"
            }
        }
    }

    func location(_ rawPath: String, defaultRoot: Bool = false) throws -> Location {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if defaultRoot, path.isEmpty || path == "." { return .root }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\") else { throw Error.invalidPath(rawPath) }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "chats" {
            parts[0] = "conversations"
            if parts.count == 3, parts[2] == "chat.json" { parts[2] = "conversation.json" }
        }
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Error.invalidPath(rawPath)
        }
        switch parts {
        case ["MEMORY.md"]: return .memory
        case ["SOUL.md"]: return .soul
        case ["artifacts"]: return .artifacts
        case let parts where parts.count == 2 && parts[0] == "artifacts":
            let name = parts[1]
            _ = try ArtifactStore.validatedFilename(name)
            return .artifact(name)
        case ["guidance"]: return .guidance("")
        case let parts where parts.count >= 2 && parts[0] == "guidance":
            let relative = parts.dropFirst().joined(separator: "/")
            guard BuiltInGuidance.validPath(relative) else { throw Error.invalidPath(rawPath) }
            return .guidance(relative)
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
        case ["services"]: return .services
        case let parts where parts.count == 2 && parts[0] == "services":
            guard let kind = ServicesMount.Kind(rawValue: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .serviceKind(kind)
        case let parts where parts.count == 3 && parts[0] == "services":
            guard let kind = ServicesMount.Kind(rawValue: parts[1]), ServicesMount.isID(parts[2]) else { throw Error.invalidPath(rawPath) }
            return .service(kind, parts[2])
        case let parts where parts.count >= 4 && parts[0] == "services":
            guard let kind = ServicesMount.Kind(rawValue: parts[1]),
                  ServicesMount.isID(parts[2]),
                  parts.dropFirst(3).allSatisfy({ !$0.hasPrefix(".") }) else {
                throw Error.invalidPath(rawPath)
            }
            return .serviceItem(kind, parts[2], Array(parts.dropFirst(3)))
        case ["conversations"]: return .chats
        case let parts where parts.count == 2 && parts[0] == "conversations":
            guard let id = UUID(uuidString: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .chat(ChatID(id))
        case let parts where parts.count == 3 && parts[0] == "conversations" && parts[2] == "conversation.json":
            guard let id = UUID(uuidString: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .chatMetadata(ChatID(id))
        case let parts where parts.count == 3 && parts[0] == "conversations" && parts[2] == "turns.jsonl":
            guard let id = UUID(uuidString: parts[1]) else { throw Error.invalidPath(rawPath) }
            return .chatTurns(ChatID(id))
        case ["files"]: return .files
        case let parts where parts.count == 2 && parts[0] == "files":
            return .deviceFolder(parts[1])
        case let parts where parts.count > 2 && parts[0] == "files":
            return .deviceItem(parts[1], Array(parts.dropFirst(2)))
        default: throw Error.invalidPath(rawPath)
        }
    }

    func relativePath(_ path: String, under base: Location) -> String? {
        switch base {
        case .root:
            return path
        default:
            let prefix = base.path + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }
    }

    func matches(path: String, pattern: String) throws -> Bool {
        let expression = try globExpression(pattern)
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return expression.firstMatch(in: path, range: range) != nil
    }

    private func globExpression(_ pattern: String) throws -> NSRegularExpression {
        guard !pattern.isEmpty else { throw Error.invalidPattern(pattern) }
        var source = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            let next = pattern.index(after: index)
            if character == "*", next < pattern.endIndex, pattern[next] == "*" {
                let afterDouble = pattern.index(after: next)
                if afterDouble < pattern.endIndex, pattern[afterDouble] == "/" {
                    source += "(?:.*/)?"
                    index = pattern.index(after: afterDouble)
                } else {
                    source += ".*"
                    index = afterDouble
                }
            } else {
                switch character {
                case "*": source += "[^/]*"
                case "?": source += "[^/]"
                default: source += NSRegularExpression.escapedPattern(for: String(character))
                }
                index = next
            }
        }
        source += "$"
        do {
            return try NSRegularExpression(pattern: source)
        } catch {
            throw Error.invalidPattern(pattern)
        }
    }
}
