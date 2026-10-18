#if DEBUG && targetEnvironment(simulator)
import Foundation

@MainActor
enum DeviceTemplate {
    struct Request: Decodable {
        struct Settings: Decodable {
            let language: String?
            let onboardingCompleted: Bool?
            let region: String?
            let defaultModel: JSONValue?
            let allowHostConnections: Bool?

            private enum CodingKeys: String, CodingKey {
                case language, onboardingCompleted, region, defaultModel, allowHostConnections
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                language = try values.decodeIfPresent(String.self, forKey: .language)
                onboardingCompleted = try values.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)
                region = try values.decodeIfPresent(String.self, forKey: .region)
                defaultModel = values.contains(.defaultModel) ? try values.decode(JSONValue.self, forKey: .defaultModel) : nil
                allowHostConnections = try values.decodeIfPresent(Bool.self, forKey: .allowHostConnections)
            }
        }
        struct Defaults: Decodable {
            let set: [String: JSONValue]?
            let remove: [String]?
        }
        struct DefaultsDomains: Decodable {
            let app: Defaults?
            let appGroup: Defaults?
        }
        struct Keychain: Decodable {
            struct Provider: Decodable { let provider: String; let value: String }
            struct Entry: Decodable { let account: String; let value: String }
            struct NamedSecret: Decodable { let key: String; let name: String; let value: String }
            let providers: [Provider]?
            let entries: [Entry]?
            let secrets: [NamedSecret]?
            let bindings: [SecretBinding]?
            let removeProviders: [String]?
            let removeSecrets: [String]?
            let removeAccounts: [String]?
        }
        struct File: Decodable { let path: String; let data: Data }
        struct ProfileInput: Decodable {
            let id: String
            let name: String
            let memory: String?
            let soul: String?
            let files: [File]?
            let conversations: [Conversation]?

            private enum CodingKeys: String, CodingKey {
                case id, name, memory, soul, files
                case conversations = "chats"
            }
        }
        struct Conversation: Decodable {
            struct File: Decodable { let id: String; let name: String; let data: Data }
            struct Message: Decodable {
                let role: String
                let text: String
                let reasoning: String?
                let attachments: [String]?
            }
            let id: String
            let title: String
            let model: JSONValue?
            let favorite: Bool?
            let unread: Bool?
            let messages: [Message]?
            let packageData: Data?
            let files: [File]?
        }
        struct WebsiteState: Decodable { let data: Data }
        struct Selection: Decodable {
            let profile: String
            let conversation: String?

            private enum CodingKeys: String, CodingKey {
                case profile
                case conversation = "chat"
            }
        }
        let version: Int
        let runID: UUID
        let settings: Settings?
        let userDefaults: DefaultsDomains?
        let keychain: Keychain?
        let profiles: [ProfileInput]?
        let websiteState: WebsiteState?
        let selection: Selection?
    }

    private enum State {
        case inactive
        case prepared(Request)
        case imported(Request)
        case finished
        case failed(Error)
    }

    private static var state: State = .inactive
    private static var profiles: [String: Profile] = [:]
    private static var conversationIDs: [String: [String: UUID]] = [:]
    private static var controlDirectory: URL?

    static func preparePreferences() {
        guard let token = ProcessInfo.processInfo.environment["OX_DEVICE_TEMPLATE"], let id = UUID(uuidString: token) else { return }
        do {
            let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("DeviceTemplates/\(id.uuidString)", isDirectory: true)
            controlDirectory = directory
            let input = directory.appendingPathComponent("input.json")
            let data = try Data(contentsOf: input)
            guard data.count <= 192 * 1024 * 1024 else { throw RuntimeError.bridge("Template exceeds size limit") }
            let decoded = try JSONDecoder().decode(Request.self, from: data)
            guard decoded.version == 1, decoded.runID == id else { throw RuntimeError.bridge("Unsupported template version or identity") }
            state = .prepared(decoded)
            try FileManager.default.removeItem(at: input)
            guard let group = UserDefaults(suiteName: AppStoragePaths.appGroupIdentifier) else { throw RuntimeError.bridge("App-group preferences unavailable") }
            var appKeys = Array(decoded.userDefaults?.app?.set?.keys ?? Dictionary<String, JSONValue>().keys) + (decoded.userDefaults?.app?.remove ?? [])
            let groupKeys = Array(decoded.userDefaults?.appGroup?.set?.keys ?? Dictionary<String, JSONValue>().keys) + (decoded.userDefaults?.appGroup?.remove ?? [])
            if decoded.selection != nil { appKeys.append("storage.activeProfile") }
            if let settings = decoded.settings {
                if settings.language != nil { appKeys.append("app.language") }
                if settings.onboardingCompleted != nil { appKeys.append("app.hasCompletedOnboarding") }
                if settings.region != nil { appKeys.append("app.region") }
                if settings.defaultModel != nil { appKeys.append(ProviderRegistry.defaultModelKey) }
                if settings.allowHostConnections != nil { appKeys.append(HostAccess.preferenceKey) }
            }
            let previous: [String: Any] = ["app": originalDefaults(appKeys, from: .standard), "appGroup": originalDefaults(groupKeys, from: group)]
            try PropertyListSerialization.data(fromPropertyList: previous, format: .binary, options: 0)
                .write(to: directory.appendingPathComponent("preferences-before.plist"), options: .atomic)
            try applyDefaults(decoded.userDefaults?.app, to: .standard)
            try applyDefaults(decoded.userDefaults?.appGroup, to: group)
            if let settings = decoded.settings {
                if let language = settings.language { UserDefaults.standard.set(language, forKey: "app.language") }
                if let value = settings.onboardingCompleted { UserDefaults.standard.set(value, forKey: "app.hasCompletedOnboarding") }
                if let region = settings.region, let value = LLMRegion(rawValue: region) { AppRegion.shared.setForTesting(value) }
                if let value = settings.allowHostConnections { UserDefaults.standard.set(value, forKey: HostAccess.preferenceKey) }
                if let value = settings.defaultModel {
                    if value == .null { UserDefaults.standard.removeObject(forKey: ProviderRegistry.defaultModelKey) }
                    else { UserDefaults.standard.set(try JSONEncoder().encode(model(value)), forKey: ProviderRegistry.defaultModelKey) }
                }
            }
            Log.app.info("DeviceTemplate.preferences applied run=\(id) appKeys=\(decoded.userDefaults?.app?.set?.count ?? 0) groupKeys=\(decoded.userDefaults?.appGroup?.set?.count ?? 0)")
        } catch {
            state = .failed(error)
            writeResult(status: "failed", error: "Template preferences could not be applied")
        }
    }

    static func reportFailure(_ error: Error) {
        guard controlDirectory != nil else { return }
        state = .failed(error)
        writeResult(status: "failed", error: "Template startup failed; inspect storage preparation logs")
    }

    static func applyStorage(services: ServiceManager) async throws {
        let request: Request
        switch state {
        case .prepared(let input): request = input
        case .failed(let error): throw error
        case .inactive, .imported, .finished: return
        }
        do {
            for provider in request.keychain?.removeProviders ?? [] {
                let definition = try ProviderRegistry.shared.definition(id: provider)
                try Secret.unbind(.provider, id: definition.credentialID)
            }
            for key in request.keychain?.removeSecrets ?? [] { try Secret.delete(key: key) }
            for account in request.keychain?.removeAccounts ?? [] { try Credentials.deleteSecretChecked(for: account) }
            for provider in request.keychain?.providers ?? [] {
                let definition = try ProviderRegistry.shared.definition(id: provider.provider)
                try Secret.saveProviderKey(provider.value, definition: definition)
            }
            for secret in request.keychain?.secrets ?? [] {
                try Secret.set(key: secret.key, displayName: secret.name, value: secret.value)
            }
            for binding in request.keychain?.bindings ?? [] { try Secret.bind(binding) }
            for entry in request.keychain?.entries ?? [] {
                guard ["secret:", "oauth:model-provider:", "oauth:mcp-service:", "oauth:api-service:"].contains(where: entry.account.hasPrefix) else {
                    throw RuntimeError.bridge("Unsupported Keychain account family")
                }
                try Credentials.setSecretChecked(entry.value, for: entry.account)
                guard try Credentials.secretChecked(for: entry.account) == entry.value else { throw RuntimeError.bridge("Credential verification failed") }
            }
            for input in request.profiles ?? [] {
                let name = input.name + " " + request.runID.uuidString.prefix(8)
                try await StorageRoot.shared.createProfile(name: name, location: .local)
                guard let profile = StorageRoot.shared.profiles.first(where: { $0.name == name }) else { throw RuntimeError.bridge("Created Profile unavailable") }
                profiles[input.id] = profile
                let scope = ProfileScope(profileID: profile.id, root: profile.url, location: .local)
                if let memory = input.memory { try await ProfileRepository.shared.writeTextFile(memory, named: "MEMORY.md", in: scope) }
                if let soul = input.soul { try await ProfileRepository.shared.writeTextFile(soul, named: "SOUL.md", in: scope) }
                for file in input.files ?? [] {
                    _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
                        "action": .string("fileWriteBinary"), "path": .string("/" + file.path), "base64": .string(file.data.base64EncodedString()),
                    ]))
                }
                for conversation in input.conversations ?? [] { conversationIDs[input.id, default: [:]][conversation.id] = try await importConversation(conversation, in: scope) }
                try await DurableProfileStore.shared.close(in: scope)
            }
            if let selection = request.selection, let profile = profiles[selection.profile] {
                UserDefaults.standard.set(profile.id.uuidString, forKey: "storage.activeProfile")
                try await StorageRoot.shared.resolve()
            }
            if let website = request.websiteState { try await services.restoreWebsiteData(website.data) }
            state = .imported(request)
            Log.app.info("DeviceTemplate.storage applied run=\(request.runID) profiles=\(profiles.count) conversations=\(conversationIDs.values.reduce(0) { $0 + $1.count }) websiteRestored=\(request.websiteState != nil)")
        } catch {
            state = .failed(error)
            writeResult(status: "failed", error: "Template storage application failed; inspect scoped device logs")
            throw error
        }
    }

    static func finish(conversations: ConversationManager) async throws {
        let request: Request
        switch state {
        case .imported(let input): request = input
        case .failed(let error): throw error
        case .inactive, .finished: return
        case .prepared: throw RuntimeError.bridge("Template storage must be imported before selection")
        }
        do {
            if let selection = request.selection, let conversation = selection.conversation,
               let id = conversationIDs[selection.profile]?[conversation] {
                _ = try await conversations.openForClient(id)
            }
            writeResult(status: "applied", error: nil)
            state = .finished
        } catch {
            state = .failed(error)
            writeResult(status: "failed", error: "Template selection could not be opened")
            throw error
        }
    }

    private static func importConversation(_ input: Request.Conversation, in scope: ProfileScope) async throws -> UUID {
        if let data = input.packageData {
            let proposal = try ConversationPackageCodec.decode(data, sourceName: "template.chat")
            let state = try await ProfileRepository.shared.importConversationPackage(proposal.payload, in: scope)
            return try await saveMetadata(input, state: state, in: scope)
        }
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("conversationCreate"), "title": .string(input.title),
            "metadata": .object(["createdAt": .double(Date().timeIntervalSinceReferenceDate), "attachedServiceDomains": .array([])]),
        ]))
        guard let value = result.objectValue?["reference"] else { throw RuntimeError.bridge("Conversation identity missing") }
        let reference = try JSONDecoder().decode(DurableConversationReference.self, from: JSONEncoder().encode(value))
        var files: [String: FileItem] = [:]
        for file in input.files ?? [] {
            files[file.id] = try await ProfileRepository.shared.importFile(data: file.data, suggestedName: file.name, in: scope, conversation: reference)
        }
        let turns = try (input.messages ?? []).map { message -> Turn in
            let at = Date()
            if message.role == "user" {
                let attachments = try (message.attachments ?? []).map { id in
                    guard let file = files[id] else { throw RuntimeError.bridge("Unknown attachment") }
                    return file
                }
                return .user(UserTurn(intent: message.text, attachments: attachments, at: at))
            }
            guard message.role == "assistant" else { throw RuntimeError.bridge("Unsupported message role") }
            let generation = AgentGenerationID()
            var steps: [Step] = []
            if let reasoning = message.reasoning { steps.append(Step(generation: generation, kind: .reasoning(reasoning))) }
            steps.append(Step(generation: generation, kind: .text(message.text)))
            return .agent(AgentTurn(at: at, generations: [ModelGeneration(id: generation, at: at, model: input.model?.objectValue?["model"]?.stringValue ?? "mock", outcome: .completed(at: at))], steps: steps, outcome: .completed(at: at)))
        }
        let alias = "ox-native:" + UUID().uuidString
        let entries = try turns.map { turn -> JSONValue in
            .object(["kind": .string("ox.native.turn"), "data": .object(["turn": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(turn))]),
                     "model": .array(ConversationProjection.makeWireMessages(from: [turn]).map { DurableMessageCodec.message($0, provider: alias, profileID: scope.profileID) })])
        }
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("conversationPopulate"), "reference": reference.value, "entries": .array(entries),
        ]))
        guard let loaded = await ProfileRepository.shared.loadConversation(reference.compatibilityID, in: scope)?.state else { throw RuntimeError.bridge("Seeded conversation unavailable") }
        return try await saveMetadata(input, state: loaded, in: scope)
    }

    private static func saveMetadata(_ input: Request.Conversation, state: ConversationState, in scope: ProfileScope) async throws -> UUID {
        var meta = state.meta
        meta.title = input.title
        meta.model = try input.model.map(model)
        meta.isFavorite = input.favorite ?? false
        meta.hasUnreadResponse = input.unread ?? false
        let saved = await ProfileRepository.shared.saveConversation(ConversationSaveRequest(payload: .metadata(meta)), in: scope)
        guard saved.succeeded else { throw RuntimeError.bridge("Seeded conversation metadata could not be saved") }
        return meta.id
    }

    private static func model(_ value: JSONValue) throws -> ModelSelection {
        guard let fields = value.objectValue, let provider = fields["provider"]?.stringValue, let model = fields["model"]?.stringValue else {
            throw RuntimeError.bridge("Invalid template model")
        }
        return ModelSelection(providerID: provider, modelID: model, reasoningEffort: fields["thinking"]?.stringValue)
    }

    private static func originalDefaults(_ keys: [String], from defaults: UserDefaults) -> [String: Any] {
        var values: [String: Any] = [:]
        var absent: [String] = []
        for key in Set(keys) {
            if let value = defaults.object(forKey: key) { values[key] = value }
            else { absent.append(key) }
        }
        return ["set": values, "remove": absent]
    }

    private static func applyDefaults(_ input: Request.Defaults?, to defaults: UserDefaults) throws {
        for (key, value) in input?.set ?? [:] { defaults.set(try propertyList(value), forKey: key) }
        for key in input?.remove ?? [] { defaults.removeObject(forKey: key) }
    }

    private static func propertyList(_ value: JSONValue) throws -> Any {
        switch value {
        case .string(let value): return value
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .array(let values): return try values.map(propertyList)
        case .object(let fields):
            if fields.count == 1, let value = fields["data"]?.stringValue, let data = Data(base64Encoded: value) { return data }
            if fields.count == 1, let value = fields["date"]?.stringValue, let date = ISO8601DateFormatter().date(from: value) { return date }
            if fields.count == 1, let value = fields["dictionary"]?.objectValue { return try value.mapValues(propertyList) }
            throw RuntimeError.bridge("Invalid property-list value")
        case .null: throw RuntimeError.bridge("Use remove to clear a preference")
        }
    }

    private static func writeResult(status: String, error: String?) {
        guard let directory = controlDirectory else { return }
        let value: JSONValue = .object([
            "status": .string(status), "error": error.map(JSONValue.string) ?? .null,
            "profiles": .object(profiles.mapValues { .string($0.id.uuidString) }),
            "chats": .object(conversationIDs.mapValues { .object($0.mapValues { .string($0.uuidString) }) }),
        ])
        do { try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("result.json"), options: .atomic) }
        catch { Log.app.error("DeviceTemplate.result write failed") }
    }
}
#endif
