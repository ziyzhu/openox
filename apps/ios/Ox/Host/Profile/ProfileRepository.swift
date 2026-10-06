import Foundation

actor ProfileRepository {
    static let shared = ProfileRepository()
    nonisolated let debugSaveGate = ProfileRepositorySaveGate()
    private var deleted: [ProfileScope: Set<ChatID>] = [:]

    nonisolated static func localDocuments() -> URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
    }

    nonisolated static func cloudDocuments() async -> URL? {
        #if targetEnvironment(simulator)
        guard !SimEnv.iCloudDisabled else { return nil }
        #endif
        return await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: AppConfiguration.iCloudContainerIdentifier)?.appendingPathComponent("Documents") }.value
    }

    nonisolated static func cleanName(_ name: String) -> String {
        let value = name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Default" : value
    }

    func renameProfile(_ profile: Profile, to name: String, base: URL) async throws -> Profile? {
        let destination = base.appendingPathComponent(Self.cleanName(name))
        guard destination != profile.url else { return nil }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProfileError.nameExists(name) }
        try await DurableProfileStore.shared.close(in: ProfileScope(profileID: profile.id, root: profile.url, location: profile.location))
        try FileManager.default.moveItem(at: profile.url, to: destination)
        var renamed = profile; renamed.name = destination.lastPathComponent; renamed.url = destination
        return renamed
    }

    func moveProfile(_ profile: Profile, to location: Profile.Location, base: URL) async throws -> Profile {
        guard location == .local else { throw RuntimeError.bridge("Export/import a closed Profile snapshot instead of synchronizing a live database") }
        let destination = base.appendingPathComponent(profile.name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ProfileError.nameExists(profile.name) }
        try await DurableProfileStore.shared.close(in: ProfileScope(profileID: profile.id, root: profile.url, location: profile.location))
        try FileManager.default.moveItem(at: profile.url, to: destination)
        var moved = profile; moved.url = destination; moved.location = location
        return moved
    }

    func deleteProfile(_ profile: Profile) async throws {
        try await DurableProfileStore.shared.close(in: ProfileScope(profileID: profile.id, root: profile.url, location: profile.location))
        try FileManager.default.removeItem(at: profile.url)
        deleted = deleted.filter { $0.key.profileID != profile.id }
    }

    func ensureLayout(in scope: ProfileScope) async {
        do { _ = try await DurableProfileStore.shared.session(in: scope) }
        catch { Log.app.error("ProfileRepository.open failed=\(error.localizedDescription)") }
    }

    func startDownloads(in scope: ProfileScope) { }

    func artifactsDirectory(in scope: ProfileScope) throws -> URL {
        try requireProfile(in: scope)
        return scope.root.appendingPathComponent("artifacts")
    }

    func skillsDirectory(in scope: ProfileScope) throws -> URL { throw RuntimeError.bridge("Skills are Pi documents, not a physical directory") }

    func file(named name: String, in scope: ProfileScope) throws -> URL {
        try requireProfile(in: scope)
        guard name == ProfileIO.configName else { throw RuntimeError.bridge("Profile documents are stored in Pi") }
        return scope.root.appendingPathComponent(name)
    }

    func readTextFile(named name: String, in scope: ProfileScope) async throws -> String? {
        let list = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("fileList"), "prefix": .string(name)]))
        guard let files = list.objectValue?["files"]?.arrayValue,
              files.allSatisfy({ $0.objectValue?["path"]?.stringValue != nil }) else { throw RuntimeError.bridge("Invalid Profile file index") }
        guard files.contains(where: { $0.objectValue?["path"]?.stringValue == name }) else { return nil }
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("fileRead"), "path": .string(name)]))
        guard let text = result.objectValue?["content"]?.stringValue else { throw RuntimeError.bridge("Profile document is not text") }
        return text
    }

    func writeTextFile(_ text: String, named name: String, in scope: ProfileScope) async throws {
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("fileWrite"), "path": .string(name), "text": .string(text)]))
    }

    private func requireProfile(in scope: ProfileScope) throws {
        guard let id = scope.profileID, let manifest = ProfileIO.readConfig(at: scope.root), manifest.id == id, manifest.version == ProfileSchema.current else {
            throw RuntimeError.bridge("Profile scope is not prepared")
        }
    }

    func chatSummaries(in scope: ProfileScope) async -> [ChatMeta] {
        do {
            var result: [ChatMeta] = []
            var cursor: JSONValue = .null
            repeat {
                let page = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("conversationList"), "limit": .int(100), "listCursor": cursor]))
                for item in page.objectValue?["items"]?.arrayValue ?? [] {
                    guard let value = item.objectValue?["reference"] else { continue }
                    let reference = try decodeReference(value, scope: scope)
                    let loaded = try await load(reference, scope: scope)
                    if loaded.state.turns.isEmpty { continue }
                    result.append(loaded.state.meta)
                }
                cursor = page.objectValue?["next"] ?? .null
            } while cursor != .null
            return result
        } catch { Log.session.error("ProfileRepository.list failed=\(error.localizedDescription)"); return [] }
    }

    func loadChat(_ id: ChatID, in scope: ProfileScope) async -> ChatLoadResult? {
        guard deleted[scope]?.contains(id) != true else { return nil }
        do { return try await load(DurableProfileStore.shared.reference(for: id, in: scope), scope: scope) }
        catch { Log.session.error("ProfileRepository.load chat=\(id) failed=\(error.localizedDescription)"); return nil }
    }

    private func load(_ reference: DurableConversationReference, scope: ProfileScope) async throws -> ChatLoadResult {
        let value = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("applicationLoad"), "reference": reference.value]))
        let fields = value.objectValue ?? [:]
        var metadata = fields["metadata"]?.objectValue ?? [:]
        metadata["id"] = .string(reference.compatibilityID.rawValue.uuidString)
        metadata["schemaVersion"] = .int(ChatFormat.currentSchemaVersion)
        metadata["createdAt"] = metadata["createdAt"] ?? .double(Date().timeIntervalSinceReferenceDate)
        metadata["attachedServiceDomains"] = metadata["attachedServiceDomains"] ?? .array([])
        metadata["title"] = fields["presentation"]?.objectValue?["title"] ?? .null
        metadata["isFavorite"] = fields["favorite"] ?? .bool(false)
        metadata["hasUnreadResponse"] = fields["unread"] ?? .bool(false)
        let agent = fields["agent"]?.objectValue ?? [:]
        if let model = agent["model"]?.objectValue, let modelID = model["modelId"]?.stringValue,
           let provider = metadata["nativeProviderID"]?.stringValue ?? model["provider"]?.stringValue {
            metadata["model"] = .object(["providerID": .string(provider), "modelID": .string(modelID),
                "reasoningEffort": metadata["nativeReasoningEffort"] ?? agent["thinkingLevel"] ?? .null])
        }
        let decoder = JSONDecoder(); decoder.userInfo[.profileScope] = scope
        let meta = try decoder.decode(ChatMeta.self, from: Data(JSONValue.object(metadata).jsonString().utf8))
        let turns = try DurableChatProjection.turns(from: fields["entries"]?.arrayValue ?? [], scope: scope)
        return ChatLoadResult(state: ChatState(meta: meta, turns: turns, context: nil), needsPersistence: false)
    }

    func saveChat(_ request: ChatSaveRequest, in scope: ProfileScope) async -> ChatSaveReceipt {
        debugSaveGate.pass()
        do {
            let reference = try await DurableProfileStore.shared.reference(for: request.chatID, in: scope)
            let meta: ChatMeta
            let turns: [Turn]?
            switch request.payload {
            case .metadata(let value): meta = value; turns = nil
            case .chat(let state): meta = state.meta; turns = state.turns
            }
            var fields = try encoded(meta).objectValue ?? [:]
            for key in ["id", "model", "title", "isFavorite", "hasUnreadResponse"] { fields.removeValue(forKey: key) }
            if let provider = meta.model?.providerID { fields["nativeProviderID"] = .string(provider) }
            var command: [String: JSONValue] = ["action": .string("applicationSave"), "reference": reference.value,
                "metadata": .object(fields), "title": .string(meta.title ?? ""), "favorite": .bool(meta.isFavorite), "unread": .bool(meta.hasUnreadResponse)]
            if let turns { command["turns"] = .array(try turns.map(encoded)) }
            if let model = meta.model {
                var agent: [String: JSONValue] = ["model": .object(["provider": .string(model.providerID), "modelId": .string(model.modelID)])]
                if let effort = model.reasoningEffort, ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) { agent["thinkingLevel"] = .string(effort) }
                command["agent"] = .object(agent)
            }
            _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(command))
            return ChatSaveReceipt(saveID: request.saveID, succeeded: true)
        } catch { Log.session.error("ProfileRepository.save chat=\(request.chatID) failed=\(error.localizedDescription)"); return ChatSaveReceipt(saveID: request.saveID, succeeded: false) }
    }

    func deleteChat(_ id: ChatID, in scope: ProfileScope) async throws {
        let reference = try await DurableProfileStore.shared.reference(for: id, in: scope)
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("applicationDelete"), "reference": reference.value]))
        deleted[scope, default: []].insert(id)
    }

    func virtualChatMetadata(_ id: ChatID, in scope: ProfileScope, snapshot: ChatState? = nil) async throws -> Data {
        let loaded = snapshot == nil ? await loadChat(id, in: scope)?.state : nil
        guard let state = snapshot ?? loaded else { throw RuntimeError.bridge("Conversation unavailable") }
        return try JSONEncoder().encode(state.meta)
    }

    func virtualChatTranscript(_ id: ChatID, in scope: ProfileScope, snapshot: ChatState? = nil) async throws -> Data {
        let loaded = snapshot == nil ? await loadChat(id, in: scope)?.state : nil
        guard let state = snapshot ?? loaded else { throw RuntimeError.bridge("Conversation unavailable") }
        var data = Data()
        for turn in state.turns { data.append(try JSONEncoder().encode(turn)); data.append(0x0A) }
        return data
    }

    func virtualChatFileSizes(_ id: ChatID, in scope: ProfileScope, snapshot: ChatState? = nil) async throws -> (metadata: Int, transcript: Int) {
        (try await virtualChatMetadata(id, in: scope, snapshot: snapshot).count, try await virtualChatTranscript(id, in: scope, snapshot: snapshot).count)
    }

    func export(_ state: ChatState) throws -> Data {
        try Data(JSONValue.object(["metadata": try encoded(state.meta), "turns": .array(try state.turns.map(encoded))]).jsonString().utf8)
    }

    func importChatPackage(_ payload: ChatPackagePayload, in scope: ProfileScope) async throws -> ChatState {
        let prepared = try ChatPackageCodec.prepare(payload)
        let directory = try artifactsDirectory(in: scope)
        let names = Dictionary(uniqueKeysWithValues: prepared.artifacts.keys.map { ($0.lowercased(), UUID().uuidString + "-" + $0) })
        let materialized = try prepared.materialized(artifactNames: names, directory: directory)
        for (name, data) in materialized.artifacts { _ = try await writeArtifact(data: data, named: name, in: scope) }
        let alias = "ox-native:" + UUID().uuidString
        let entries = try materialized.turns.map { turn -> JSONValue in
            .object(["kind": .string("ox.native.turn"), "data": .object(["turn": try encoded(turn)]),
                "model": .array(ChatProjection.makeWireMessages(from: [turn]).map { DurableMessageCodec.message($0, provider: alias, profileID: scope.profileID) })])
        }
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object(["action": .string("conversationCreate"), "entries": .array(entries),
            "metadata": .object(["createdAt": .double(payload.header.createdAt.timeIntervalSinceReferenceDate), "attachedServiceDomains": .array([])]),
            "title": .string(String(payload.header.title.prefix(60)))]))
        guard let value = result.objectValue?["reference"] else { throw RuntimeError.bridge("Imported conversation identity missing") }
        let reference = try decodeReference(value, scope: scope)
        return try await load(reference, scope: scope).state
    }

    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }

    private func decodeReference(_ value: JSONValue, scope: ProfileScope) throws -> DurableConversationReference {
        let reference = try JSONDecoder().decode(DurableConversationReference.self, from: Data(value.jsonString().utf8))
        guard reference.profileID == scope.profileID else { throw RuntimeError.bridge("Conversation belongs to another Profile") }
        return reference
    }
}
