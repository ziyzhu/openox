import Foundation

nonisolated enum JSONSchemaValidator {
    struct Violation: Equatable, Sendable {
        let path: String
        let message: String
    }

    static func validate(
        _ value: JSONValue,
        against schema: JSONValue,
        definitions: [String: JSONValue]
    ) -> [Violation] {
        var violations: [Violation] = []
        check(value, schema: schema, definitions: definitions, path: "$", depth: 0, violations: &violations)
        return Array(violations.prefix(3))
    }

    private static func check(
        _ value: JSONValue,
        schema: JSONValue,
        definitions: [String: JSONValue],
        path: String,
        depth: Int,
        violations: inout [Violation]
    ) {
        guard violations.count < 3 else { return }
        guard depth < 128 else {
            violations.append(Violation(path: path, message: "schema nesting exceeds 128 levels"))
            return
        }
        guard let object = schema.objectValue else {
            violations.append(Violation(path: path, message: "schema is not an object"))
            return
        }

        if let reference = object["$ref"]?.stringValue {
            let prefix = "#/$defs/"
            guard reference.hasPrefix(prefix) else {
                violations.append(Violation(path: path, message: "unsupported reference \(reference)"))
                return
            }
            let encoded = String(reference.dropFirst(prefix.count))
            let name = encoded.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let target = definitions[name] else {
                violations.append(Violation(path: path, message: "unresolved reference \(reference)"))
                return
            }
            check(value, schema: target, definitions: definitions, path: path, depth: depth + 1, violations: &violations)
            if violations.count >= 3 { return }
        }

        if let variants = object["allOf"]?.arrayValue {
            for variant in variants {
                check(value, schema: variant, definitions: definitions, path: path, depth: depth + 1, violations: &violations)
                if violations.count >= 3 { return }
            }
        }

        if let variants = object["anyOf"]?.arrayValue {
            let matches = variants.contains {
                validate($0, value: value, definitions: definitions, path: path, depth: depth + 1).isEmpty
            }
            if !matches { violations.append(Violation(path: path, message: "does not match any allowed schema")) }
        }

        if let variants = object["oneOf"]?.arrayValue {
            let matches = variants.filter {
                validate($0, value: value, definitions: definitions, path: path, depth: depth + 1).isEmpty
            }.count
            if matches != 1 { violations.append(Violation(path: path, message: "matches \(matches) oneOf schemas")) }
        }

        if let allowed = object["enum"]?.arrayValue, !allowed.contains(value) {
            violations.append(Violation(path: path, message: "is not an allowed value"))
        }

        let types: [String]
        if let type = object["type"]?.stringValue {
            types = [type]
        } else if let values = object["type"]?.arrayValue {
            types = values.compactMap(\.stringValue)
        } else {
            types = []
        }
        if !types.isEmpty && !types.contains(where: { matches(value, type: $0) }) {
            violations.append(Violation(path: path, message: "expected \(types.joined(separator: " or ")), got \(typeName(value))"))
            return
        }

        if case .object(let fields) = value {
            let properties = object["properties"]?.objectValue ?? [:]
            for name in object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
                violations.append(Violation(path: propertyPath(path, name), message: "is required"))
                if violations.count >= 3 { return }
            }
            for (name, child) in fields {
                if let childSchema = properties[name] {
                    check(child, schema: childSchema, definitions: definitions, path: propertyPath(path, name), depth: depth + 1, violations: &violations)
                } else if object["additionalProperties"]?.boolValue == false {
                    violations.append(Violation(path: propertyPath(path, name), message: "is not declared"))
                } else if let additional = object["additionalProperties"], additional.objectValue != nil {
                    check(child, schema: additional, definitions: definitions, path: propertyPath(path, name), depth: depth + 1, violations: &violations)
                }
                if violations.count >= 3 { return }
            }
        }

        if case .array(let values) = value, let itemSchema = object["items"] {
            for (index, child) in values.enumerated() {
                check(child, schema: itemSchema, definitions: definitions, path: "\(path)[\(index)]", depth: depth + 1, violations: &violations)
                if violations.count >= 3 { return }
            }
        }

        if case .array(let values) = value {
            if let minimum = object["minItems"]?.intValue, values.count < minimum {
                violations.append(Violation(path: path, message: "must contain at least \(minimum) items"))
            }
            if let maximum = object["maxItems"]?.intValue, values.count > maximum {
                violations.append(Violation(path: path, message: "must contain at most \(maximum) items"))
            }
        }

        if case .string(let string) = value {
            if let minimum = object["minLength"]?.intValue, string.count < minimum {
                violations.append(Violation(path: path, message: "must contain at least \(minimum) characters"))
            }
            if let maximum = object["maxLength"]?.intValue, string.count > maximum {
                violations.append(Violation(path: path, message: "must contain at most \(maximum) characters"))
            }
            if let pattern = object["pattern"]?.stringValue,
               let expression = try? NSRegularExpression(pattern: pattern),
               expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) == nil {
                violations.append(Violation(path: path, message: "does not match required pattern"))
            }
        }

        if let number = value.doubleValue {
            if let minimum = object["minimum"]?.doubleValue, number < minimum {
                violations.append(Violation(path: path, message: "must be at least \(minimum)"))
            }
            if let maximum = object["maximum"]?.doubleValue, number > maximum {
                violations.append(Violation(path: path, message: "must be at most \(maximum)"))
            }
        }
    }

    private static func validate(
        _ schema: JSONValue,
        value: JSONValue,
        definitions: [String: JSONValue],
        path: String,
        depth: Int
    ) -> [Violation] {
        var violations: [Violation] = []
        check(value, schema: schema, definitions: definitions, path: path, depth: depth, violations: &violations)
        return violations
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.null, "null"), (.bool, "boolean"), (.string, "string"), (.array, "array"), (.object, "object"), (.int, "integer"):
            return true
        case (.int, "number"), (.double, "number"):
            return true
        default:
            return false
        }
    }

    private static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func propertyPath(_ path: String, _ name: String) -> String {
        let identifier = try? NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        let range = NSRange(name.startIndex..., in: name)
        if identifier?.firstMatch(in: name, range: range) != nil { return "\(path).\(name)" }
        return "\(path)[\(String(reflecting: name))]"
    }
}
