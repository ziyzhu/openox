import Foundation

extension Chat {
    public func createSkill(
        name: String,
        description: String,
        instructions: String,
        services: [String],
        purpose: String
    ) async throws -> JSONValue? {
        let args = skillMutationArgs(name: name, services: services)
        return try await tracked(.skillCreate, args, purpose: purpose) {
            try self.requireProfileMutation(.skillCreate)
            let skill = try await self.repository.createSkill(
                name: name,
                description: description,
                instructions: instructions,
                services: services,
                in: self.scope
            )
            self.refreshUserSkills()
            Log.session.info("bridge.skill.create name=\(skill.name) services=\(skill.services.count)")
            return self.skillResult(skill, source: nil)
        }
    }

    public func copySkill(source: String, name: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["source": .string(source), "name": .string(name)])
        return try await tracked(.skillCopy, args, purpose: purpose) {
            try self.requireProfileMutation(.skillCopy)
            let entry = try await self.skillsMount.entry(named: source)
            let sourceName = switch entry.source {
            case .user, .system: entry.name
            case .service: entry.name.split(separator: ":").last.map(String.init) ?? entry.name
            }
            guard let sourceSkill = SkillFiles.parse(entry.content, directoryName: sourceName) else {
                throw RuntimeError.bridge("ox.skill.copy: source '\(source)' is invalid.")
            }
            var services = sourceSkill.services
            if case .service(let domain) = entry.source, !services.contains(domain) {
                services.append(domain)
            }
            let skill = try await self.repository.createSkill(
                name: name,
                description: sourceSkill.description,
                instructions: sourceSkill.instructions,
                services: services,
                in: self.scope
            )
            self.refreshUserSkills()
            Log.session.info("bridge.skill.copy source=\(source) name=\(skill.name) services=\(skill.services.count)")
            return self.skillResult(skill, source: source)
        }
    }

    public func deleteSkill(name: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["name": .string(name)])
        return try await tracked(.skillDelete, args, purpose: purpose) {
            try self.requireProfileMutation(.skillDelete)
            let skill = try await self.repository.deleteSkill(named: name, in: self.scope)
            self.refreshUserSkills()
            Log.session.info("bridge.skill.delete name=\(skill.name)")
            return .object([
                "name": .string(skill.name),
                "path": .string("skills/\(skill.name)/SKILL.md"),
                "deleted": .bool(true),
            ])
        }
    }

    private func skillMutationArgs(name: String, services: [String]) -> JSONValue {
        .object([
            "name": .string(name),
            "services": .array(services.map(JSONValue.string)),
        ])
    }

    private func skillResult(_ skill: Skill, source: String?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(skill.name),
            "description": .string(skill.description),
            "services": .array(skill.services.map(JSONValue.string)),
            "path": .string("skills/\(skill.name)/SKILL.md"),
        ]
        if let source { fields["source"] = .string(source) }
        return .object(fields)
    }
}
