import Foundation

nonisolated enum SkillOwner: Codable, Equatable, Hashable, Sendable {
    case system
    case user
    case repository(id: String, name: String, writable: Bool)

    var id: String {
        switch self {
        case .system: "system"
        case .user: "user"
        case .repository(let id, _, _): "repository:\(id)"
        }
    }

    var name: String {
        switch self {
        case .system: String(localized: "System")
        case .user: String(localized: "My Skills")
        case .repository(_, let name, _): name
        }
    }

    var isWritable: Bool {
        switch self {
        case .system: false
        case .user: true
        case .repository(_, _, let writable): writable
        }
    }
}

nonisolated struct SkillSelections: Codable, Sendable {
    var version = 1
    var sources: [String: String] = [:]
}

nonisolated struct SkillCatalog: Sendable {
    struct Conflict: Identifiable, Sendable {
        let name: String
        let candidates: [Skill]
        let selectedSourceID: String?
        var id: String { name }
    }

    let skills: [Skill]
    let conflicts: [Conflict]

    init(candidates: [Skill], selections: [String: String]) {
        let grouped = Dictionary(grouping: candidates, by: \.name)
        var resolved: [Skill] = []
        var conflicts: [Conflict] = []
        for name in Set(grouped.keys).union(selections.keys).sorted() {
            let options = (grouped[name] ?? []).sorted { $0.owner.id < $1.owner.id }
            if let system = options.first(where: { $0.owner == .system }) {
                resolved.append(system)
                continue
            }
            let selected: Skill?
            if let source = selections[name] {
                selected = options.first { $0.owner.id == source }
            } else {
                selected = options.count == 1 ? options.first : nil
            }
            if let selected { resolved.append(selected) }
            if options.count > 1 || (selections[name] != nil && selected == nil) {
                conflicts.append(Conflict(name: name, candidates: options, selectedSourceID: selected?.owner.id))
            }
        }
        skills = resolved
        self.conflicts = conflicts
    }

    func skill(named name: String) throws -> Skill {
        if let skill = skills.first(where: { $0.name == name }) { return skill }
        if conflicts.contains(where: { $0.name == name }) { throw SkillError.conflict(name) }
        throw SkillError.missing(name)
    }
}

nonisolated struct BundledSkillPackages: Sendable {
    struct Requirement: Decodable, Sendable {
        let action: String
        let skill: String
        let pathPrefix: String?
    }
    private struct Snapshot: Decodable {
        struct Package: Decodable {
            let name: String
            let source: String
            let files: [String: String]
        }
        let scope: String
        let skills: [Package]
        let activationRequirements: [Requirement]
    }
    let skills: [Skill]
    let activationRequirements: [Requirement]

    init(data: Data, scope: String) throws {
        guard data.count <= 1024 * 1024 else { throw SkillError.invalidPackage }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.scope == scope, snapshot.skills.count <= 64,
              Set(snapshot.skills.map(\.name)) == SkillFiles.reservedNames,
              snapshot.skills.count == SkillFiles.reservedNames.count else { throw SkillError.invalidPackage }
        skills = try snapshot.skills.map { package in
            guard package.source == "system", let text = package.files[SkillFiles.fileName],
                  var skill = SkillFiles.parse(text, directoryName: package.name),
                  package.files.count <= SkillFiles.maximumFiles,
                  package.files.values.allSatisfy({ $0.utf8.count <= VirtualFileSystem.maximumReadBytes }) else { throw SkillError.invalidPackage }
            let resources = package.files.filter { $0.key != SkillFiles.fileName }
            skill.resources = resources.isEmpty ? nil : resources
            skill.source = .system
            try SkillFiles.validate(skill)
            return skill
        }
        guard snapshot.activationRequirements.count <= 64, snapshot.activationRequirements.allSatisfy({ requirement in
            SkillFiles.reservedNames.contains(requirement.skill) && requirement.action.hasPrefix("ox.") &&
            (requirement.pathPrefix == nil || requirement.pathPrefix!.hasSuffix("/") && !requirement.pathPrefix!.hasPrefix("/") &&
                requirement.pathPrefix!.dropLast().split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                    $0.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil
                })
        }) else { throw SkillError.invalidPackage }
        activationRequirements = snapshot.activationRequirements
        Log.agent.info("Skills.bundle scope=\(scope) packages=\(skills.count) requirements=\(activationRequirements.count)")
    }
}

@MainActor
final class SkillSession {
    var snapshots: [String: Skill] = [:]
}

extension ProfileRepository {
    func skillSelections(in scope: ProfileScope) async throws -> SkillSelections {
        guard let text = try await readTextFile(named: "skill-selections.json", in: scope) else { return SkillSelections() }
        let selections = try JSONDecoder().decode(SkillSelections.self, from: Data(text.utf8))
        guard selections.version == 1 else { throw SkillError.invalidPackage }
        return selections
    }

    func selectSkill(name: String, source: String?, in scope: ProfileScope) async throws {
        guard SkillFiles.isUserName(name) else { throw SkillError.invalidName }
        var selections = try await skillSelections(in: scope)
        selections.sources[name] = source
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let text = String(decoding: try encoder.encode(selections), as: UTF8.self)
        try await writeTextFile(text, named: "skill-selections.json", in: scope)
        Log.ui.info("Skills.select name=\(name) source=\(source ?? "automatic") profile=\(scope.profileID?.uuidString ?? "temporary")")
    }
}
