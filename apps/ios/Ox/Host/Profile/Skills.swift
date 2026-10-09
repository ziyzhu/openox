import Foundation
import Observation

nonisolated struct Skill: Codable, Identifiable, Equatable, Sendable {
    var name: String
    var description: String
    var instructions: String
    var services: [String] = []
    var resources: [String: String]? = nil
    var source: SkillOwner? = nil
    var owner: SkillOwner { source ?? .user }
    var id: String { "\(owner.id):\(name)" }
    var displayName: String { name }
}

nonisolated struct SkillPatch: Sendable {
    var description: String?
    var instructions: String?
    var services: [String]?
}

nonisolated enum SkillError: LocalizedError, Sendable {
    case invalidPackage
    case conflict(String)
    case reserved(String)
    case invalidName
    case missing(String)
    case exists(String)
    case emptyDescription
    case emptyInstructions
    case findMissing(String)
    case findAmbiguous(String, matches: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPackage: "The skill package is invalid or too large."
        case .conflict(let name): "Choose a source for /\(name) in Skills before using it."
        case .reserved(let name): "The name /\(name) is reserved for a bundled System skill. Copy it to a distinct name to customize."
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
    static let maximumBytes = 524_288
    static let maximumFiles = 64
    static let reservedNames = ModelGuidance.bundledSkillNames

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
        guard isLocalName(directoryName), directoryName.count <= 100, fields["name"] == directoryName,
              let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty,
              !instructions.isEmpty else { return nil }
        let services = fields["services"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard services.allSatisfy({ $0.range(of: "^[a-z0-9]+(?:[.:-][a-z0-9]+)*$", options: .regularExpression) != nil }) else { return nil }
        return Skill(name: directoryName, description: description, instructions: instructions, services: services.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
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
            guard parts.count == 2 else { return [:] }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard ["name", "description", "services"].contains(key), fields[key] == nil else { return [:] }
            let raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
                fields[key] = decoded
            } else {
                guard !raw.hasPrefix("\"") else { return [:] }
                fields[key] = raw
            }
        }
        return fields
    }

}

extension ProfileRepository {
    func skills(in scope: ProfileScope) async throws -> [Skill] {
        let files = try await profileFiles(prefix: "skills/", in: scope)
        let names = Set(try files.map { file in
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[0] == "skills", SkillFiles.isUserName(String(parts[1])) else {
                throw SkillError.invalidPackage
            }
            return String(parts[1])
        })
        var skills: [Skill] = []
        for name in names.sorted() {
            skills.append(try await loadSkill(name: name, files: files.filter { $0.path.hasPrefix("skills/\(name)/") }, in: scope))
        }
        return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func skill(named rawName: String, in scope: ProfileScope) async throws -> Skill {
        let name = try canonicalSkillName(rawName)
        let files = try await profileFiles(prefix: "skills/\(name)/", in: scope)
        guard !files.isEmpty else { throw SkillError.missing(name) }
        return try await loadSkill(name: name, files: files, in: scope)
    }

    private func loadSkill(name: String, files: [DurableProfileFile], in scope: ProfileScope) async throws -> Skill {
        guard files.count <= SkillFiles.maximumFiles,
              files.reduce(0, { $0 + $1.size }) <= SkillFiles.maximumBytes else { throw SkillError.invalidPackage }
        let prefix = "skills/\(name)/"
        var contents: [String: String] = [:]
        for file in files {
            let path = String(file.path.dropFirst(prefix.count))
            guard file.path.hasPrefix(prefix), !file.binary,
                  path == SkillFiles.fileName || SkillFiles.isResourcePath(path),
                  let text = try await readTextFile(named: file.path, in: scope) else { throw SkillError.invalidPackage }
            contents[path] = text
        }
        guard let text = contents.removeValue(forKey: SkillFiles.fileName),
              var skill = SkillFiles.parse(text, directoryName: name) else { throw SkillError.invalidPackage }
        skill.resources = contents.isEmpty ? nil : contents
        try SkillFiles.validate(skill)
        return skill
    }

    @discardableResult
    func saveSkill(
        name: String,
        description: String,
        instructions: String,
        services: [String] = [],
        replacing: String? = nil,
        resources: [String: String]? = nil,
        in scope: ProfileScope
    ) async throws -> Skill {
        let name = try canonicalSkillName(name)
        let replacing = try replacing.map(canonicalSkillName)
        let existing = try await profileFiles(prefix: "skills/\(name)/", in: scope)
        if !existing.isEmpty, replacing != name { throw SkillError.exists(name) }
        var skill = try validatedSkill(name: name, description: description, instructions: instructions, services: services)
        if let resources {
            skill.resources = resources
        } else if let replacing {
            skill.resources = try await self.skill(named: replacing, in: scope).resources
        }
        try SkillFiles.validate(skill)
        let prefix = "skills/\(name)/"
        let resources = skill.resources ?? [:]
        let instructions = SkillFiles.serialize(skill)
        guard instructions.utf8.count <= ArtifactLimits.textBytes,
              resources.values.allSatisfy({ $0.utf8.count <= ArtifactLimits.textBytes }) else { throw SkillError.invalidPackage }
        var writes = Dictionary(uniqueKeysWithValues: resources.map { (prefix + $0.key, $0.value) })
        writes[prefix + SkillFiles.fileName] = instructions
        var removes = existing.filter { writes[$0.path] == nil }.map(\.path)
        if let replacing, replacing != name {
            let source = try await profileFiles(prefix: "skills/\(replacing)/", in: scope)
            guard !source.isEmpty else { throw SkillError.missing(replacing) }
            removes += source.map(\.path)
        }
        try await commitSkillFiles(writes: writes, removes: removes, in: scope)
        Log.ui.info("ProfileRepository.saveSkill profile=\(scope.profileID?.uuidString ?? "temporary") name=\(name) replacing=\(replacing ?? "-") files=\(writes.count) removed=\(removes.count)")
        return skill
    }

    func createSkill(
        name: String,
        description: String,
        instructions: String,
        services: [String],
        in scope: ProfileScope
    ) async throws -> Skill {
        try await saveSkill(
            name: name,
            description: description,
            instructions: instructions,
            services: services,
            in: scope
        )
    }

    func updateSkill(named name: String, patch: SkillPatch, in scope: ProfileScope) async throws -> Skill {
        let current = try await skill(named: name, in: scope)
        return try await saveSkill(
            name: current.name,
            description: patch.description ?? current.description,
            instructions: patch.instructions ?? current.instructions,
            services: patch.services ?? current.services,
            replacing: current.name,
            in: scope
        )
    }

    func replaceSkillText(named name: String, oldText: String, newText: String, in scope: ProfileScope) async throws -> Skill {
        let current = try await skill(named: name, in: scope)
        let instructions: String
        if oldText.isEmpty {
            instructions = current.instructions.isEmpty ? newText : current.instructions + "\n" + newText
        } else {
            let matches = ExactTextReplacement.count(oldText, in: current.instructions)
            guard matches > 0 else { throw SkillError.findMissing(current.name) }
            guard matches == 1 else { throw SkillError.findAmbiguous(current.name, matches: matches) }
            instructions = ExactTextReplacement.replace(oldText, with: newText, in: current.instructions)
        }
        return try await updateSkill(
            named: current.name,
            patch: SkillPatch(instructions: instructions),
            in: scope
        )
    }

    func renameSkill(named name: String, to newName: String, in scope: ProfileScope) async throws -> Skill {
        let current = try await skill(named: name, in: scope)
        let destination = try canonicalSkillName(newName)
        guard destination != current.name else { return current }
        return try await saveSkill(
            name: destination,
            description: current.description,
            instructions: current.instructions,
            services: current.services,
            replacing: current.name,
            in: scope
        )
    }

    @discardableResult
    func deleteSkill(named name: String, in scope: ProfileScope) async throws -> Skill {
        let skill = try await skill(named: name, in: scope)
        let files = try await profileFiles(prefix: "skills/\(skill.name)/", in: scope)
        try await commitSkillFiles(writes: [:], removes: files.map(\.path), in: scope)
        Log.ui.info("ProfileRepository.deleteSkill profile=\(scope.profileID?.uuidString ?? "temporary") name=\(skill.name) files=\(files.count)")
        return skill
    }

    private func commitSkillFiles(writes: [String: String], removes: [String], in scope: ProfileScope) async throws {
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileBatch"),
            "writes": .array(writes.sorted { $0.key < $1.key }.map { .object(["path": .string($0.key), "text": .string($0.value)]) }),
            "removes": .array(Set(removes).sorted().map { .string($0) }),
        ]))
    }

    private func canonicalSkillName(_ rawName: String) throws -> String {
        let name = SkillFiles.slug(rawName)
        guard SkillFiles.isUserName(name) else { throw SkillError.invalidName }
        guard !SkillFiles.reservedNames.contains(name) else { throw SkillError.reserved(name) }
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
    private(set) var conflicts: [SkillCatalog.Conflict] = []
    private(set) var errorMessage: String?
    private(set) var repositorySkills: [Skill] = []
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

    private var scope: ProfileScope? { fixedScope ?? StorageRoot.currentScope }

    func setRepositorySkills(_ skills: [Skill]) {
        guard repositorySkills != skills else { return }
        repositorySkills = skills
        refresh()
    }

    static func catalog(in scope: ProfileScope, repositorySkills: [Skill]) async throws -> SkillCatalog {
        let users = try await ProfileRepository.shared.skills(in: scope)
        let selections = try await ProfileRepository.shared.skillSelections(in: scope)
        let bundled = try await DurableProfileStore.shared.session(in: scope).skills.skills
        return SkillCatalog(candidates: bundled + repositorySkills + users, selections: selections.sources)
    }

    func refresh() { enqueue { _, _ in } }
    func waitUntilCurrent() async { await operation?.value }
    func dismissError() { errorMessage = nil }
    func skill(named name: String) -> Skill? { all.first { $0.name == SkillFiles.slug(name) } }

    func select(name: String, source: String?) {
        enqueue(syncActive: true) { repository, scope in
            try await repository.selectSkill(name: name, source: source, in: scope)
        }
    }

    func customize(_ skill: Skill, name: String) {
        enqueue(syncActive: true) { repository, scope in
            let saved = try await repository.saveSkill(name: name, description: skill.description, instructions: skill.instructions, services: skill.services, resources: skill.resources, in: scope)
            try await repository.selectSkill(name: saved.name, source: SkillOwner.user.id, in: scope)
        }
    }

    func share(_ skill: Skill, manager: ServiceManager) {
        enqueue(syncActive: true) { _, _ in
            _ = try await manager.saveLocalSkill(skill, createOnly: true)
        }
    }

    func upsert(name: String, description: String, instructions: String, services: [String] = [], replacing: String? = nil, resources: [String: String]? = nil, owner: SkillOwner = .user, manager: ServiceManager? = nil) {
        enqueue(syncActive: true) { repository, scope in
            guard owner.isWritable else { throw SkillError.reserved(name) }
            if case .repository = owner {
                guard let manager else { throw SkillError.missing(name) }
                let skill = Skill(name: SkillFiles.slug(name), description: description, instructions: instructions, services: services, resources: resources)
                _ = try await manager.saveLocalSkill(skill, replacing: replacing)
            } else {
                _ = try await repository.saveSkill(name: name, description: description, instructions: instructions, services: services, replacing: replacing, resources: resources, in: scope)
            }
        }
    }

    func delete(_ skill: Skill, manager: ServiceManager) {
        enqueue(syncActive: true) { repository, scope in
            guard skill.owner.isWritable else { throw SkillError.reserved(skill.name) }
            if case .repository = skill.owner { try await manager.deleteLocalSkill(name: skill.name) }
            else { _ = try await repository.deleteSkill(named: skill.name, in: scope) }
        }
    }

    private func enqueue(syncActive: Bool = false, _ mutation: @escaping @MainActor (ProfileRepository, ProfileScope) async throws -> Void) {
        guard let scope else {
            all = []
            conflicts = []
            isLoaded = true
            return
        }
        let previous = operation
        let repository = ProfileRepository.shared
        operation = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await mutation(repository, scope)
                let catalog = try await Self.catalog(in: scope, repositorySkills: Self.shared.repositorySkills)
                guard self?.scope == scope else { return }
                self?.all = catalog.skills
                self?.conflicts = catalog.conflicts
                self?.errorMessage = nil
            } catch {
                guard self?.scope == scope else { return }
                self?.errorMessage = error.localizedDescription
                Log.ui.error("Skills.refresh failed=\(error.localizedDescription)")
            }
            self?.isLoaded = true
            if syncActive, self?.fixedScope != nil, StorageRoot.currentScope == scope { Self.shared.refresh() }
        }
    }
}
