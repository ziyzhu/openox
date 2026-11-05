import Foundation

nonisolated enum RemoteMCPAttachments {
    static let maximumBytes = 2 * 1_024 * 1_024
    static let maximumFiles = 4

    static func inputSchema(_ schema: JSONValue) -> JSONValue {
        guard var fields = schema.objectValue else { return schema }
        if fields["type"]?.stringValue == "string", fields["contentEncoding"]?.stringValue == "base64" {
            return .object([
                "description": .string("Explicit binary transfer: supply {path: \"artifacts/photo.png\"} to read an authorized Profile file or granted folder file and send its bytes to this MCP server. Never print or construct base64 in model text. At most four files and 2 MiB combined per call. " + (fields["description"]?.stringValue ?? "")),
                "anyOf": .array([schema, .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(4096)])]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ])]),
            ])
        }
        if let children = fields["properties"]?.objectValue { fields["properties"] = .object(children.mapValues(inputSchema)) }
        for key in ["items", "additionalProperties"] {
            if let child = fields[key], child.objectValue != nil { fields[key] = inputSchema(child) }
        }
        for key in ["anyOf", "oneOf"] {
            if let children = fields[key]?.arrayValue { fields[key] = .array(children.map(inputSchema)) }
        }
        return .object(fields)
    }

    @MainActor
    static func arguments(
        _ value: JSONValue,
        schema: JSONValue,
        readFile: (String) async throws -> Data
    ) async throws -> JSONValue {
        var count = 0
        var bytes = 0
        func encode(_ value: JSONValue, schema: JSONValue, depth: Int) async throws -> JSONValue {
            guard depth < 64 else { throw RemoteMCPError.protocolError("attachment input is too deeply nested") }
            guard let fields = schema.objectValue else { return value }
            if fields["type"]?.stringValue == "string", fields["contentEncoding"]?.stringValue == "base64", let reference = value.objectValue {
                guard reference.count == 1, let path = reference["path"]?.stringValue, !path.isEmpty else {
                    throw RemoteMCPError.protocolError("binary file references require only a path")
                }
                count += 1
                guard count <= maximumFiles else { throw RemoteMCPError.protocolError("at most four file transfers per call") }
                let data = try await readFile(path)
                bytes += data.count
                guard !data.isEmpty, bytes <= maximumBytes else { throw RemoteMCPError.protocolError("file transfers exceed the combined 2 MiB limit or contain an empty file") }
                return .string(data.base64EncodedString())
            }
            for key in ["anyOf", "oneOf"] {
                if let variants = fields[key]?.arrayValue,
                   let selected = variants.first(where: { JSONSchemaValidator.validate(value, against: inputSchema($0), definitions: [:]).isEmpty }) {
                    return try await encode(value, schema: selected, depth: depth + 1)
                }
            }
            if let children = value.objectValue {
                let properties = fields["properties"]?.objectValue ?? [:]
                var result = children
                for (key, child) in children {
                    if let childSchema = properties[key] ?? fields["additionalProperties"], childSchema.objectValue != nil {
                        result[key] = try await encode(child, schema: childSchema, depth: depth + 1)
                    }
                }
                return .object(result)
            }
            if let children = value.arrayValue, let childSchema = fields["items"] {
                var result: [JSONValue] = []
                for child in children { result.append(try await encode(child, schema: childSchema, depth: depth + 1)) }
                return .array(result)
            }
            return value
        }
        return try await encode(value, schema: schema, depth: 0)
    }
}
