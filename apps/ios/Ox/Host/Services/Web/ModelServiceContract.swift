import Foundation

nonisolated enum ModelServiceContract {
    static let list = "listModels"
    static let start = "startModelGeneration"
    static let read = "readModelGeneration"
    static let cancel = "cancelModelGeneration"
    static let generationIDs: Set<String> = [start, read, cancel]
    static let actionIDs = generationIDs.union([list])

    private static let schemas: [String: JSONValue] = {
        guard let url = Bundle.main.url(forResource: "ModelServiceActions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            fatalError("Missing ModelServiceActions.json")
        }
        return value
    }()

    static func validate(_ actions: [Manifest.Action], definitions: [String: JSONValue], isWeb: Bool) throws {
        guard actions.contains(where: { generationIDs.contains($0.id) }) else { return }
        guard isWeb else { throw ServiceDefinition.ValidationError.invalid("model Actions require a web service") }
        for id in actionIDs {
            guard let action = actions.first(where: { $0.id == id }), !action.blocking,
                  let expected = schemas[id]?.objectValue,
                  try normalized(action.inputSchema ?? .null, definitions: definitions) == normalized(expected["inputSchema"] ?? .null),
                  try normalized(action.outputSchema ?? .null, definitions: definitions) == normalized(expected["outputSchema"] ?? .null) else {
                throw ServiceDefinition.ValidationError.invalid("standard model Action \(id)")
            }
        }
        guard Set(actions.filter { generationIDs.contains($0.id) }.map { $0.raw["baseUrl"]?.stringValue ?? "" }).count == 1 else {
            throw ServiceDefinition.ValidationError.invalid("model generation Actions must share a baseUrl")
        }
        guard !actions.contains(where: { generationIDs.contains($0.id) && ($0.raw["baseUrl"]?.stringValue?.contains(where: { $0 == "{" || $0 == "}" }) == true) }) else {
            throw ServiceDefinition.ValidationError.invalid("model generation baseUrl must be literal")
        }
    }

    private static func normalized(_ value: JSONValue, definitions: [String: JSONValue] = [:], depth: Int = 0) throws -> JSONValue {
        guard depth <= 32 else { throw ServiceDefinition.ValidationError.invalid("recursive model schema") }
        if let array = value.arrayValue {
            return .array(try array.map { try normalized($0, definitions: definitions, depth: depth + 1) })
        }
        guard var fields = value.objectValue else { return value }
        fields.removeValue(forKey: "description")
        if let reference = fields["$ref"]?.stringValue {
            guard fields.count == 1, reference.hasPrefix("#/$defs/"),
                  let target = definitions[String(reference.dropFirst(8))] else {
                throw ServiceDefinition.ValidationError.invalid("model schema reference")
            }
            return try normalized(target, definitions: definitions, depth: depth + 1)
        }
        for (key, field) in fields {
            if key == "properties", let properties = field.objectValue {
                fields[key] = .object(try properties.mapValues { try normalized($0, definitions: definitions, depth: depth + 1) })
            } else if ["required", "enum"].contains(key), let values = field.arrayValue {
                fields[key] = .array(values.sorted { $0.jsonString() < $1.jsonString() })
            } else {
                fields[key] = try normalized(field, definitions: definitions, depth: depth + 1)
            }
        }
        return .object(fields)
    }
}
