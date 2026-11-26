import Foundation

nonisolated enum ModelServiceContract {
    static let maximumSubmissions = 32
    static let maximumResponseBytes = 2_000_000
    static let maximumRetainedResponseBytes = 8_000_000
    static let list = "listModels"
    static let start = "startModelGeneration"
    static let resume = "continueModelGeneration"
    static let read = "readModelGeneration"
    static let cancel = "cancelModelGeneration"
    static let generationIDs: Set<String> = [start, resume, read, cancel]

    static func normalized(_ value: JSONValue, definitions: [String: JSONValue] = [:], depth: Int = 0) throws -> JSONValue {
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
