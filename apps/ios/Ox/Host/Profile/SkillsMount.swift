import Foundation

@MainActor
struct SkillsMount {
    struct Resource: Sendable {
        let name: String
        let content: String
    }

    struct Entry: Sendable {
        let skill: Skill
        var name: String { skill.name }
        var description: String { skill.description }
        var content: String { SkillFiles.serialize(skill) }
        var source: SkillOwner { skill.owner }
        var resources: [Resource] {
            (skill.resources ?? [:]).sorted { $0.key < $1.key }.map { Resource(name: $0.key, content: $0.value) }
        }
        var directoryPath: String { "skills/\(name)" }
        var filePath: String { "\(directoryPath)/SKILL.md" }
        func resourcePath(_ resource: Resource) -> String { "\(directoryPath)/\(resource.name)" }
    }

    let repository: ProfileRepository
    let scope: ProfileScope
    let manager: ServiceManager
    let session: SkillSession

    static nonisolated func isPathName(_ name: String) -> Bool { SkillFiles.isLocalName(name) }

    func catalog() async throws -> SkillCatalog {
        try await Skills.catalog(in: scope, repositorySkills: manager.repositorySkills)
    }

    func entries() async throws -> [Entry] {
        let catalog = try await catalog()
        var skills = Dictionary(uniqueKeysWithValues: catalog.skills.map { ($0.name, $0) })
        for (name, skill) in session.snapshots { skills[name] = skill }
        return skills.values.sorted { $0.name < $1.name }.map { Entry(skill: $0) }
    }

    func entry(named name: String) async throws -> Entry {
        if let snapshot = session.snapshots[name] { return Entry(skill: snapshot) }
        let skill = try await catalog().skill(named: name)
        return Entry(skill: skill)
    }

    func activate(named name: String) async throws -> Entry {
        let entry = try await entry(named: name)
        session.snapshots[name] = entry.skill
        return entry
    }

    func resource(skill name: String, path: String) async throws -> Resource {
        let entry = try await activate(named: name)
        guard let content = entry.skill.resources?[path] else { throw SkillError.missing("\(name)/\(path)") }
        return Resource(name: path, content: content)
    }

    func requireWritable(name: String, path: String) async throws {
        guard !SkillFiles.reservedNames.contains(name) else { throw SkillError.reserved(name) }
        let catalog = try await catalog()
        if catalog.conflicts.contains(where: { $0.name == name && $0.selectedSourceID == nil }) { throw SkillError.conflict(name) }
        let selected = catalog.skills.first(where: { $0.name == name })
        if let snapshot = session.snapshots[name], snapshot.owner.id != selected?.owner.id { throw SkillError.conflict(name) }
        if let skill = selected, !skill.owner.isWritable {
            throw VirtualFileSystem.Error.unsupportedMutation(path)
        }
    }

    func save(_ skill: Skill) async throws -> Skill {
        try await requireWritable(name: skill.name, path: "skills/\(skill.name)")
        let selected = try await catalog().skills.first { $0.name == skill.name }
        var saved = skill
        if case .repository = selected?.owner {
            saved = try await manager.saveLocalSkill(skill)
        } else {
            let exists = (try? await repository.skill(named: skill.name, in: scope)) != nil
            saved = try await repository.saveSkill(name: skill.name, description: skill.description, instructions: skill.instructions, services: skill.services, replacing: exists ? skill.name : nil, resources: skill.resources, in: scope)
        }
        session.snapshots.removeValue(forKey: skill.name)
        Skills.shared.refresh()
        return saved
    }

    func delete(name: String) async throws {
        try await requireWritable(name: name, path: "skills/\(name)")
        let selected = try await catalog().skill(named: name)
        if case .repository = selected.owner { try await manager.deleteLocalSkill(name: name) }
        else { _ = try await repository.deleteSkill(named: name, in: scope) }
        session.snapshots.removeValue(forKey: name)
        Skills.shared.refresh()
    }
}
