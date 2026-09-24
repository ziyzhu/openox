import Foundation
import Observation

nonisolated struct Skill: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var description: String
    var instructions: String
    var services: [String] = []
    var id: String { name }
    var displayName: String { name }
}

nonisolated struct SkillPatch: Sendable {
    var description: String?
    var instructions: String?
    var services: [String]?
}

nonisolated enum SkillError: LocalizedError, Sendable {
    case invalidName
    case missing(String)
    case exists(String)
    case emptyDescription
    case emptyInstructions
    case findMissing(String)
    case findAmbiguous(String, matches: Int)

    var errorDescription: String? {
        switch self {
        case .invalidName: "User skill names must use lowercase kebab-case."
        case .missing(let name): "No skill named /\(name) exists."
        case .exists(let name): "A skill named /\(name) already exists."
        case .emptyDescription: "Skill description cannot be empty."
        case .emptyInstructions: "Skill instructions cannot be empty."
        case .findMissing(let name): "The requested text was not found in /\(name)."
        case .findAmbiguous(let name, let matches): "The requested text matched \(matches) locations in /\(name); make it more specific."
        }
    }
}

nonisolated enum SkillFiles {
    static let fileName = "SKILL.md"

    static func displayName(_ name: String) -> String {
        name
    }

    static func displayTitle(_ title: String) -> String {
        guard title.hasPrefix("/") else { return title }
        return "/\(displayName(String(title.dropFirst())))"
    }

    static func slug(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "/" }
            .lowercased()
        guard !value.contains(":") else { return "" }
        return slugSegment(String(value))
    }

    static func isUserName(_ name: String) -> Bool {
        isLocalName(name)
    }

    static func isLocalName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(":") && slugSegment(name) == name
    }

    private static func slugSegment(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func parse(_ text: String, directoryName: String) -> Skill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let content = normalized.dropFirst(4)
        guard let closing = content.range(of: "\n---\n") else { return nil }
        let fields = parseFields(String(content[..<closing.lowerBound]))
        let instructions = String(content[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard fields["name"] == directoryName,
              let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty,
              !instructions.isEmpty else { return nil }
        let services = fields["services"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return Skill(name: directoryName, description: description, instructions: instructions, services: services)
    }

    static func serialize(_ skill: Skill) -> String {
        let services = skill.services.isEmpty ? "" : "\nservices: \(skill.services.joined(separator: ", "))"
        return """
        ---
        name: \(skill.name)
        description: \(scalar(skill.description))\(services)
        ---

        \(skill.instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        """ + "\n"
    }

    private static func scalar(_ value: String) -> String {
        let flattened = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let data = try? JSONEncoder().encode(flattened),
              let encoded = String(data: data, encoding: .utf8) else { return flattened }
        return encoded
    }

    private static func parseFields(_ frontmatter: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in frontmatter.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
                fields[key] = decoded
            } else {
                fields[key] = raw
            }
        }
        return fields
    }

}

extension ProfileRepository {
    func skills(in scope: ProfileScope) -> [Skill] {
        let manager = FileManager.default
        guard let root = try? skillsDirectory(in: scope),
              let directories = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
              ) else { return [] }
        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  SkillFiles.isUserName(directory.lastPathComponent),
                  let text = try? String(
                    contentsOf: directory.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: directory.lastPathComponent) else {
                Log.ui.error("ProfileRepository.skills invalid path=\(directory.lastPathComponent)")
                return nil
            }
            return skill
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func skill(named rawName: String, in scope: ProfileScope) throws -> Skill {
        let name = try canonicalSkillName(rawName)
        let file = try skillsDirectory(in: scope)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(SkillFiles.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw SkillError.missing(name) }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard let skill = SkillFiles.parse(text, directoryName: name) else { throw SkillError.missing(name) }
        return skill
    }

    @discardableResult
    func saveSkill(
        name: String,
        description: String,
        instructions: String,
        services: [String] = [],
        replacing: String? = nil,
        in scope: ProfileScope
    ) throws -> Skill {
        let name = try canonicalSkillName(name)
        let replacing = try replacing.map(canonicalSkillName)
        let root = try skillsDirectory(in: scope)
        let manager = FileManager.default
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let directoryExists = manager.fileExists(atPath: directory.path)
        if directoryExists, replacing != name {
            throw SkillError.exists(name)
        }
        let skill = try validatedSkill(
            name: name,
            description: description,
            instructions: instructions,
            services: services
        )
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try SkillFiles.serialize(skill).write(
                to: directory.appendingPathComponent(SkillFiles.fileName),
                atomically: true,
                encoding: .utf8
            )
            if let replacing, replacing != name {
                do {
                    try manager.removeItem(at: root.appendingPathComponent(replacing, isDirectory: true))
                } catch {
                    try? manager.removeItem(at: directory)
                    throw error
                }
            }
        } catch {
            if !directoryExists { try? manager.removeItem(at: directory) }
            throw error
        }
        Log.ui.info("ProfileRepository.saveSkill name=\(name) replacing=\(replacing ?? "-") services=\(services.count) count=\(skills(in: scope).count)")
        return skill
    }

    func createSkill(
        name: String,
        description: String,
        instructions: String,
        services: [String],
        in scope: ProfileScope
    ) throws -> Skill {
        try saveSkill(
            name: name,
            description: description,
            instructions: instructions,
            services: services,
            in: scope
        )
    }

    func updateSkill(named name: String, patch: SkillPatch, in scope: ProfileScope) throws -> Skill {
        let current = try skill(named: name, in: scope)
        return try saveSkill(
            name: current.name,
            description: patch.description ?? current.description,
            instructions: patch.instructions ?? current.instructions,
            services: patch.services ?? current.services,
            replacing: current.name,
            in: scope
        )
    }

    func replaceSkillText(named name: String, oldText: String, newText: String, in scope: ProfileScope) throws -> Skill {
        let current = try skill(named: name, in: scope)
        let instructions: String
        if oldText.isEmpty {
            instructions = current.instructions.isEmpty ? newText : current.instructions + "\n" + newText
        } else {
            let matches = ExactTextReplacement.count(oldText, in: current.instructions)
            guard matches > 0 else { throw SkillError.findMissing(current.name) }
            guard matches == 1 else { throw SkillError.findAmbiguous(current.name, matches: matches) }
            instructions = ExactTextReplacement.replace(oldText, with: newText, in: current.instructions)
        }
        return try updateSkill(
            named: current.name,
            patch: SkillPatch(instructions: instructions),
            in: scope
        )
    }

    func renameSkill(named name: String, to newName: String, in scope: ProfileScope) throws -> Skill {
        let current = try skill(named: name, in: scope)
        let destination = try canonicalSkillName(newName)
        guard destination != current.name else { return current }
        return try saveSkill(
            name: destination,
            description: current.description,
            instructions: current.instructions,
            services: current.services,
            replacing: current.name,
            in: scope
        )
    }

    @discardableResult
    func deleteSkill(named name: String, in scope: ProfileScope) throws -> Skill {
        let skill = try skill(named: name, in: scope)
        let root = try skillsDirectory(in: scope)
        try FileManager.default.removeItem(at: root.appendingPathComponent(skill.name, isDirectory: true))
        Log.ui.info("ProfileRepository.deleteSkill name=\(skill.name)")
        return skill
    }

    private func canonicalSkillName(_ rawName: String) throws -> String {
        let name = SkillFiles.slug(rawName)
        guard SkillFiles.isUserName(name) else { throw SkillError.invalidName }
        return name
    }

    private func validatedSkill(
        name: String,
        description: String,
        instructions: String,
        services: [String]
    ) throws -> Skill {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw SkillError.emptyDescription }
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { throw SkillError.emptyInstructions }
        var seen: Set<String> = []
        let services = services.compactMap { raw -> String? in
            let service = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !service.isEmpty, seen.insert(service).inserted else { return nil }
            return service
        }
        return Skill(name: name, description: description, instructions: instructions, services: services)
    }
}

@MainActor
@Observable
final class Skills {
    static let shared = Skills()

    private(set) var all: [Skill] = []
    private(set) var isLoaded = false
    @ObservationIgnored private let fixedScope: ProfileScope?
    @ObservationIgnored private var operation: Task<Void, Never>?

    private init() {
        fixedScope = nil
        refresh()
    }

    init(scope: ProfileScope) {
        fixedScope = scope
        refresh()
    }

    private var scope: ProfileScope? {
        fixedScope ?? StorageRoot.currentScope
    }

    func refresh() {
        isLoaded = false
        enqueue { _, _ in }
    }

    func waitUntilCurrent() async {
        await operation?.value
    }

    func skill(named name: String) -> Skill? {
        all.first { $0.name == SkillFiles.slug(name) }
    }

    func upsert(name: String, description: String, instructions: String, services: [String] = [], replacing: String? = nil) {
        enqueue(syncActive: true) { repository, scope in
            do {
                try await repository.saveSkill(
                    name: name,
                    description: description,
                    instructions: instructions,
                    services: services,
                    replacing: replacing,
                    in: scope
                )
            } catch {
                Log.ui.error("Skills.upsert name=\(name) failed: \(error.localizedDescription)")
            }
        }
    }

    func delete(_ skill: Skill) {
        enqueue(syncActive: true) { repository, scope in
            do {
                try await repository.deleteSkill(named: skill.name, in: scope)
            } catch {
                Log.ui.error("Skills.delete name=\(skill.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func enqueue(
        syncActive: Bool = false,
        _ mutation: @escaping @Sendable (ProfileRepository, ProfileScope) async -> Void
    ) {
        guard let scope else {
            all = []
            isLoaded = true
            return
        }
        let previous = operation
        let repository = ProfileRepository.shared
        operation = Task { @MainActor [weak self] in
            await previous?.value
            await mutation(repository, scope)
            let skills = await repository.skills(in: scope)
            guard self?.scope == scope else { return }
            self?.all = skills
            self?.isLoaded = true
            if syncActive, let fixedScope = self?.fixedScope,
               StorageRoot.currentScope?.profileID == fixedScope.profileID {
                Skills.shared.refresh()
            }
            Log.ui.info("Skills.refresh count=\(skills.count) generation=\(scope.generation)")
        }
    }
}
