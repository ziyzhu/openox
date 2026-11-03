import Foundation

extension Conversation {
    public func searchWeb(arguments: JSONValue, purpose: String) async throws -> JSONValue? {
        let options = arguments.objectValue ?? [:]
        let query = options["query"]?.stringValue ?? ""
        let services = options["services"]?.arrayValue?.compactMap(\.stringValue)
            ?? ["web:search.brave.com", "web:duckduckgo.com", "web:google.com"]
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OxSearch.failure("invalid_argument", "Search query must not be blank.")
        }
        guard services.allSatisfy({ $0.range(of: "^web:[a-z0-9.-]+$", options: .regularExpression) != nil }) else {
            throw OxSearch.failure("invalid_argument", "Use a qualified web service ID.")
        }
        for field in ["cursors", "sessions"] {
            let values = options[field]?.objectValue ?? [:]
            guard values.keys.allSatisfy(services.contains) else {
                throw OxSearch.failure("invalid_argument", "\(field) contains an unselected service.")
            }
            let schema: JSONValue = field == "sessions" ? WebSessionContract.sessionSchema
                : .object(["type": .string("string"), "minLength": .int(1)])
            for value in values.values {
                let issues = JSONSchemaValidator.validate(value, against: schema, definitions: [:])
                guard issues.isEmpty else { throw OxSearch.failure("invalid_argument", "\(field): \(issues)") }
            }
        }
        var recorded = options
        recorded["services"] = .array(services.map(JSONValue.string))
        return try await tracked(Actions.webSearch, .object(recorded), purpose: purpose, groupsCalls: true) {
            let outcomes = try await withThrowingTaskGroup(of: (Int, Result<JSONValue, OxFunctionError>).self) { group in
                for (index, service) in services.enumerated() {
                    group.addTask {
                        do {
                            return (index, .success(try await self.searchPage(service: service, options: options, purpose: purpose)))
                        } catch {
                            let failure = OxFunctionError.from(error)
                            if ["cancelled", "permission_denied", "handoff_incomplete"].contains(failure.code) { throw error }
                            Log.session.warning("bridge.web.search service=\(service) code=\(failure.code) error=\(LogPrivacy.text(error.localizedDescription))")
                            return (index, .failure(failure))
                        }
                    }
                }
                var outcomes = [Result<JSONValue, OxFunctionError>?](repeating: nil, count: services.count)
                for try await (index, outcome) in group { outcomes[index] = outcome }
                return outcomes
            }
            var results: [JSONValue] = []
            var errors: [JSONValue] = []
            for (service, outcome) in zip(services, outcomes) {
                switch outcome {
                case .success(let page): results.append(page)
                case .failure(let failure): errors.append(.object(["service": .string(service), "code": .string(failure.code), "message": .string(failure.message)]))
                case nil: break
                }
            }
            guard !results.isEmpty else {
                let message = errors.compactMap { error -> String? in
                    guard let fields = error.objectValue else { return nil }
                    return "\(fields["service"]?.stringValue ?? ""): \(fields["code"]?.stringValue ?? ""): \(fields["message"]?.stringValue ?? "")"
                }.joined(separator: "; ")
                throw OxFunctionError(code: "all_searches_failed", message: message, recovery: "Inspect each service failure. Do not report that no matches exist.")
            }
            return .object(["query": .string(query), "results": .array(results), "errors": .array(errors)])
        }
    }

    private func searchPage(service: String, options: [String: JSONValue], purpose: String) async throws -> JSONValue {
        let domain = String(service.dropFirst(4))
        guard let target = serviceManager.service(domain: domain), target.isWebService else {
            throw OxSearch.failure("search_unsupported", "\(service) is not an available web service.")
        }
        try await serviceManager.requireRepositoryAccess(for: target)
        guard await target.loadManifest(reason: .inspect) != nil else {
            throw OxSearch.failure("operation_failed", "\(service) capabilities are unavailable.")
        }
        guard target.definition.exposedActions.contains(where: { $0.id == "search" }),
              let action = OxActions.detail(definition: target.definition, id: "search")?.objectValue else {
            throw OxSearch.failure("search_unsupported", "\(service) does not expose standard search.")
        }
        let input = try OxSearch.searchInput(action: action, service: service)
        guard action["requireApproval"]?.boolValue != true else {
            throw OxSearch.failure("invalid_contract", "Standard search must be read-only and requireApproval must be false.")
        }
        let session = options["sessions"]?.objectValue?[service]
        guard action["requireAuth"]?.boolValue != true || session != nil else {
            throw OxSearch.failure("authentication_required", "\(service) requires an authenticated session. Select a session or sign in before searching.")
        }
        guard let maximum = input.objectValue?["properties"]?.objectValue?["limit"]?.objectValue?["maximum"]?.intValue,
              (1...50).contains(maximum) else {
            throw OxSearch.failure("invalid_contract", "Search limit must declare a maximum from 1 to 50.")
        }
        let limit = min(options["limit"]?.intValue ?? 10, maximum)
        let cursor = options["cursors"]?.objectValue?[service]
        var args: [String: JSONValue] = ["query": options["query"] ?? .null, "limit": .int(limit)]
        args["cursor"] = cursor
        let issues = JSONSchemaValidator.validate(.object(args), against: input, definitions: [:])
        guard issues.isEmpty else { throw OxSearch.failure("invalid_argument", "\(issues)") }
        let page = try await serviceOperations.invokeAction(service: target, actionID: "search", args: .object(args), session: session, purpose: purpose)
        var result = page?.objectValue ?? [:]
        result["service"] = .string(service)
        let invalid = JSONSchemaValidator.validate(.object(result), against: OxSearch.resultSchema, definitions: [:])
        guard invalid.isEmpty, let items = result["items"]?.arrayValue, items.count <= limit,
              result["nextCursor"] == .null || result["coverage"] == .string("partial") else {
            throw OxSearch.failure("invalid_output", "Search returned invalid results, too many items, or inconsistent coverage: \(invalid)")
        }
        guard cursor == nil || result["nextCursor"] != cursor else {
            throw OxSearch.failure("invalid_output", "Search cursor did not advance.")
        }
        guard try JSONEncoder().encode(JSONValue.object(result)).count <= 1_000_000 else {
            throw OxSearch.failure("resource_limit", "Search page exceeds the bounded response size.")
        }
        return .object(result)
    }
}

extension OxSearch {
    static func failure(_ code: String, _ message: String) -> OxFunctionError {
        OxFunctionError(code: code, message: message, recovery: "Inspect the service search contract before retrying.")
    }

    private static func expanded(_ schema: JSONValue?, definitions: [String: JSONValue], depth: Int = 0) throws -> JSONValue {
        guard depth <= 12 else { throw failure("invalid_contract", "Search schema reference is too deep.") }
        guard let reference = schema?.objectValue?["$ref"]?.stringValue else { return schema ?? .null }
        guard reference.hasPrefix("#/$defs/") else {
            throw failure("invalid_contract", "Search schema uses an unsupported reference.")
        }
        guard let target = definitions[String(reference.dropFirst(8))] else {
            throw failure("invalid_contract", "Search schema reference is missing.")
        }
        return try expanded(target, definitions: definitions, depth: depth + 1)
    }

    static func searchInput(action: [String: JSONValue], service: String) throws -> JSONValue {
        let input = try expanded(action["inputSchema"], definitions: action["inputSchema"]?.objectValue?["$defs"]?.objectValue ?? [:])
        let outputDefinitions = action["outputSchema"]?.objectValue?["$defs"]?.objectValue ?? [:]
        let output = try expanded(action["outputSchema"], definitions: outputDefinitions)
        let inputFields = input.objectValue ?? [:]
        let inputProperties = inputFields["properties"]?.objectValue ?? [:]
        let required = inputFields["required"]?.arrayValue ?? []
        let outputFields = output.objectValue ?? [:]
        guard inputFields["type"] == .string("object"), inputFields["additionalProperties"] == .bool(false),
              required.contains(.string("query")), required.allSatisfy({ $0 == .string("query") }),
              inputProperties["query"]?.objectValue?["type"] == .string("string"),
              inputProperties["limit"]?.objectValue?["type"] == .string("integer"),
              inputProperties["cursor"]?.objectValue?["type"] == .string("string"),
              inputProperties.keys.allSatisfy({ ["query", "limit", "cursor"].contains($0) }),
              outputFields["type"] == .string("object"),
              ["items", "nextCursor", "scope", "coverage"].allSatisfy({ outputFields["required"]?.arrayValue?.contains(.string($0)) == true }) else {
            throw failure("invalid_contract", "\(service):search does not implement the standard search contract.")
        }
        let properties = outputFields["properties"]?.objectValue ?? [:]
        let item = try expanded(properties["items"]?.objectValue?["items"], definitions: outputDefinitions).objectValue ?? [:]
        func types(_ schema: JSONValue?, _ expected: [JSONValue]) throws -> Bool {
            let type = try expanded(schema, definitions: outputDefinitions).objectValue?["type"]
            let actual = type?.arrayValue ?? type.map { [$0] } ?? []
            return actual.count == expected.count && expected.allSatisfy(actual.contains)
        }
        guard outputFields["additionalProperties"] == .bool(false),
              try types(properties["items"], [.string("array")]),
              try types(properties["nextCursor"], [.string("string"), .string("null")]),
              try types(properties["scope"], [.string("string")]),
              try types(properties["coverage"], [.string("string")]),
              ["complete", "partial", "unknown"].allSatisfy({ properties["coverage"]?.objectValue?["enum"]?.arrayValue?.contains(.string($0)) == true }),
              item["type"] == .string("object"), item["additionalProperties"] == .bool(false),
              ["title", "url", "snippet"].allSatisfy({ item["required"]?.arrayValue?.contains(.string($0)) == true }),
              try types(item["properties"]?.objectValue?["title"], [.string("string")]),
              try types(item["properties"]?.objectValue?["url"], [.string("string"), .string("null")]),
              try types(item["properties"]?.objectValue?["snippet"], [.string("string"), .string("null")]) else {
            throw failure("invalid_contract", "\(service):search does not declare standard search results.")
        }
        return input
    }
}
