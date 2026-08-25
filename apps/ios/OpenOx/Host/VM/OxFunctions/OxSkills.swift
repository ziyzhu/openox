import Foundation
import JavaScriptCore

nonisolated enum OxSkills {
    static let function = OxFunction(
        namespace: "skill",
        schema: {
            [
                entry(
                    "ox.skill.create",
                    "Create one Profile-owned skill: `await ox.skill.create({ name, description, instructions, services?, purpose })`. The name is normalized to lowercase kebab-case and creation fails rather than replacing an existing skill.",
                    input: object([
                        "name": name,
                        "description": description,
                        "instructions": instructions,
                        "services": services,
                    ], required: ["name", "description", "instructions"]),
                    output: skill
                ),
                entry(
                    "ox.skill.copy",
                    "Copy one readable Profile, `system:`, or `service:` skill into a new Profile-owned skill: `await ox.skill.copy({ source, name, purpose })`. The destination name is normalized to lowercase kebab-case and must not already exist. A copied service skill retains its owning service dependency.",
                    input: object([
                        "source": source,
                        "name": name,
                    ], required: ["source", "name"]),
                    output: skill
                ),
                entry(
                    "ox.skill.delete",
                    "Delete one Profile-owned skill: `await ox.skill.delete({ name, purpose })`. Read-only `system:` and `service:` skills cannot be deleted.",
                    input: object(["name": name], required: ["name"]),
                    output: deletion
                ),
            ]
        },
        installNatives: { context, env in
            let create: @convention(block) (String, String, String, JSValue, JSValue) -> JSValue = {
                name, description, instructions, servicesValue, purposeValue in
                let services = jsValueToJSON(servicesValue)?.arrayValue?.compactMap(\.stringValue) ?? []
                return env.call {
                    try await $0.createSkill(
                        name: name,
                        description: description,
                        instructions: instructions,
                        services: services,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            context.setObject(create as AnyObject, forKeyedSubscript: "__nativeSkillCreate" as NSString)

            let copy: @convention(block) (String, String, JSValue) -> JSValue = { source, name, purposeValue in
                env.call { try await $0.copySkill(source: source, name: name, purpose: purposeValue.toString()!) }
            }
            context.setObject(copy as AnyObject, forKeyedSubscript: "__nativeSkillCopy" as NSString)

            let delete: @convention(block) (String, JSValue) -> JSValue = { name, purposeValue in
                env.call { try await $0.deleteSkill(name: name, purpose: purposeValue.toString()!) }
            }
            context.setObject(delete as AnyObject, forKeyedSubscript: "__nativeSkillDelete" as NSString)
        },
        jsFragment: """
          create: (value) => { const options = __oxOptions(value, 'ox.skill.create'); return __nativeSkillCreate(String(options.name), String(options.description), String(options.instructions), options.services ?? [], String(options.purpose)); },
          copy: (value) => { const options = __oxOptions(value, 'ox.skill.copy'); return __nativeSkillCopy(String(options.source), String(options.name), String(options.purpose)); },
          delete: (value) => { const options = __oxOptions(value, 'ox.skill.delete'); return __nativeSkillDelete(String(options.name), String(options.purpose)); }
        """
    )

    private static let name: JSONValue = .object([
        "type": .string("string"),
        "minLength": .int(1),
        "maxLength": .int(200),
    ])
    private static let source: JSONValue = .object([
        "type": .string("string"),
        "minLength": .int(1),
        "maxLength": .int(500),
    ])
    private static let description: JSONValue = .object([
        "type": .string("string"),
        "minLength": .int(1),
        "maxLength": .int(1_000),
    ])
    private static let instructions: JSONValue = .object([
        "type": .string("string"),
        "minLength": .int(1),
        "maxLength": .int(VirtualFileSystem.maximumReadBytes),
    ])
    private static let services: JSONValue = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
        "maxItems": .int(50),
        "uniqueItems": .bool(true),
    ])
    private static let skill = object([
        "name": name,
        "description": description,
        "services": services,
        "path": source,
        "source": .object(["type": .array([.string("string"), .string("null")])]),
    ], required: ["name", "description", "services", "path"])
    private static let deletion = object([
        "name": name,
        "path": source,
        "deleted": .object(["type": .string("boolean")]),
    ], required: ["name", "path", "deleted"])

    private static func entry(_ name: String, _ description: String, input: JSONValue, output: JSONValue) -> (String, JSONValue) {
        (name, .object(["description": .string(description), "inputSchema": input, "outputSchema": output]))
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }
}
