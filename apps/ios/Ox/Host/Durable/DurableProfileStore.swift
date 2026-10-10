import Foundation

nonisolated struct DurableConversationReference: Hashable, Codable, Sendable {
    let profileID: UUID
    let conversationID: Int

    var value: JSONValue { .object(["profileID": .string(profileID.uuidString), "conversationID": .int(conversationID)]) }

    var compatibilityID: ChatID {
        let prefix = profileID.uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let compact = String(prefix) + String(format: "%016llx", UInt64(conversationID))
        let bytes = Array(compact)
        let text = [String(bytes[0..<8]), String(bytes[8..<12]), String(bytes[12..<16]), String(bytes[16..<20]), String(bytes[20..<32])].joined(separator: "-")
        return ChatID(UUID(uuidString: text)!)
    }

    init(profileID: UUID, conversationID: Int) {
        self.profileID = profileID
        self.conversationID = conversationID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        conversationID = try values.decode(Int.self, forKey: .conversationID)
        guard (0...9_007_199_254_740_991).contains(conversationID) else {
            throw DecodingError.dataCorruptedError(forKey: .conversationID, in: values, debugDescription: "Invalid Pi conversation identity")
        }
    }

    init?(compatibilityID: ChatID, profileID: UUID) {
        let text = compatibilityID.rawValue.uuidString.replacingOccurrences(of: "-", with: "")
        guard text.prefix(16) == profileID.uuidString.replacingOccurrences(of: "-", with: "").prefix(16),
              let number = UInt64(text.suffix(16), radix: 16), number <= 9_007_199_254_740_991 else { return nil }
        self.init(profileID: profileID, conversationID: Int(number))
    }
}

actor DurableProfileStore {
    static let shared = DurableProfileStore()

    struct Session: Sendable {
        let runtime: DurableRuntime
        let host: DurableAgentHost
        let scope: ProfileScope
        let resources: ReadOnlyFiles
        let skills: BundledSkillPackages
    }

    private var sessions: [URL: Task<Session, Error>] = [:]

    func session(in scope: ProfileScope) async throws -> Session {
        let root = scope.root.standardizedFileURL
        if let opening = sessions[root] {
            let session = try await opening.value
            guard session.scope.profileID == scope.profileID else { throw RuntimeError.bridge("Profile database identity mismatch") }
            return session
        }
        guard let profileID = scope.profileID,
              let manifest = ProfileIO.readConfig(at: root), manifest.id == profileID, manifest.version == ProfileSchema.current else {
            throw RuntimeError.bridge("Profile must pass storage preparation before Pi opens")
        }
        guard scope.location == .local else { throw RuntimeError.bridge("Pi Profiles require local storage; import an offline snapshot into a local Profile") }
        let opening = Task<Session, Error> {
            let host = DurableAgentHost()
            let runtime = DurableRuntime(databaseURL: scope.stateRoot.appendingPathComponent("state.sqlite"), fileRoot: root) { method, params, stream in
                try await host.handle(method, params, stream: stream)
            }
            do {
                _ = try await runtime.command(JSONValue.object(["action": .string("open"), "profileID": .string(profileID.uuidString), "artifactFiles": .bool(true), "workspace": .bool(true), "publicFiles": .bool(true)]).jsonString())
                let resources = try await runtime.fileMounts(scope: profileID)
                Log.agent.info("PiDurable Profile opened profile=\(profileID)")
                return Session(runtime: runtime, host: host, scope: scope, resources: resources, skills: try await runtime.skillPackages(scope: profileID))
            } catch { await runtime.dispose(); throw error }
        }
        sessions[root] = opening
        do { return try await opening.value }
        catch { sessions[root] = nil; throw error }
    }

    func command(scope: ProfileScope, value: JSONValue) async throws -> JSONValue {
        let session = try await session(in: scope)
        return try JSONDecoder().decode(JSONValue.self, from: Data(try await session.runtime.command(value.jsonString()).utf8))
    }

    func readFile(scope: ProfileScope, file: JSONValue) async throws -> Data {
        try await session(in: scope).runtime.readFile(file)
    }

    func readFileData(path: String, in scope: ProfileScope) async throws -> Data {
        let result = try await command(scope: scope, value: .object(["action": .string("fileStat"), "path": .string(path)]))
        guard let file = result.objectValue?["file"], file != .null else { throw RuntimeError.bridge("File is not committed in this Profile") }
        return try await readFile(scope: scope, file: file)
    }

    func close(in scope: ProfileScope) async throws {
        let root = scope.root.standardizedFileURL
        guard let opening = sessions[root] else { return }
        let session = try await opening.value
        do {
            _ = try await session.runtime.command(JSONValue.object(["action": .string("close")]).jsonString())
        } catch {
            await session.runtime.dispose()
            sessions[root] = nil
            Log.agent.error("PiDurable Profile close failed; native owner disposed, explicit reopen required profile=\(scope.profileID?.uuidString ?? "nil") error=\(error.localizedDescription)")
            throw error
        }
        await session.runtime.dispose()
        sessions[root] = nil
        Log.agent.info("PiDurable Profile closed profile=\(scope.profileID?.uuidString ?? "nil")")
    }

    func create(in scope: ProfileScope, metadata: JSONValue = .object([:])) async throws -> DurableConversationReference {
        let result = try await command(scope: scope, value: .object(["action": .string("conversationCreate"), "metadata": metadata]))
        guard let reference = result.objectValue?["reference"] else { throw RuntimeError.bridge("Pi conversation creation did not return its identity") }
        let value = try JSONDecoder().decode(DurableConversationReference.self, from: Data(reference.jsonString().utf8))
        guard value.profileID == scope.profileID else { throw RuntimeError.bridge("Pi conversation belongs to another Profile") }
        return value
    }

    func fork(in scope: ProfileScope, from source: DurableConversationReference, beforeUser index: Int, title: String?) async throws -> DurableConversationReference {
        let loaded = try await command(scope: scope, value: .object(["action": .string("applicationLoad"), "reference": source.value]))
        var users = 0
        var previous: Int?
        for entry in loaded.objectValue?["entries"]?.arrayValue ?? [] {
            guard let fields = entry.objectValue, let entryID = fields["id"]?.intValue else { throw RuntimeError.bridge("Invalid committed history") }
            if fields["kind"]?.stringValue != "pi.reset", fields["kind"]?.stringValue != "pi.compaction" {
                let models = (fields["model"]?.arrayValue ?? []).filter { $0.objectValue?["role"]?.stringValue != "system" }
                for (offset, model) in models.enumerated() where model.objectValue?["role"]?.stringValue == "user" {
                    if users == index {
                        guard offset == 0, let previous else { throw RuntimeError.bridge("Selected turn cannot be split at a committed boundary") }
                        return try await fork(in: scope, from: source, atEntry: previous, title: title)
                    }
                    users += 1
                }
            }
            previous = entryID
        }
        if users == index, let previous {
            return try await fork(in: scope, from: source, atEntry: previous, title: title)
        }
        throw RuntimeError.bridge("Selected user turn is not committed in Pi")
    }

    private func fork(in scope: ProfileScope, from source: DurableConversationReference, atEntry entryID: Int, title: String?) async throws -> DurableConversationReference {
        var request: [String: JSONValue] = ["action": .string("conversationFork"), "reference": source.value, "entryID": .int(entryID)]
        if let title { request["title"] = .string(title) }
        let result = try await command(scope: scope, value: .object(request))
        guard let reference = result.objectValue?["reference"] else { throw RuntimeError.bridge("Missing fork identity") }
        return try JSONDecoder().decode(DurableConversationReference.self, from: Data(reference.jsonString().utf8))
    }

    nonisolated func reference(for id: ChatID, in scope: ProfileScope) throws -> DurableConversationReference {
        guard let profileID = scope.profileID else { throw RuntimeError.bridge("No Profile identity") }
        if let reference = DurableConversationReference(compatibilityID: id, profileID: profileID) { return reference }
        guard let reference = try StorageMigrator.durableConversationReference(for: id.rawValue, in: scope) else {
            throw RuntimeError.bridge("Conversation is not part of this Profile")
        }
        return reference
    }
}
