import Foundation

@MainActor
struct SkillsMount {
    enum Source: Equatable, Sendable {
        case user
        case system
        case service(String)

        var isWritable: Bool {
            self == .user
        }
    }

    struct Entry: Sendable {
        let name: String
        let description: String
        let content: String
        let source: Source

        var directoryPath: String { "skills/\(name)" }
        var filePath: String { "\(directoryPath)/\(SkillFiles.fileName)" }
    }

    let repository: ProfileRepository
    let scope: ProfileScope
    let services: [Service]

    static nonisolated func isPathName(_ name: String) -> Bool {
        if SkillFiles.isUserName(name) { return true }
        if name.hasPrefix("system:") {
            let localName = String(name.dropFirst("system:".count))
            return SkillFiles.isLocalName(localName)
        }
        guard name.hasPrefix("service:") else { return false }
        let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              validServiceDomain(parts[1]),
              SkillFiles.isLocalName(parts[2]) else { return false }
        return true
    }

    func entries() async -> [Entry] {
        var entries = await repository.skills(in: scope).map { skill in
            Entry(
                name: skill.name,
                description: skill.description,
                content: SkillFiles.serialize(skill),
                source: .user
            )
        }
        entries.append(contentsOf: BuiltInSkills.all.map {
            Entry(name: $0.name, description: $0.description, content: $0.content, source: .system)
        })
        await withTaskGroup(of: Void.self) { group in
            for service in services {
                group.addTask { _ = await service.loadManifest() }
            }
        }
        for service in services {
            for skill in service.skills {
                guard let content = service.skill(named: skill.name) else { continue }
                entries.append(Entry(
                    name: "service:\(service.domain):\(skill.name)",
                    description: skill.description,
                    content: content,
                    source: .service(service.domain)
                ))
            }
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entry(named name: String) async throws -> Entry {
        if let builtIn = BuiltInSkills.entry(named: name) {
            return Entry(
                name: builtIn.name,
                description: builtIn.description,
                content: builtIn.content,
                source: .system
            )
        }
        if name.hasPrefix("service:") {
            let parts = name.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3,
                  let service = services.first(where: { $0.domain == parts[1] }) else {
                throw SkillError.missing(name)
            }
            _ = await service.loadManifest()
            guard let skill = service.skills.first(where: { $0.name == parts[2] }),
                  let content = service.skill(named: skill.name) else {
                throw SkillError.missing(name)
            }
            return Entry(
                name: name,
                description: skill.description,
                content: content,
                source: .service(service.domain)
            )
        }
        guard SkillFiles.isUserName(name) else { throw SkillError.missing(name) }
        let skill = try await repository.skill(named: name, in: scope)
        return Entry(
            name: skill.name,
            description: skill.description,
            content: SkillFiles.serialize(skill),
            source: .user
        )
    }

    func requireWritable(name: String, path: String) async throws {
        if SkillFiles.isUserName(name) {
            if let existing = try? await entry(named: name), !existing.source.isWritable {
                throw VirtualFileSystem.Error.unsupportedMutation(path)
            }
            return
        }
        throw VirtualFileSystem.Error.unsupportedMutation(path)
    }

    private static nonisolated func validServiceDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain == domain.lowercased() && domain.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
        }
    }
}
