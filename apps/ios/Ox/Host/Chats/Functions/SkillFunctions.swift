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
        return try await tracked(Actions.skillCreate, args, purpose: purpose) {
            try self.requireProfileMutation(Actions.skillCreate)
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
        return try await tracked(Actions.skillCopy, args, purpose: purpose) {
            try self.requireProfileMutation(Actions.skillCopy)
            let entry = try await self.skillsMount.entry(named: source)
            let sourceSkill = entry.skill
            let skill = try await self.repository.saveSkill(
                name: name,
                description: sourceSkill.description,
                instructions: sourceSkill.instructions,
                services: sourceSkill.services,
                resources: sourceSkill.resources,
                in: self.scope
            )
            self.refreshUserSkills()
            Log.session.info("bridge.skill.copy source=\(source) name=\(skill.name) services=\(skill.services.count)")
            return self.skillResult(skill, source: source)
        }
    }

    public func deleteSkill(name: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["name": .string(name)])
        return try await tracked(Actions.skillDelete, args, purpose: purpose) {
            try self.requireProfileMutation(Actions.skillDelete)
            let skill = try await self.skillsMount.entry(named: name).skill
            try await self.skillsMount.delete(name: name)
            self.refreshUserSkills()
            Log.session.info("bridge.skill.delete name=\(skill.name)")
            return .object([
                "name": .string(skill.name),
                "path": .string("skills/\(skill.name)/SKILL.md"),
                "deleted": .bool(true),
            ])
        }
    }

    public func shareSkill(name: String, purpose: String) async throws -> JSONValue? {
        let args: JSONValue = .object(["name": .string(name)])
        return try await tracked(Actions.skillShare, args, purpose: purpose) {
            try self.requireProfileMutation("ox.skill.share")
            let skill = try await self.skillsMount.entry(named: name).skill
            let saved = try await self.serviceManager.saveLocalSkill(skill, createOnly: true)
            return self.skillResult(saved, source: saved.owner.id)
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
