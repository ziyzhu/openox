import Foundation

extension Conversation {
    var appFilesAvailable: Bool {
        let path = scope.root.appendingPathComponent("app").path
        return !FileManager.default.fileExists(atPath: path) && (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil
    }

    func appFileBackend(operation: String, path: String, arguments: JSONValue,
                        requestedOperation: String, requestedPath: String) async throws -> JSONValue {
        guard appFilesAvailable, path == "app" || path.hasPrefix("app/"),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw RuntimeError.bridge("The app mount is unavailable or its path is invalid")
        }
        let files = ["settings.json", "providers.json", "services.json", "policy.json", "status.json", "logs.jsonl"]
        let directory = path == "app" || path == "app/actions"
        let action = try appFileAction(path)
        guard directory || files.contains(String(path.dropFirst(4))) || action != nil else {
            return .object(["error": .object(["code": .string("not_found"), "message": .string("App file not found")])])
        }
        func info(_ path: String, directory: Bool = false) -> JSONValue {
            .object(["path": .string(path), "name": .string(path.split(separator: "/").last.map(String.init) ?? path),
                     "kind": .string(directory ? "directory" : "file"), "size": .int(0), "mtimeMs": .int(0)])
        }
        let value: JSONValue
        switch operation {
        case "info":
            value = info(path, directory: directory)
        case "list":
            guard directory else { throw RuntimeError.bridge("Not an app directory: \(path)") }
            if path == "app" {
                value = .array(files.map { info("app/\($0)") } + [info("app/actions", directory: true)])
            } else {
                let actions = Set(Actions.builtIn).union(serviceManager.actionPolicies.actions.keys).sorted()
                guard actions.count <= 1_000 else { throw RuntimeError.bridge("Action inventory exceeds the listing limit; read an exact encoded action path") }
                value = .array(actions.map { info("app/actions/\(Self.appActionFilename($0))") })
            }
        case "read":
            guard !directory else { throw RuntimeError.bridge("Cannot read an app directory") }
            if path == "app/logs.jsonl", requestedPath != path {
                throw RuntimeError.bridge("Read or search app/logs.jsonl explicitly; app-wide logs are excluded from directory searches")
            }
            let text = try await appFileText(path: path, action: action)
            guard text.utf8.count <= 32 * 1024 * 1024 else { throw RuntimeError.bridge("App file exceeds the read safety limit") }
            if ["app/settings.json", "app/providers.json", "app/services.json"].contains(path), requestedOperation == "read" {
                appFileRevisions[path] = text
            }
            value = .object(["text": .string(text), "truncated": .bool(false), "unsupported": .null])
        case "write":
            try requireProfileMutation(requestedOperation == "edit" ? Actions.fsEdit : Actions.fsWrite)
            guard ["write", "edit"].contains(requestedOperation),
                  ["app/settings.json", "app/providers.json", "app/services.json"].contains(path) else {
                throw OxFunctionError(code: "permission_denied", message: "This app file is read-only.", recovery: "Inspect its current contents; use trusted Settings controls for protected preferences. Do not bypass file permissions.")
            }
            guard let content = arguments.objectValue?["content"]?.stringValue else {
                throw OxFunctionError(code: "invalid_argument", message: "App configuration requires UTF-8 JSON content.", recovery: "Use ox.fs.read, then ox.fs.edit with valid JSON. Binary configuration writes are unsupported.")
            }
            let expected = arguments.objectValue?["expected"]?.stringValue ?? appFileRevisions[path]
            guard let expected else { throw RuntimeError.bridge("Read the app file before replacing it; prefer ox.fs.edit") }
            try await writeAppFile(path: path, content: content, expected: expected)
            appFileRevisions[path] = nil
            value = .null
        default:
            throw RuntimeError.bridge("App files do not support deletion, directory creation, moves, copies, or activation")
        }
        try Task.checkCancellation()
        return .object(["value": value])
    }

    private static func appActionFilename(_ action: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return (action.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + ".json"
    }

    private func appFileAction(_ path: String) throws -> String? {
        guard path.hasPrefix("app/actions/") else { return nil }
        let filename = String(path.dropFirst("app/actions/".count))
        guard filename.hasSuffix(".json"), let action = String(filename.dropLast(5)).removingPercentEncoding,
              !action.isEmpty, action.count <= 500, Self.appActionFilename(action) == filename else {
            throw RuntimeError.bridge("Use app/actions/<encodeURIComponent(action)>.json for an exact Action")
        }
        return action
    }

    private func appFileText(path: String, action: String? = nil) async throws -> String {
        let purpose = "Read app configuration"
        if let action {
            let query = try AppActionPolicyQuery(options: .object(["action": .string(action)]))
            try await requireApproval(action: Actions.appActionPolicies, defaultPolicy: Actions.defaultPolicy(for: Actions.appActionPolicies), purpose: purpose)
            return try Self.appConfigurationText(query.read(serviceManager.actionPolicies, actionDefaultPolicy: serviceManager.defaultPolicy(for: action)))
        }
        switch path {
        case "app/settings.json":
            try await requireApproval(action: Actions.appLanguage, defaultPolicy: Actions.defaultPolicy(for: Actions.appLanguage), purpose: purpose)
            return try Self.appConfigurationText(AppSettings.load())
        case "app/policy.json":
            try await requireApproval(action: Actions.appActionPolicies, defaultPolicy: Actions.defaultPolicy(for: Actions.appActionPolicies), purpose: purpose)
            return try Self.appConfigurationText(ActionPolicyConfiguration.load())
        case "app/providers.json":
            try await requireApproval(action: Actions.providerList, defaultPolicy: Actions.defaultPolicy(for: Actions.providerList), purpose: purpose)
            return try Self.appConfigurationText(ProviderCatalog.load())
        case "app/services.json":
            return try Self.appConfigurationText(ServicePreferences.load())
        case "app/status.json":
            let info = try await appInfo(purpose: purpose)
            let profiles = try await appProfiles(purpose: purpose)
            let notifications = try await appNotifications(purpose: purpose)
            let language = try await appLanguage(purpose: purpose)
            let model = try await appDefaultModel(purpose: purpose)
            let repositories = try await appRepositories(purpose: purpose)
            return try Self.appConfigurationText(JSONValue.object([
                "app": info ?? .null, "profiles": profiles ?? .null,
                "notifications": notifications ?? .null, "language": language ?? .null,
                "defaultModel": model ?? .null, "repositories": repositories ?? .null,
                "host": .object(["allowConnections": .bool(try HostConfiguration.load().allowConnections)]),
            ]))
        case "app/logs.jsonl":
            try await requireApproval(action: Actions.appLogs, defaultPolicy: .ask, purpose: "Read app-wide diagnostic logs")
            let snapshot = try await LogFile.shared.snapshot()
            return try await Task.detached(priority: .userInitiated) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var text = ""
                for entry in snapshot {
                    try Task.checkCancellation()
                    let message = LogPrivacy.text(entry.message, limit: Int.max)
                    let scalars = message.unicodeScalars.prefix(2_049)
                    text += JSONValue.object([
                        "timestamp": .string(formatter.string(from: entry.date)),
                        "level": .string(entry.level.name), "category": .string(entry.category),
                        "message": .string(String(String.UnicodeScalarView(scalars.prefix(2_048)))), "truncated": .bool(scalars.count > 2_048),
                    ]).jsonString() + "\n"
                    guard text.utf8.count <= 32 * 1024 * 1024 else { throw RuntimeError.bridge("Diagnostic view exceeds its safety limit") }
                }
                return text
            }.value
        default:
            throw RuntimeError.bridge("App file not found")
        }
    }

    private static func appConfigurationText<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }

    private func writeAppFile(path: String, content: String, expected: String) async throws {
        guard content.utf8.count <= 200 * 1024,
              let fields = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8)).objectValue else {
            throw RuntimeError.bridge("App configuration must be a bounded JSON object")
        }
        guard try await appFileText(path: path) == expected else {
            throw OxFunctionError(code: "file_changed", message: "App configuration changed after reading.", recovery: "Read the file again and rebuild the edit from its current contents.")
        }
        switch path {
        case "app/settings.json":
            guard Set(fields.keys) == ["format", "language"] else { throw RuntimeError.bridge("Unsupported app settings fields") }
            let next = try JSONDecoder().decode(AppSettings.self, from: Data(content.utf8))
            try next.validate()
            guard let language = AppLocale.Language(rawValue: next.language) else { throw RuntimeError.bridge("Unsupported language") }
            try await requireApproval(action: Actions.appSetLanguage, defaultPolicy: Actions.defaultPolicy(for: Actions.appSetLanguage),
                                      args: ["selection": next.language], purpose: "Change Ox language")
            guard try Self.appConfigurationText(AppSettings.load()) == expected else { throw RuntimeError.bridge("App settings changed during approval") }
            try Task.checkCancellation()
            try AppLocale.shared.setLanguage(language)
        case "app/providers.json":
            guard Set(fields.keys).isSubset(of: ["format", "providers", "defaultModel"]) else { throw RuntimeError.bridge("Unsupported provider configuration fields") }
            if let selection = fields["defaultModel"]?.objectValue,
               !Set(selection.keys).isSubset(of: ["providerID", "modelID", "reasoningEffort"]) {
                throw RuntimeError.bridge("Unsupported default-model fields")
            }
            for definition in fields["providers"]?.arrayValue ?? [] { _ = try ProviderDefinition.decode(definition) }
            let next = try JSONDecoder().decode(ProviderCatalog.self, from: Data(content.utf8))
            try next.validate()
            try await replaceAppProviderCatalog(next, expected: expected)
        case "app/services.json":
            guard Set(fields.keys) == ["format", "names", "saved"] else { throw RuntimeError.bridge("Unsupported service preference fields") }
            let next = try JSONDecoder().decode(ServicePreferences.self, from: Data(content.utf8))
            try next.validate()
            let current = try ServicePreferences.load()
            guard Set(next.saved).subtracting(current.saved).allSatisfy({ serviceManager.service(domain: $0) != nil }),
                  Set(next.names.keys).subtracting(current.names.keys).allSatisfy({ serviceManager.service(domain: $0) != nil }) else {
                throw RuntimeError.bridge("New service preferences must refer to existing services")
            }
            try Task.checkCancellation()
            try serviceManager.replaceServicePreferences(next)
        default:
            throw RuntimeError.bridge("App file is read-only")
        }
    }

    private func replaceAppProviderCatalog(_ next: ProviderCatalog, expected: String) async throws {
        let current = try ProviderCatalog.load()
        let removed = current.providers.filter { old in !next.providers.contains(where: { $0.id == old.id }) }
        let changed = next.providers.filter { definition in !current.providers.contains(definition) }
        guard next.defaultModel == current.defaultModel || next.providers == current.providers else {
            throw RuntimeError.bridge("Edit provider definitions and the default model in separate writes")
        }
        try ProviderRegistry.shared.validateReplacement(next, expected: current)
        if !removed.isEmpty {
            try await requireApproval(action: Actions.providerDelete, defaultPolicy: Actions.defaultPolicy(for: Actions.providerDelete),
                                      args: ["providers": removed.map(\.id)], purpose: "Remove provider definitions")
        }
        if !changed.isEmpty {
            try await requireApproval(action: Actions.providerSave, defaultPolicy: Actions.defaultPolicy(for: Actions.providerSave),
                                      args: ["providers": changed.map { try $0.json.toAny() }], purpose: "Update provider definitions")
        }
        if next.defaultModel != current.defaultModel {
            try await requireApproval(action: Actions.appSetDefaultModel, defaultPolicy: Actions.defaultPolicy(for: Actions.appSetDefaultModel),
                                      args: next.defaultModel?.appInformation.toAny(), purpose: "Change default model")
        }
        guard try Self.appConfigurationText(ProviderCatalog.load()) == expected else { throw RuntimeError.bridge("Provider configuration changed during approval") }
        try Task.checkCancellation()
        try ProviderRegistry.shared.replaceConfiguration(next, expected: current)
    }
}
