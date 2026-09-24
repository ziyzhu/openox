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

@MainActor
final class SkillSession {
    var snapshots: [String: Skill] = [:]
}

extension ProfileRepository {
    func skillSelections(in scope: ProfileScope) throws -> SkillSelections {
        let file = try file(named: "skill-selections.json", in: scope)
        guard FileManager.default.fileExists(atPath: file.path) else { return SkillSelections() }
        let selections = try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: file))
        guard selections.version == 1 else { throw SkillError.invalidPackage }
        return selections
    }

    func selectSkill(name: String, source: String?, in scope: ProfileScope) throws {
        guard SkillFiles.isUserName(name) else { throw SkillError.invalidName }
        var selections = try skillSelections(in: scope)
        selections.sources[name] = source
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(selections).write(to: file(named: "skill-selections.json", in: scope), options: .atomic)
        Log.ui.info("Skills.select name=\(name) source=\(source ?? "automatic") profile=\(scope.profileID?.uuidString ?? "temporary")")
    }
}
