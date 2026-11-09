import Foundation

nonisolated struct SecretReference: Hashable, Sendable {
    static let marker = "$secret"

    let key: String
    let field: String?

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let key = object[Self.marker]?.stringValue, !key.isEmpty,
              Set(object.keys).isSubset(of: [Self.marker, "field", "serviceID"]) else { return nil }
        if let field = object["field"], field.stringValue == nil { return nil }
        self.key = key
        self.field = object["field"]?.stringValue
    }

    static func collect(_ value: JSONValue) -> [SecretReference] {
        if let reference = SecretReference(value) { return [reference] }
        switch value {
        case .array(let items): return items.flatMap(collect)
        case .object(let fields): return fields.keys.sorted().flatMap { collect(fields[$0] ?? .null) }
        default: return []
        }
    }

    static func annotate(_ value: JSONValue, owner: (SecretReference) throws -> String) rethrows -> JSONValue {
        if let reference = SecretReference(value) {
            var object: [String: JSONValue] = [marker: .string(reference.key), "serviceID": .string(try owner(reference))]
            if let field = reference.field { object["field"] = .string(field) }
            return .object(object)
        }
        switch value {
        case .array(let items): return .array(try items.map { try annotate($0, owner: owner) })
        case .object(let fields): return .object(try fields.mapValues { try annotate($0, owner: owner) })
        default: return value
        }
    }
}
