import Foundation

nonisolated enum OxFunctionCatalog {
    private static let namespaceDescriptions: [(String, String)] = [
        ("app", "Inspect Ox's identity and current setup, and keep the current chat named."),
        ("service", "Discover, attach, detach, and invoke services."),
        ("user", "Keep the user informed and ask them to choose."),
        ("web", "Search and fetch the public web."),
        ("fs", "List, read, write, edit, delete, and search Ox files."),
        ("output", "Retrieve complete captured JavaScript output."),
        ("skill", "Create, copy, and delete Profile-owned skills."),
        ("artifact", "Attach content, import files, rename artifacts, and show existing artifacts."),
        ("widget", "Display structured content in the conversation."),
    ]

    static let all: [OxFunction] = [
        OxAppInformation.function,
        OxActions.function,
        OxWeb.function,
        OxServices.function,
        OxUser.function,
        OxFileSystem.function,
        OxOutput.function,
        OxSkills.function,
        OxArtifacts.function,
        OxWidgets.function,
    ]

    private static let catalogEntries: [(String, JSONValue)] =
        all.flatMap { $0.schema() }.map { name, schema in
            (name, closeInputSchema(schema))
        }

    private static let catalog = Dictionary(uniqueKeysWithValues: catalogEntries)

    private static func closeInputSchema(_ value: JSONValue) -> JSONValue {
        guard case .object(var entry) = value,
              case .object(var input)? = entry["inputSchema"],
              input["type"]?.stringValue == "object" else { return value }
        var properties = input["properties"]?.objectValue ?? [:]
        properties["purpose"] = .object([
            "type": .string("string"),
            "minLength": .int(1),
            "maxLength": .int(80),
            "description": .string("Short (<10 words) description shown to the user as the step label."),
        ])
        var required = input["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !required.contains("purpose") { required.append("purpose") }
        input["properties"] = .object(properties)
        input["required"] = .array(required.map(JSONValue.string))
        input["additionalProperties"] = .bool(false)
        entry["inputSchema"] = .object(input)
        return .object(entry)
    }

    static func build() -> JSONValue {
        return .object(catalog)
    }

    static func buildHelpText() -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: catalogEntries.map { name, schema in
            (name, .string(helpText(name: name, schema: schema)))
        }))
    }

    static func helpTree() -> String {
        let catalog = catalogEntries
        var lines = ["ox"]
        let rootHelpers = catalog.compactMap { name, schema -> (String, String)? in
            guard name.dropFirst("ox.".count).contains(".") == false,
                  let description = compactDescription(name: name, schema: schema, includesUsage: true) else { return nil }
            return (name, description)
        }.sorted { $0.0 < $1.0 }
        for helper in rootHelpers {
            lines.append("├── \(helper.0) — \(helper.1)")
        }
        for (namespaceIndex, namespace) in namespaceDescriptions.enumerated() {
            let isLastNamespace = namespaceIndex == namespaceDescriptions.count - 1
            lines.append("\(isLastNamespace ? "└──" : "├──") \(namespace.0) — \(namespace.1)")
            let prefix = isLastNamespace ? "    " : "│   "
            let helpers = catalog.compactMap { name, schema -> (String, String)? in
                let namespacePrefix = "ox.\(namespace.0)."
                guard name.hasPrefix(namespacePrefix),
                      let description = compactDescription(name: name, schema: schema, includesUsage: true) else { return nil }
                return (String(name.dropFirst(namespacePrefix.count)), description)
            }.sorted { $0.0 < $1.0 }
            for (helperIndex, helper) in helpers.enumerated() {
                let branch = helperIndex == helpers.count - 1 ? "└──" : "├──"
                lines.append("\(prefix)\(branch) ox.\(namespace.0).\(helper.0) — \(helper.1)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func compactDescription(name: String, schema: JSONValue, includesUsage: Bool = false) -> String? {
        guard case .object(let fields) = schema,
              let description = fields["description"]?.stringValue else { return nil }
        let oneLine = description
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let summary: String
        var usageText: String?
        if let usage = oneLine.range(of: ": `") {
            summary = String(oneLine[..<usage.lowerBound])
            if includesUsage,
               let end = oneLine[usage.upperBound...].firstIndex(of: "`") {
                usageText = String(oneLine[usage.upperBound..<end])
            }
        } else {
            let endings = [". ", "? ", "! "].compactMap { oneLine.range(of: $0)?.lowerBound }
            summary = endings.min().map { String(oneLine[...$0]) } ?? oneLine
        }
        let sentence = summary.last.map { ".?!".contains($0) } == true ? summary : "\(summary)."
        return usageText.map { "\(sentence) `\($0)`" } ?? sentence
    }

    private static func helpText(name: String, schema: JSONValue) -> String {
        guard let fields = schema.objectValue else { return name }
        var sections = [name]
        if let description = fields["description"]?.stringValue {
            sections.append(description.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        }
        if let input = fields["inputSchema"] {
            sections.append(schemaText(label: "input", value: input))
        }
        if let output = fields["outputSchema"] {
            sections.append(schemaText(label: "output", value: output))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func schemaText(label: String, value: JSONValue) -> String {
        schemaLines(label: label, value: value, required: true, depth: 0).joined(separator: "\n")
    }

    private static func schemaLines(
        label: String,
        value: JSONValue,
        required: Bool,
        depth: Int
    ) -> [String] {
        guard let fields = value.objectValue else {
            return ["\(String(repeating: "  ", count: depth))\(label): \(value.jsonString(fallback: "unknown"))"]
        }
        let optional = required ? "" : "?"
        let indentation = String(repeating: "  ", count: depth)
        var lines = ["\(indentation)\(label)\(optional): \(schemaSummary(fields))"]
        guard fields["enum"] == nil, fields["const"] == nil else { return lines }

        if let properties = fields["properties"]?.objectValue {
            let requiredKeys = fields["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let requiredSet = Set(requiredKeys)
            let keys = requiredKeys + properties.keys.filter { !requiredSet.contains($0) }.sorted()
            for key in keys {
                guard let property = properties[key] else { continue }
                lines.append(contentsOf: schemaLines(
                    label: key,
                    value: property,
                    required: requiredSet.contains(key),
                    depth: depth + 1
                ))
            }
        }
        if let additional = fields["additionalProperties"], additional.objectValue != nil {
            lines.append(contentsOf: schemaLines(label: "*", value: additional, required: true, depth: depth + 1))
        }
        if let items = fields["items"], items.objectValue != nil {
            lines.append(contentsOf: schemaLines(label: "items", value: items, required: true, depth: depth + 1))
        }
        return lines
    }

    private static func schemaSummary(_ fields: [String: JSONValue]) -> String {
        var summary: String
        if let values = fields["enum"]?.arrayValue {
            summary = values.map { $0.jsonString(fallback: "unknown") }.joined(separator: " | ")
        } else if let value = fields["const"] {
            summary = value.jsonString(fallback: "unknown")
        } else if let types = fields["type"]?.arrayValue {
            summary = types.compactMap(\.stringValue).joined(separator: " | ")
        } else {
            summary = fields["type"]?.stringValue ?? "value"
        }
        if summary == "object", fields["additionalProperties"]?.boolValue == false {
            summary = "exact object"
        }
        let constraints = schemaConstraints(fields)
        if !constraints.isEmpty { summary += " [\(constraints.joined(separator: ", "))]" }
        if let description = fields["description"]?.stringValue {
            let compact = description.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !compact.isEmpty { summary += " — \(compact)" }
        }
        return summary
    }

    private static func schemaConstraints(_ fields: [String: JSONValue]) -> [String] {
        var constraints: [String] = []
        if fields["minLength"] != nil || fields["maxLength"] != nil {
            constraints.append("chars \(range(fields["minLength"], fields["maxLength"]))")
        }
        if fields["minItems"] != nil || fields["maxItems"] != nil {
            constraints.append("items \(range(fields["minItems"], fields["maxItems"]))")
        }
        if fields["minimum"] != nil || fields["maximum"] != nil {
            constraints.append(range(fields["minimum"], fields["maximum"]))
        }
        if fields["uniqueItems"]?.boolValue == true { constraints.append("unique") }
        return constraints
    }

    private static func range(_ minimum: JSONValue?, _ maximum: JSONValue?) -> String {
        let lower = minimum.map { $0.jsonString(fallback: "") } ?? ""
        let upper = maximum.map { $0.jsonString(fallback: "") } ?? ""
        return "\(lower)..\(upper)"
    }

}
