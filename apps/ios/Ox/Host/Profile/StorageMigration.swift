import Foundation
import CryptoKit
import Security
import SwiftGitX
import UniformTypeIdentifiers
import Darwin

nonisolated enum ProfileSchema {
    static let versions = [
        "2026-06-15",
        "2026-06-26",
        "2026-07-06",
        "2026-07-10",
        "2026-07-11",
        "2026-07-12-chat",
        "2026-07-19-artifacts",
        "2026-07-27-chat-directories",
        "2026-07-29-migration-repair",
        "2026-08-01-agent-context",
        "2026-08-03-skill-namespace",
        "2026-08-10-plain-skill-names",
        "2026-08-17-runtime",
        "2026-08-29-compacted-context",
        "2026-08-31-model-selection",
        "2026-09-18-providers",
        "2026-09-20-browser-functions",
        "2026-09-24-repository-skills",
        "2026-09-25-import-memory",
        "2026-09-27-outcome-skills",
        "2026-09-28-provider-skill",
        "2026-10-05-pi-durable",
    ]
    static var current: String { versions.last! }

    static let steps: [@Sendable (URL) throws -> Void] = [
        { _ in },
        { _ in },
        { try StorageMigrator.moveAttachmentsToArtifacts(at: $0) },
        { try StorageMigrator.migrateLegacySkills(at: $0) },
        { _ in },
        { try StorageMigrator.renameLibraryToArtifacts(at: $0) },
        { try StorageMigrator.moveChatsIntoDirectories(at: $0) },
        { try StorageMigrator.repairStorage(at: $0) },
        { try StorageMigrator.migrateAgentContexts(at: $0) },
        { try StorageMigrator.namespaceUserSkills(at: $0) },
        { try StorageMigrator.removeUserSkillNamespace(at: $0) },
        { _ in },
        { try StorageMigrator.removeRedundantAgentContexts(at: $0) },
        { try StorageMigrator.migrateChatModelSelections(at: $0) },
        { try StorageMigrator.migrateChatProviderDefinitions(at: $0) },
        { try StorageMigrator.removeBrowserServiceAttachments(at: $0) },
        { try StorageMigrator.migrateProfileSkillCatalog(at: $0) },
        { try StorageMigrator.migrateReservedImportMemorySkill(at: $0) },
        { try StorageMigrator.migrateReservedOutcomeSkills(at: $0) },
        { try StorageMigrator.migrateReservedSkill("manage-providers", at: $0) },
    ]
}

nonisolated enum StorageMigrationError: LocalizedError {
    case activeProfileUnavailable
    case collision(String)
    case invalidAttachment(String)
    case invalidApplicationStorage(String)
    case invalidArtifact(String)
    case invalidLocalRepositorySeed
    case invalidRepairedLocalRepository
    case missingArtifact(String)
    case missingConfig
    case localRepositoryRollbackFailed(String)
    case profileMigrationFailed(String)
    case recoveryRequired(String)
    case unsupportedProfileVersion(String, String)

    var errorDescription: String? {
        switch self {
        case .activeProfileUnavailable: "No Profile is available to open."
        case .collision(let path): "Migration destination conflicts with existing data: \(path)"
        case .invalidAttachment(let path): "Legacy attachment metadata is invalid: \(path)"
        case .invalidApplicationStorage(let component): "Stored \(component) data is not compatible with this version of Ox."
        case .invalidArtifact(let path): "Legacy artifact metadata is invalid: \(path)"
        case .invalidLocalRepositorySeed: "The Local repository repair seed is invalid."
        case .invalidRepairedLocalRepository: "The repaired Local repository is invalid."
        case .missingArtifact(let path): "Legacy artifact content is missing: \(path)"
        case .missingConfig: "The Profile configuration could not be read."
        case .localRepositoryRollbackFailed(let detail): "The Local repository repair and rollback failed: \(detail)"
        case .profileMigrationFailed(let name): "The Profile “\(name)” could not be updated safely."
        case .recoveryRequired(let message): message
        case .unsupportedProfileVersion(let name, let version):
            "The Profile “\(name)” uses data format “\(version)”, which this version of Ox does not support. Install the Ox version that last opened it or a newer one."
        }
    }
}

nonisolated enum StoragePreparation: Equatable, Sendable {
    case ready
    case needsRecovery(String)

    var failureMessage: String? {
        if case .needsRecovery(let message) = self { return message }
        return nil
    }
}

nonisolated enum StorageMigrator {
    private static let legacyChatSchemaVersion = 6
    static let durableProfileVersion = "2026-10-05-pi-durable"
    static let nativeProfileVersion = "2026-09-28-provider-skill"

    static func builtInSkillSnapshot(named name: String) throws -> Skill? {
        guard SkillFiles.reservedNames.contains(name) else { return nil }
        let prefix = name + "/"
        let instructions = try BuiltInGuidance.text(prefix + "guide.md")
        var resources: [String: String] = [:]
        for path in try BuiltInGuidance.paths(under: name) where path != prefix + "guide.md" {
            resources[String(path.dropFirst(prefix.count))] = try BuiltInGuidance.text(path)
        }
        Log.app.info("StorageMigrator.builtInSkillSnapshot name=\(name) resources=\(resources.count)")
        return Skill(name: name, description: "Built-in Ox workflow retained for compatibility.", instructions: instructions,
            resources: resources.isEmpty ? nil : resources, source: .system)
    }

    static func createFreshProfile(name: String, base: URL, unique: Bool = false) async throws -> Profile {
        let manager = FileManager.default
        let stem = ProfileRepository.cleanName(name)
        var candidate = stem
        var suffix = 2
        while manager.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            guard unique else { throw ProfileError.nameExists(name) }
            candidate = "\(stem) \(suffix)"; suffix += 1
        }
        let destination = base.appendingPathComponent(candidate)
        let stage = base.appendingPathComponent(".pi-fresh-" + UUID().uuidString)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let manifest = ProfileConfig.fresh()
        let runtime = DurableRuntime(databaseURL: stage.appendingPathComponent("state.sqlite"), artifactRoot: stage) { method, _, _ in
            throw RuntimeError.bridge("Fresh Profile installation forbids native capabilities: \(method)")
        }
        do {
            let draft: JSONValue = .object(["format": .int(1), "profileID": .string(manifest.id.uuidString),
                "documents": .array([]), "artifacts": .array([]), "conversations": .array([])])
            _ = try await runtime.command(JSONValue.object(["action": .string("installProfile"), "draft": draft]).jsonString())
            await runtime.dispose()
            try ProfileIO.writeConfig(manifest, to: stage)
            try syncDurableDirectory(stage)
            try manager.moveItem(at: stage, to: destination)
            try syncDurableDirectory(base)
            guard let profile = ProfileIO.profile(at: destination, location: .local) else { throw StorageMigrationError.profileMigrationFailed(candidate) }
            return profile
        } catch {
            await runtime.dispose()
            Log.app.error("StorageMigrator.fresh failed stage=\(stage.lastPathComponent) error=\(error.localizedDescription)")
            throw error
        }
    }

    private static func durableJournalDirectory(_ id: UUID) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StorageMigration/PiProfiles/" + id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private static func writeDurableJournal(_ journal: [String: Any], profileID: UUID) throws {
        let directory = try durableJournalDirectory(profileID)
        let file = directory.appendingPathComponent("journal.json")
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: file, options: .atomic)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration journal") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration journal durability") }
        try syncDurableDirectory(directory)
    }

    private static func syncDurableDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration directory") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration directory durability") }
    }

    private static func publishDurableJournal(_ journal: [String: Any]) throws {
        guard journal["format"] as? Int == 1, let text = journal["profileID"] as? String, let id = UUID(uuidString: text),
              let rootPath = journal["root"] as? String, let stagePath = journal["stage"] as? String, let backupPath = journal["backup"] as? String else {
            throw StorageMigrationError.invalidApplicationStorage("Pi migration journal")
        }
        let root = URL(fileURLWithPath: rootPath), stage = URL(fileURLWithPath: stagePath), backup = URL(fileURLWithPath: backupPath)
        guard stage.deletingLastPathComponent() == root.deletingLastPathComponent(), stage.lastPathComponent.hasPrefix(".pi-stage-"),
              backup.deletingLastPathComponent() == (try durableJournalDirectory(id)), root != stage, root != backup else {
            throw StorageMigrationError.invalidApplicationStorage("Pi migration publication paths")
        }
        if let manifest = ProfileIO.readConfig(at: root), manifest.id == id, manifest.version == durableProfileVersion {
            var published = journal; published["phase"] = "published"
            try writeDurableJournal(published, profileID: id)
            return
        }
        guard let manifest = ProfileIO.readConfig(at: stage), manifest.id == id, manifest.version == durableProfileVersion,
              FileManager.default.fileExists(atPath: stage.appendingPathComponent("state.sqlite").path) else {
            throw StorageMigrationError.invalidApplicationStorage("validated staged Pi Profile")
        }
        if FileManager.default.fileExists(atPath: root.path) {
            guard !FileManager.default.fileExists(atPath: backup.path),
                  let result = journal["result"] as? [String: Any], let inventory = result["sourceInventory"] as? [String: String],
                  try migrationSourceInventory(at: root) == inventory else { throw StorageMigrationError.profileMigrationFailed(root.lastPathComponent) }
            try FileManager.default.moveItem(at: root, to: backup)
            try syncDurableDirectory(root.deletingLastPathComponent())
            try syncDurableDirectory(backup.deletingLastPathComponent())
        }
        try FileManager.default.moveItem(at: stage, to: root)
        try syncDurableDirectory(root.deletingLastPathComponent())
        var published = journal; published["phase"] = "published"
        try writeDurableJournal(published, profileID: id)
        Log.app.info("StorageMigrator.pi published id=\(id) sourceBackupRetained=true")
    }

    private static func recoverDurablePublications() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StorageMigration/PiProfiles")
        guard FileManager.default.fileExists(atPath: base.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            let file = directory.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], journal["format"] as? Int == 1 else {
                throw StorageMigrationError.invalidApplicationStorage("Pi migration journal")
            }
            if journal["phase"] as? String == "prepared" { try publishDurableJournal(journal) }
            else if journal["phase"] as? String != "published" { throw StorageMigrationError.invalidApplicationStorage("Pi migration phase") }
        }
    }

    static func durableConversationReference(for legacyID: UUID, in scope: ProfileScope) throws -> DurableConversationReference? {
        guard let id = scope.profileID else { return nil }
        let file = try durableJournalDirectory(id).appendingPathComponent("journal.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any], journal["format"] as? Int == 1,
              let result = journal["result"] as? [String: Any], let installation = result["installation"] as? [String: Any],
              let conversations = installation["conversations"] as? [[String: Any]] else { throw StorageMigrationError.invalidApplicationStorage("Pi conversion results") }
        guard let record = conversations.first(where: { ($0["key"] as? String).flatMap(UUID.init(uuidString:)) == legacyID }),
              let reference = record["reference"] as? [String: Any] else { return nil }
        let value = try JSONDecoder().decode(DurableConversationReference.self, from: JSONSerialization.data(withJSONObject: reference))
        guard value.profileID == id else { throw StorageMigrationError.invalidApplicationStorage("Pi conversion identity") }
        return value
    }

    static func stageDurableProfile(_ profile: Profile, at destination: URL) async throws -> JSONValue {
        let sourcePath = profile.url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard profile.location == .local, profile.version == nativeProfileVersion,
              sourcePath != destinationPath, !destinationPath.hasPrefix(sourcePath + "/"), !sourcePath.hasPrefix(destinationPath + "/") else {
            throw StorageMigrationError.profileMigrationFailed(profile.name)
        }
        let prepared = try await Task.detached(priority: .userInitiated) {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw StorageMigrationError.collision(destination.lastPathComponent)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return try durableProfileDraft(profile, destination: destination)
        }.value
        let runtime = DurableRuntime(databaseURL: destination.appendingPathComponent("state.sqlite"), artifactRoot: destination)
        do {
            let result = try await runtime.command(JSONValue.object(["action": .string("installProfile"), "draft": prepared.draft]).jsonString())
            await runtime.dispose()
            try await Task.detached(priority: .userInitiated) {
                let current = try durableSourceInventory(at: profile.url)
                guard current == prepared.inventory else { throw StorageMigrationError.profileMigrationFailed(profile.name) }
                var manifest = prepared.manifest
                manifest["version"] = durableProfileVersion
                try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
                    .write(to: destination.appendingPathComponent(ProfileIO.configName), options: .atomic)
                let directory = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw StorageMigrationError.invalidApplicationStorage("staged Profile") }
                defer { Darwin.close(directory) }
                let file = openat(directory, ProfileIO.configName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard file >= 0 else { throw StorageMigrationError.missingConfig }
                defer { Darwin.close(file) }
                guard fsync(file) == 0, fsync(directory) == 0 else { throw StorageMigrationError.profileMigrationFailed(profile.name) }
            }.value
            Log.app.info("StorageMigrator.pi staged id=\(profile.id) target=\(durableProfileVersion) activated=false")
            return .object(["installation": try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)),
                "sourceInventory": .from(prepared.inventory), "profileID": .string(profile.id.uuidString)])
        } catch {
            await runtime.dispose()
            Log.app.error("StorageMigrator.pi stage failed id=\(profile.id) sourcePreserved=true error=\(error.localizedDescription)")
            throw error
        }
    }

    private struct DurableProfileDraft: @unchecked Sendable {
        let draft: JSONValue
        let manifest: [String: Any]
        let inventory: [String: String]
    }

    private static func durableProfileDraft(_ profile: Profile, destination: URL) throws -> DurableProfileDraft {
        let manager = FileManager.default
        let inventory = try durableSourceInventory(at: profile.url)
        let manifest = try JSONSerialization.jsonObject(with: durableSourceFile(ProfileIO.configName, at: profile.url)) as? [String: Any]
        guard let manifest, (manifest["id"] as? String).flatMap(UUID.init(uuidString:)) == profile.id,
              manifest["version"] as? String == nativeProfileVersion else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: profile.id, root: profile.url, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        decoder.userInfo[.artifactDirectoryListing] = ArtifactDirectoryListing()
        var documents: [[String: Any]] = []
        var artifacts: [[String: Any]] = []
        var conversations: [[String: Any]] = []
        var payloads: [String: JSONValue] = [:]
        let payloadStore = DurableArtifactStore(root: destination)
        defer { payloadStore.close() }
        func archive(_ data: Data) throws -> JSONValue {
            let writer = try payloadStore.payloadWriter()
            try writer.append(data)
            let source = try writer.finish()
            payloads[source.objectValue!["path"]!.stringValue!] = source
            return source
        }
        let savedPath = "artifacts/.saved.json"
        let saved = inventory[savedPath] == nil ? [] : try decoder.decode([String].self, from: durableSourceFile(savedPath, at: profile.url))
        let artifactDirectory = destination.appendingPathComponent("artifacts", isDirectory: true)
        try manager.createDirectory(at: artifactDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for path in inventory.keys.sorted() {
            if ["MEMORY.md", "SOUL.md", "skill-selections.json"].contains(path) || path.hasPrefix("skills/") {
                let data = try durableSourceFile(path, at: profile.url)
                if path == "skill-selections.json", try decoder.decode(SkillSelections.self, from: data).version != 1 { throw SkillError.invalidPackage }
                guard let text = String(data: data, encoding: .utf8) else { throw StorageMigrationError.invalidApplicationStorage(path) }
                documents.append(["path": path, "text": text])
            } else if path.hasPrefix("artifacts/"), path != savedPath {
                let name = String(path.dropFirst("artifacts/".count))
                guard !name.contains("/"), try ArtifactStore.validatedFilename(name) == name else { throw StorageMigrationError.invalidArtifact(path) }
                let data = try durableSourceFile(path, at: profile.url, limit: 32 * 1024 * 1024)
                let binary = data.count > 200 * 1024 || String(data: data, encoding: .utf8) == nil
                try data.write(to: artifactDirectory.appendingPathComponent(name), options: .withoutOverwriting)
                artifacts.append(["path": path, "size": data.count, "sha256": durableDigest(data), "binary": binary,
                    "saved": saved.contains { $0.caseInsensitiveCompare(name) == .orderedSame }])
            }
        }
        let names = Set(artifacts.compactMap { $0["path"] as? String }.map { String($0.dropFirst("artifacts/".count)).lowercased() })
        guard saved.allSatisfy({ names.contains($0.lowercased()) }) else { throw StorageMigrationError.invalidArtifact(savedPath) }
        let chatFiles = inventory.keys.filter { $0.hasPrefix("chats/") }
        guard chatFiles.allSatisfy({ path in
            let parts = path.split(separator: "/")
            return parts.count == 3 && UUID(uuidString: String(parts[1])) != nil && inventory["\(parts[0])/\(parts[1])/chat.json"] != nil
        }) else { throw StorageMigrationError.invalidApplicationStorage("chats") }
        let chatPaths = chatFiles.filter { $0.hasSuffix("/chat.json") }.sorted()
        for path in chatPaths {
            let prefix = String(path.dropLast("chat.json".count))
            let data = try durableSourceFile(path, at: profile.url)
            let metadata = try decodeMigrationValue(ChatMeta.self, from: data, decoder: decoder, path: path)
            guard metadata.schemaVersion == ChatFormat.currentSchemaVersion,
                  UUID(uuidString: String(prefix.split(separator: "/")[1])) == metadata.id else {
                throw StorageMigrationError.invalidApplicationStorage(path)
            }
            let transcriptPath = prefix + "turns.jsonl"
            var records: [(turn: Turn, source: JSONValue, missingPurposes: Set<UUID>)] = []
            if inventory[transcriptPath] != nil {
                let descriptor = try durableSourceDescriptor(transcriptPath, at: profile.url)
                defer { Darwin.close(descriptor) }
                let reader = DurableTranscriptReader(descriptor: descriptor, store: payloadStore)
                while let record = try reader.next() {
                    var missingPurposes: Set<UUID> = []
                    let value = mapMigrationInvocations(in: record.value) { invocation in
                        var invocation = invocation
                        if invocation["purpose"] == nil {
                            invocation["purpose"] = .string("")
                            if let id = invocation["id"]?.stringValue.flatMap(UUID.init(uuidString:)) { missingPurposes.insert(id) }
                        }
                        return invocation
                    }
                    let turn = try decodeMigrationValue(Turn.self, from: Data(value.jsonString().utf8), decoder: decoder,
                        path: "\(transcriptPath):\(records.count + 1)")
                    records.append((turn, record.source, missingPurposes))
                    payloads[record.source.objectValue!["path"]!.stringValue!] = record.source
                }
                let missingPurposes = records.reduce(0) { $0 + $1.missingPurposes.count }
                Log.app.info("StorageMigrator.pi transcript archived path=\(transcriptPath) turns=\(records.count) externalized=\(reader.externalized) legacyPurposes=\(missingPurposes) bytes=\(reader.position)")
            }
            let turns = records.map(\.turn)
            var document = ChatDocument(turns: turns)
            guard document.turns.map(\.id) == turns.map(\.id) else { throw StorageMigrationError.invalidApplicationStorage(transcriptPath) }
            document.apply(.sealAllTurns)
            let sealed = document.turns
            let contextPath = prefix + "context.json"
            let checkpoint = inventory[contextPath] == nil ? nil : try decodeMigrationValue(AgentContextCheckpoint.self,
                from: durableSourceFile(contextPath, at: profile.url), decoder: decoder, path: contextPath)
            let boundary = try checkpoint.map {
                let original = try decoder.decode(JSONValue.self, from: durableSourceFile(contextPath, at: profile.url))
                return try durableCheckpointBoundary($0, records: records, originalMessages: original.objectValue?["messages"], store: payloadStore)
            } ?? nil
            if checkpoint != nil, boundary == nil {
                Log.app.warning("StorageMigrator.pi context recovered path=\(contextPath) reason=staleTranscriptCheckpoint source=completeTranscript turns=\(turns.count)")
            } else if turns.requiresContextCheckpoint, checkpoint == nil {
                Log.app.warning("StorageMigrator.pi context recovered path=\(contextPath) reason=missingCheckpoint source=completeTranscript turns=\(turns.count)")
            }
            let alias = "ox-native:\(metadata.id.uuidString)"
            var unavailableAttachments = 0
            func messages(_ source: [Message]) -> [JSONValue] {
                source.map { message in
                    var fields = DurableMessageCodec.message(message, provider: alias, profileID: profile.id).objectValue!
                    fields["content"] = .array((fields["content"]?.arrayValue ?? []).map { block in
                        guard let name = block.objectValue?["oxAttachment"]?.stringValue,
                              !names.contains(name.lowercased()) else { return block }
                        unavailableAttachments += 1
                        return .object(["type": .string("text"), "text": .string("[Unavailable historical attachment: artifacts/\(name)]")])
                    })
                    return .object(fields)
                }
            }
            var entries: [[String: Any]] = [["kind": "ox.native.metadata", "data": ["source": try archive(data).toAny()]]]
            if checkpoint != nil, boundary == nil {
                entries.append(["kind": "ox.native.context", "data": ["source": try archive(durableSourceFile(contextPath, at: profile.url)).toAny()]])
            }
            var expected: [Any] = []
            for (index, turn) in sealed.enumerated() {
                let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn))
                let model = messages(ChatProjection.makeWireMessages(from: [turn])).map { $0.toAny() }
                expected.append(contentsOf: model)
                entries.append(["kind": "ox.native.turn", "model": model, "data": ["turn": canonical, "source": records[index].source.toAny()]])
                if index == boundary, let checkpoint {
                    expected = messages(checkpoint.messages).map { $0.toAny() }
                    let source = try archive(durableSourceFile(contextPath, at: profile.url))
                    entries.append(["kind": "pi.reset", "head": "self", "data": ["source": source.toAny()], "model": expected])
                }
            }
            if unavailableAttachments > 0 {
                Log.app.warning("StorageMigrator.pi attachments unavailable path=\(path) count=\(unavailableAttachments) sourcePreserved=true")
            }
            var applicationMetadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            for key in ["id", "model", "title", "isFavorite", "hasUnreadResponse"] { applicationMetadata.removeValue(forKey: key) }
            var agent: [String: Any] = [:]
            if let model = metadata.model {
                agent["model"] = ["provider": model.providerID, "modelId": model.modelID]
                if let effort = model.reasoningEffort {
                    if ["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort) { agent["thinkingLevel"] = effort }
                    else { applicationMetadata["nativeReasoningEffort"] = effort }
                }
            }
            conversations.append(["key": metadata.id.uuidString, "title": metadata.title ?? "", "favorite": metadata.isFavorite,
                "unread": metadata.hasUnreadResponse, "agent": agent, "metadata": applicationMetadata, "entries": entries, "expectedContext": try durableExpectedContext(expected)])
        }
        return DurableProfileDraft(draft: .from(["format": 1, "profileID": profile.id.uuidString, "documents": documents,
            "artifacts": artifacts, "payloads": payloads.values.map { $0.toAny() }, "conversations": conversations]), manifest: manifest, inventory: inventory)
    }

    private static func decodeMigrationValue<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder, path: String) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch let error as DecodingError {
            let context: DecodingError.Context
            let reason: String
            switch error {
            case .keyNotFound(let key, let detail): context = detail; reason = "missingKey:\(key.stringValue)"
            case .valueNotFound(_, let detail): context = detail; reason = "missingValue"
            case .typeMismatch(_, let detail): context = detail; reason = "typeMismatch"
            case .dataCorrupted(let detail): context = detail; reason = "dataCorrupted"
            @unknown default: throw error
            }
            let field = String(context.codingPath.map(\.stringValue).joined(separator: ".").prefix(512))
            Log.app.error("StorageMigrator.pi decode failed path=\(path) field=\(field) reason=\(reason) sourcePreserved=true")
            throw error
        }
    }

    private static func mapMigrationInvocations(in value: JSONValue, transform: ([String: JSONValue]) -> [String: JSONValue]) -> JSONValue {
        guard var root = value.objectValue, root["type"] == .string("agent"),
              var agent = root["agent"]?.objectValue, let steps = agent["steps"]?.arrayValue else { return value }
        agent["steps"] = .array(steps.map { value in
            guard var step = value.objectValue, step["type"] == .string("action"),
                  var action = step["action"]?.objectValue, action["type"] == .string("execute"),
                  var execution = action["execute"]?.objectValue, let effects = execution["effects"]?.arrayValue else { return value }
            execution["effects"] = .array(effects.compactMap { value in
                guard var effect = value.objectValue else { return value }
                if ["step", "widget", "media"].contains(effect["type"]?.stringValue ?? ""),
                   let fields = value.toAny() as? [String: Any] {
                    guard let legacy = canonicalLegacyEffect(fields) else { return nil }
                    effect = JSONValue.from(legacy).objectValue!
                }
                if effect["type"] == .string("invocation"), let invocation = effect["invocation"]?.objectValue {
                    effect["invocation"] = .object(transform(invocation))
                }
                return .object(effect)
            })
            action["execute"] = .object(execution)
            step["action"] = .object(action)
            return .object(step)
        })
        root["agent"] = .object(agent)
        return .object(root)
    }

    private static func durableCheckpointBoundary(_ checkpoint: AgentContextCheckpoint,
        records: [(turn: Turn, source: JSONValue, missingPurposes: Set<UUID>)], originalMessages: JSONValue?, store: DurableArtifactStore) throws -> Int? {
        let turns = records.map(\.turn)
        if let boundary = checkpoint.boundary(in: turns) { return boundary }
        guard checkpoint.schemaVersion == AgentContextCheckpoint.currentSchemaVersion,
              let boundary = turns.firstIndex(where: { $0.id == checkpoint.throughTurnID }) else {
            throw StorageMigrationError.invalidApplicationStorage("compaction checkpoint boundary")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let currentMessagesDigest = durableDigest(try encoder.encode(checkpoint.messages))
        let originalMessagesDigest = try originalMessages.map { durableDigest(try encoder.encode($0)) }
        guard currentMessagesDigest == checkpoint.messagesDigest || originalMessagesDigest == checkpoint.messagesDigest else {
            Log.app.error("StorageMigrator.pi checkpoint invalid component=messages turn=\(checkpoint.throughTurnID.rawValue)")
            throw StorageMigrationError.invalidApplicationStorage("compaction checkpoint messages")
        }
        var hash = SHA256()
        func append(_ value: JSONValue) throws {
            if let fields = value.objectValue, let reference = fields["oxPayload"]?.objectValue, reference["format"] == .int(1),
               let source = reference["source"], let offset = reference["offset"]?.intValue, let length = reference["length"]?.intValue {
                let original = try store.capturePayload(source, offset: offset, length: length)
                let decoded = try JSONDecoder().decode(JSONValue.self, from: original)
                hash.update(data: try encoder.encode(decoded))
                return
            }
            switch value {
            case .array(let values):
                hash.update(data: Data("[".utf8))
                for (index, item) in values.enumerated() {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    try append(item)
                }
                hash.update(data: Data("]".utf8))
            case .object(let fields):
                hash.update(data: Data("{".utf8))
                for (index, key) in fields.keys.sorted().enumerated() {
                    if index > 0 { hash.update(data: Data(",".utf8)) }
                    hash.update(data: try encoder.encode(key))
                    hash.update(data: Data(":".utf8))
                    try append(fields[key]!)
                }
                hash.update(data: Data("}".utf8))
            default: hash.update(data: try encoder.encode(value))
            }
        }
        hash.update(data: Data("[".utf8))
        for (index, record) in records[...boundary].enumerated() {
            if index > 0 { hash.update(data: Data(",".utf8)) }
            let canonical = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(record.turn))
            let original = mapMigrationInvocations(in: canonical) { invocation in
                var invocation = invocation
                if let id = invocation["id"]?.stringValue.flatMap(UUID.init(uuidString:)), record.missingPurposes.contains(id) {
                    invocation.removeValue(forKey: "purpose")
                }
                return invocation
            }
            try append(original)
        }
        hash.update(data: Data("]".utf8))
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == checkpoint.transcriptPrefixDigest else {
            Log.app.warning("StorageMigrator.pi checkpoint stale component=transcript turn=\(checkpoint.throughTurnID.rawValue)")
            return nil
        }
        return boundary
    }

    private static func durableExpectedContext(_ source: [Any]) throws -> [[String: Any]] {
        let messages = try source.map { value -> [String: Any] in
            guard let message = value as? [String: Any] else { throw StorageMigrationError.invalidApplicationStorage("model context") }
            return message
        }.filter { $0["role"] as? String != "assistant" || !["aborted", "error", "deferred"].contains($0["stopReason"] as? String ?? "") }
        var ordered: [[String: Any]] = []
        for (index, message) in messages.enumerated() {
            if message["role"] as? String == "toolResult" { continue }
            ordered.append(message)
            guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { continue }
            var results: [String: [String: Any]] = [:]
            for candidate in messages.dropFirst(index + 1) {
                if candidate["role"] as? String == "assistant" { break }
                if candidate["role"] as? String == "toolResult", let id = candidate["toolCallId"] as? String, results[id] == nil { results[id] = candidate }
            }
            for call in content where call["type"] as? String == "toolCall" {
                guard let id = call["id"] as? String, let name = call["name"] as? String, let timestamp = message["timestamp"] else {
                    throw StorageMigrationError.invalidApplicationStorage("tool context")
                }
                ordered.append(results[id] ?? ["role": "toolResult", "toolCallId": id, "toolName": name,
                    "content": [["type": "text", "text": "Tool result unavailable: history ends before this call completed."]],
                    "isError": true, "details": ["reason": "missing_result"], "timestamp": timestamp])
            }
        }
        return ordered
    }

    private static func durableSourceInventory(at root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        var directories = [root]
        while let directory = directories.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(url.lastPathComponent) }
                let path = String(url.path.dropFirst(root.path.count + 1))
                if values.isDirectory == true {
                    guard ["chats", "skills", "artifacts"].contains(path) || path.hasPrefix("chats/") || path.hasPrefix("skills/") else {
                        throw StorageMigrationError.invalidApplicationStorage(path)
                    }
                    directories.append(url); continue
                }
                guard values.isRegularFile == true,
                    [ProfileIO.configName, "MEMORY.md", "SOUL.md", "skill-selections.json", "artifacts/.saved.json"].contains(path)
                    || path.hasPrefix("skills/") || path.hasPrefix("artifacts/")
                    || (path.hasPrefix("chats/") && ["chat.json", "turns.jsonl", "context.json"].contains(url.lastPathComponent)) else {
                    throw StorageMigrationError.invalidApplicationStorage(path)
                }
                files[path] = try durableSourceFingerprint(path, at: root)
            }
        }
        return files
    }

    private static func durableSourceDescriptor(_ path: String, at root: URL) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
        do {
            for (index, part) in parts.enumerated() {
                let next = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0))
                guard next >= 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
                Darwin.close(descriptor); descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else {
                throw StorageMigrationError.invalidApplicationStorage(path)
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    private static func durableSourceFingerprint(_ path: String, at root: URL) throws -> String {
        let descriptor = try durableSourceDescriptor(path, at: root)
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
        var hash = SHA256()
        var size = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
            size += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size, size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func durableSourceFile(_ path: String, at root: URL, limit: Int = 64 * 1024 * 1024) throws -> Data {
        let descriptor = try durableSourceDescriptor(path, at: root)
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size <= limit else {
            Log.app.error("StorageMigrator.pi source too large path=\(path) bytes=\(before.st_size) limit=\(limit)")
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, output.count + count <= limit else { throw StorageMigrationError.invalidApplicationStorage(path) }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size, output.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        return output
    }

    private final class DurableTranscriptReader {
        private let descriptor: Int32
        private let store: DurableArtifactStore
        private var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        private var count = 0
        private var index = 0
        private var archived = 0
        private var writer: DurablePayloadWriter?
        private var recordStart = 0
        private var captures: [[String]: (offset: Int, length: Int)] = [:]
        private(set) var position = 0
        private(set) var externalized = 0

        init(descriptor: Int32, store: DurableArtifactStore) {
            self.descriptor = descriptor
            self.store = store
        }

        func next() throws -> (value: JSONValue, source: JSONValue)? {
            while let byte = try peek(), byte == 10 || byte == 13 { advance() }
            guard try peek() != nil else { return nil }
            recordStart = position
            captures.removeAll(keepingCapacity: true)
            writer = try store.payloadWriter()
            archived = index
            let value = try parse(path: [], build: true, depth: 0)
            try spaces()
            guard let value, try peek() == nil || peek() == 10 else { throw invalid() }
            try flush()
            let source = try writer!.finish()
            writer = nil
            return (bind(value, source: source), source)
        }

        private func bind(_ value: JSONValue, path: [String] = [], source: JSONValue) -> JSONValue {
            if let capture = captures[path] {
                let digest = source.objectValue!["sha256"]!.stringValue!
                return .object([
                    "oxPayload": .object(["format": .int(1), "source": source, "offset": .int(capture.offset), "length": .int(capture.length)]),
                    "preview": .string("Large result retained in file-backed storage. Read its complete JSON with ox.output.read({ id: 'payload:\(digest):\(capture.offset):\(capture.length)', purpose: 'Read archived result' }), then JSON.parse the returned string and filter before printing."),
                ])
            }
            switch value {
            case .array(let values): return .array(values.enumerated().map { bind($0.element, path: path + [String($0.offset)], source: source) })
            case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, bind($0.value, path: path + [$0.key], source: source)) }))
            default: return value
            }
        }

        private func parse(path: [String], build: Bool, depth: Int) throws -> JSONValue? {
            guard depth <= 128 else { throw invalid() }
            try spaces()
            if build, path.suffix(4) == ["invocation", "outcome", "succeeded", "_0"] || path.suffix(2) == ["invocation", "args"] {
                let start = position - recordStart
                _ = try parse(path: path, build: false, depth: depth)
                let length = position - recordStart - start
                try flush()
                if length <= DurablePayloadWriter.inlineLimit {
                    return try JSONDecoder().decode(JSONValue.self, from: writer!.read(offset: start, length: length))
                }
                externalized += 1
                captures[path] = (start, length)
                return .null
            }
            guard let byte = try peek() else { throw invalid() }
            if byte == 123 {
                advance()
                var fields: [String: JSONValue] = [:]
                var keys = Set<String>()
                try spaces()
                if try peek() == 125 { advance(); return build ? .object(fields) : nil }
                while true {
                    guard try peek() == 34 else { throw invalid() }
                    let data = try string(collect: true)
                    let key = try JSONDecoder().decode(String.self, from: data!)
                    guard keys.insert(key).inserted else { throw invalid() }
                    try spaces()
                    try expect(58)
                    let value = try parse(path: build ? path + [key] : [], build: build, depth: depth + 1)
                    if let value { fields[key] = value }
                    try spaces()
                    if try peek() == 125 { advance(); break }
                    try expect(44)
                    try spaces()
                }
                return build ? .object(fields) : nil
            }
            if byte == 91 {
                advance()
                var values: [JSONValue] = []
                var ordinal = 0
                try spaces()
                if try peek() == 93 { advance(); return build ? .array(values) : nil }
                while true {
                    if let value = try parse(path: build ? path + [String(ordinal)] : [], build: build, depth: depth + 1) { values.append(value) }
                    ordinal += 1
                    try spaces()
                    if try peek() == 93 { advance(); break }
                    try expect(44)
                }
                return build ? .array(values) : nil
            }
            if byte == 34 {
                let data = try string(collect: build)
                return try data.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
            }
            var token = Data()
            while let byte = try peek(), ![9, 10, 13, 32, 44, 93, 125].contains(byte) {
                guard token.count < 1024 else { throw invalid() }
                token.append(byte)
                advance()
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: token)
            return build ? value : nil
        }

        private func string(collect: Bool) throws -> Data? {
            try expect(34)
            var token: Data? = collect ? Data([34]) : nil
            var remaining = 0
            var lower: UInt8 = 0x80
            var upper: UInt8 = 0xbf
            while true {
                guard try peek() != nil else { throw invalid() }
                let start = index
                while index < count {
                    let byte = buffer[index]
                    if byte == 34 || byte == 92 || byte < 32 { break }
                    if remaining > 0 {
                        guard byte >= lower, byte <= upper else { throw invalid() }
                        remaining -= 1
                        lower = 0x80; upper = 0xbf
                    } else if byte >= 0x80 {
                        switch byte {
                        case 0xc2...0xdf: remaining = 1
                        case 0xe0: remaining = 2; lower = 0xa0
                        case 0xe1...0xec, 0xee...0xef: remaining = 2
                        case 0xed: remaining = 2; upper = 0x9f
                        case 0xf0: remaining = 3; lower = 0x90
                        case 0xf1...0xf3: remaining = 3
                        case 0xf4: remaining = 3; upper = 0x8f
                        default: throw invalid()
                        }
                    }
                    index += 1; position += 1
                }
                if collect {
                    token!.append(contentsOf: buffer[start..<index])
                    guard token!.count <= 64 * 1024 * 1024 else { throw invalid() }
                }
                guard let byte = try peek() else { throw invalid() }
                if byte == 34 {
                    guard remaining == 0 else { throw invalid() }
                    advance()
                    token?.append(34)
                    return token
                }
                if byte == 92 {
                    guard remaining == 0 else { throw invalid() }
                    advance()
                    token?.append(92)
                    guard let escape = try peek(), [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escape) else { throw invalid() }
                    advance()
                    token?.append(escape)
                    if escape == 117 {
                        for _ in 0..<4 {
                            guard let hex = try peek(), (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw invalid() }
                            advance()
                            token?.append(hex)
                        }
                    }
                } else if byte < 32 { throw invalid() }
            }
        }

        private func spaces() throws {
            while let byte = try peek(), [9, 13, 32].contains(byte) { advance() }
        }

        private func expect(_ byte: UInt8) throws {
            guard try peek() == byte else { throw invalid() }
            advance()
        }

        private func advance() { index += 1; position += 1 }

        private func peek() throws -> UInt8? {
            if index == count {
                try flush()
                repeat { count = Darwin.read(descriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
                guard count >= 0 else { throw invalid() }
                index = 0; archived = 0
            }
            return index < count ? buffer[index] : nil
        }

        private func flush() throws {
            if let writer, archived < index { try writer.append(Data(buffer[archived..<index])) }
            archived = index
        }

        private func invalid() -> StorageMigrationError { .invalidApplicationStorage("chat transcript near byte \(position)") }
    }

    private static func durableDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum LegacyLocalRepositoryState {
        case main(String)
        case empty
        case unsupported([String])
    }

    private struct LegacyProfileRecord: Decodable {
        let id: UUID
        let location: Profile.Location
        let bookmark: Data?
    }

    @MainActor
    static func migrateApplicationStorage() {
        Log.app.info("StorageMigrator.application start")
        migrateExternalProfiles(
            in: AppStoragePaths.applicationSupport,
            destination: AppStoragePaths.externalProfiles
        )
        migrateDeviceFolderGrants(
            in: AppStoragePaths.applicationSupport,
            destination: AppStoragePaths.deviceFolderGrants
        )
        migrateRemoteMCPServers(
            defaults: .standard,
            currentKey: ServiceManager.remoteMCPKey
        )
        migrateCustomLLMProviders(
            defaults: .standard,
            key: ProviderRegistry.customProvidersKey
        )
        migrateDefaultModel(defaults: .standard, fallbackRegion: AppRegion.shared.region)
        do { try removeRetiredGemma() }
        catch { Log.app.error("StorageMigrator.retiredGemma failed error=\(error.localizedDescription)") }
        do { try migrateProviderCatalog(defaults: .standard) }
        catch { Log.app.error("StorageMigrator.providerCatalog failed error=\(error.localizedDescription)") }
        migrateActionApprovalPolicies()
        migrateSavedServices()
        migrateTheme()
        removeLegacyRepositoryAuthorization()
        Log.app.info("StorageMigrator.application done")
    }

    private static func removeLegacyRepositoryAuthorization() {
        let account = "oauth:service-repository:github"
        guard Credentials.secret(for: account) != nil else { return }
        Credentials.clearSecret(for: account)
        Log.app.info("StorageMigrator.repositoryAuthorization removedLegacy=true reauthorizationRequired=true")
    }

    @MainActor
    static func prepare(storage: StorageRoot, services: ServiceManager) async throws {
        Log.app.info("StorageMigrator.prepare start")
        try recoverDurablePublications()
        try validateApplicationStorage()
        try migrateLegacySecrets()
        try migrateManagedOAuthAccounts()
        try migratePublicationToken()
        try await storage.resolve()
        try migrateSecretProviderKeys()
        try removeVerifiedLegacyProviderKeys()
        await services.prepareStorage()
        let manifests = try await services.storageManifestFiles()
        try migrateAPIServiceOAuthAccounts(manifests: manifests)
        try migrateSecretAPIServiceCredentials(manifests: manifests)
        Log.app.info("StorageMigrator.prepare done profile=\(storage.activeId?.uuidString ?? "nil")")
    }

    private static func removeRetiredGemma(
        defaults: UserDefaults = .standard,
        support: URL = AppStoragePaths.applicationSupport
    ) throws {
        let providerID = "on-device-gemma"
        let names = ["gemma-4-e2b-it.litertlm", "gemma-4-e2b-it.json"]
        let manager = FileManager.default
        var removedFiles = 0
        for directory in ["models", "on-device-models"] {
            let root = support.appendingPathComponent(directory, isDirectory: true)
            for name in names {
                let url = root.appendingPathComponent(name)
                guard manager.fileExists(atPath: url.path) else { continue }
                try manager.removeItem(at: url)
                removedFiles += 1
            }
        }
        let selection = defaults.data(forKey: ProviderRegistry.defaultModelKey)
            .flatMap { try? JSONDecoder().decode(ModelSelection.self, from: $0) }
        let clearedDefault = selection?.providerID == providerID
        if clearedDefault { defaults.removeObject(forKey: ProviderRegistry.defaultModelKey) }
        if removedFiles > 0 || clearedDefault {
            Log.app.info("StorageMigrator.retiredGemma removedFiles=\(removedFiles) clearedDefault=\(clearedDefault)")
        }
    }

    private static func migrateLegacySecrets() throws {
        let defaults = UserDefaults.standard
        let legacyIndexKey = "vault.index"
        let legacyAccounts = try Credentials.accounts(prefix: "vault:")
        let legacyData = defaults.data(forKey: legacyIndexKey)
        guard legacyData != nil || !legacyAccounts.isEmpty else { return }

        var convertedData: Data?
        if let legacyData {
            let data = try convertLegacySecretsIndex(legacyData)
            let converted = try JSONDecoder().decode(SecretIndex.self, from: data)
            try converted.validate()
            if let destination = defaults.data(forKey: Secret.indexKey) {
                let current = try JSONDecoder().decode(SecretIndex.self, from: destination)
                try current.validate()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(current) == encoder.encode(converted) else {
                    throw StorageMigrationError.collision(Secret.indexKey)
                }
            }
            convertedData = data
        }

        for account in legacyAccounts {
            guard let value = try Credentials.secretChecked(for: account) else { continue }
            let destination = "secret:" + String(account.dropFirst("vault:".count))
            if let current = try Credentials.secretChecked(for: destination) {
                guard current == value else { throw StorageMigrationError.collision(destination) }
            } else {
                try Credentials.setSecretChecked(value, for: destination,
                                                 accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
                guard try Credentials.secretChecked(for: destination) == value else {
                    throw StorageMigrationError.invalidApplicationStorage("secret credential")
                }
            }
        }
        if let convertedData, defaults.data(forKey: Secret.indexKey) == nil {
            defaults.set(convertedData, forKey: Secret.indexKey)
            guard defaults.data(forKey: Secret.indexKey) == convertedData else {
                throw StorageMigrationError.invalidApplicationStorage("secrets index")
            }
        }
        for account in legacyAccounts { try Credentials.deleteSecretChecked(for: account) }
        if legacyData != nil { defaults.removeObject(forKey: legacyIndexKey) }
        Log.app.info("StorageMigrator.secretsRenamed items=\(legacyAccounts.count) index=\(legacyData != nil)")
    }

    private static func convertLegacySecretsIndex(_ data: Data) throws -> Data {
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legacyBindings = document["bindings"] as? [[String: Any]] else {
            throw StorageMigrationError.invalidApplicationStorage("legacy secrets index")
        }
        document["bindings"] = try legacyBindings.map { legacy in
            var binding = legacy
            guard binding["secretKey"] == nil,
                  let key = binding.removeValue(forKey: "vaultKey") as? String else {
                throw StorageMigrationError.invalidApplicationStorage("legacy secrets binding")
            }
            binding["secretKey"] = key
            return binding
        }
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    @MainActor
    private static func migrateSecretAPIServiceCredentials(manifests: [Repository.ManifestFile]) throws {
        var migrated = 0
        for file in manifests {
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: file.data),
                  let definition = try? ServiceDefinition(manifest: raw, repositoryID: file.repositoryID,
                                                          provenance: file.provenance),
                  definition.isAPI, let baseURL = definition.baseURL,
                  let authValue = definition.manifest.objectValue?["auth"],
                  let auth = try? APIServiceAuth(authValue) else { continue }
            if case .none = auth { continue }
            if case .oauth = auth { continue }
            let identity = Data("\(definition.repositoryID ?? ""):\(definition.domain)".utf8)
            let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let account = "service:api:\(hash)"
            guard let rawCredential = try Credentials.secretChecked(for: account),
                  let data = rawCredential.data(using: .utf8),
                  let credential = try? JSONDecoder().decode(APIServiceCredential.self, from: data),
                  credential.version == 1,
                  credential.refreshToken == nil, credential.expiresAt == nil, credential.scopes == nil else { continue }
            let authorization = try APIServiceAuthorization(definition: definition)
            guard credential.binding == authorization.binding else { continue }
            let key = "ox.api-service.\(hash.prefix(24))"
            if let binding = try Secret.binding(kind: .apiService, id: hash) {
                guard binding.configurationFingerprint == credential.binding,
                      binding.destination == baseURL.absoluteString,
                      let current = try Secret.apiServiceCredential(id: hash, fingerprint: credential.binding, auth: auth),
                      current.0 == credential.secret, current.1 == credential.username else {
                    throw StorageMigrationError.collision(account)
                }
            } else if let current = try Secret.value(key: key) {
                let expected = try secretJSON(for: credential, auth: auth)
                guard current == expected else { throw StorageMigrationError.collision(account) }
                try Secret.bind(SecretBinding(consumerKind: .apiService, consumerID: hash, secretKey: key,
                                           destination: baseURL.absoluteString,
                                           configurationFingerprint: credential.binding,
                                           requiredFields: requiredSecretFields(for: auth)))
            } else {
                try Secret.saveAPIServiceCredential(credential, id: hash, displayName: definition.name,
                                                   destination: baseURL.absoluteString, auth: auth)
            }
            guard let current = try Secret.apiServiceCredential(id: hash, fingerprint: credential.binding, auth: auth),
                  current.0 == credential.secret, current.1 == credential.username else {
                throw StorageMigrationError.invalidApplicationStorage("API service credential")
            }
            try Credentials.deleteSecretChecked(for: account)
            migrated += 1
        }
        Log.app.info("StorageMigrator.secretAPIServiceCredentials migrated=\(migrated)")
    }

    private static func secretJSON(for credential: APIServiceCredential, auth: APIServiceAuth) throws -> String {
        let fields: [String: String]
        switch auth {
        case .apiKey: fields = ["apiKey": credential.secret]
        case .bearer: fields = ["token": credential.secret]
        case .basic: fields = ["username": credential.username ?? "", "password": credential.secret]
        case .none, .oauth: throw StorageMigrationError.invalidApplicationStorage("API service authentication")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func requiredSecretFields(for auth: APIServiceAuth) -> [String] {
        switch auth {
        case .apiKey: ["apiKey"]
        case .bearer: ["token"]
        case .basic: ["password", "username"]
        case .none, .oauth: []
        }
    }

    @MainActor
    private static func migrateSecretProviderKeys() throws {
        var migrated = 0
        for definition in ProviderRegistry.shared.definitions {
            let account = "api:\(definition.credentialID)"
            guard let legacy = try Credentials.secretChecked(for: account) else { continue }
            if let binding = try Secret.binding(kind: .provider, id: definition.credentialID) {
                guard binding.configurationFingerprint == Secret.providerFingerprint(definition),
                      binding.destination == definition.url.absoluteString,
                      Secret.providerKey(for: definition.credentialID) == legacy else {
                    throw StorageMigrationError.collision(account)
                }
            } else {
                let digest = SHA256.hash(data: Data(definition.credentialID.utf8))
                    .map { String(format: "%02x", $0) }.joined().prefix(24)
                let key = "ox.provider.\(digest)"
                if let existing = try Secret.value(key: key) {
                    let data = try JSONSerialization.data(withJSONObject: ["apiKey": legacy], options: [.sortedKeys])
                    guard existing == String(decoding: data, as: UTF8.self) else {
                        throw StorageMigrationError.collision(account)
                    }
                    try Secret.bindProvider(key: key, definition: definition)
                } else {
                    try Secret.saveProviderKey(legacy, definition: definition)
                }
                guard Secret.providerKey(for: definition.credentialID) == legacy else {
                    throw StorageMigrationError.invalidApplicationStorage("provider credential")
                }
            }
            try Credentials.deleteSecretChecked(for: account)
            migrated += 1
        }
        Log.app.info("StorageMigrator.secretProviderKeys migrated=\(migrated)")
    }

    @MainActor
    private static func removeVerifiedLegacyProviderKeys() throws {
        let definitions = ProviderRegistry.shared.definitions
        let definitionsByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        var aliases: [String: Set<String>] = [:]
        for definition in definitions where definition.id != definition.credentialID {
            aliases[definition.id, default: []].insert(definition.credentialID)
        }
        for bundled in ProviderRegistry.bundledDefinitions() {
            guard let definition = definitionsByID[bundled.definition.id],
                  bundled.legacyCredentialID != definition.credentialID else { continue }
            aliases[bundled.legacyCredentialID, default: []].insert(definition.credentialID)
        }
        var removed = 0
        var retained = 0
        for (sourceID, targetIDs) in aliases {
            let account = "api:\(sourceID)"
            guard let old = try Credentials.secretChecked(for: account) else { continue }
            guard targetIDs.contains(where: { Secret.providerKey(for: $0) == old }) else {
                retained += 1
                continue
            }
            try Credentials.deleteSecretChecked(for: account)
            removed += 1
        }
        Log.app.info("StorageMigrator.legacyProviderCopies removed=\(removed) retained=\(retained)")
    }

    @MainActor
    private static func migrateManagedOAuthAccounts() throws {
        var moved = 0
        for id in ["chatgpt", "xai", "github-copilot", "openrouter"] {
            if try moveCredential(from: "oauth:\(id)", to: ManagedOAuthAccount.modelProvider(id)) { moved += 1 }
        }
        for definition in ProviderRegistry.shared.definitions where definition.auth.kind == .oauth {
            let old = "oauth:\(definition.credentialID)"
            if try moveCredential(from: old, to: ManagedOAuthAccount.modelProvider(definition.credentialID)) { moved += 1 }
        }
        for old in try Credentials.accounts(prefix: "oauth:mcp:") {
            let hash = String(old.dropFirst("oauth:mcp:".count))
            if try moveCredential(from: old, to: ManagedOAuthAccount.mcpService(hash)) { moved += 1 }
        }
        Log.app.info("StorageMigrator.managedOAuth moved=\(moved)")
    }

    private static func migrateAPIServiceOAuthAccounts(manifests: [Repository.ManifestFile]) throws {
        var moved = 0
        for file in manifests {
            guard let raw = try? JSONDecoder().decode(JSONValue.self, from: file.data),
                  let definition = try? ServiceDefinition(manifest: raw, repositoryID: file.repositoryID,
                                                          provenance: file.provenance),
                  definition.isAPI, let authValue = definition.manifest.objectValue?["auth"],
                  let auth = try? APIServiceAuth(authValue) else { continue }
            guard case .oauth = auth else { continue }
            let identity = Data("\(definition.repositoryID ?? ""):\(definition.domain)".utf8)
            let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            if try moveCredential(from: "service:api:\(hash)", to: ManagedOAuthAccount.apiService(hash)) {
                moved += 1
            }
        }
        Log.app.info("StorageMigrator.apiServiceOAuth moved=\(moved)")
    }

    private static func moveCredential(from source: String, to destination: String) throws -> Bool {
        guard source != destination, let value = try Credentials.secretChecked(for: source) else { return false }
        if let existing = try Credentials.secretChecked(for: destination) {
            guard existing == value else { throw StorageMigrationError.collision(destination) }
        } else {
            try Credentials.setSecretChecked(value, for: destination)
            guard try Credentials.secretChecked(for: destination) == value else {
                throw StorageMigrationError.invalidApplicationStorage("managed OAuth")
            }
        }
        try Credentials.deleteSecretChecked(for: source)
        return true
    }

    private static func migratePublicationToken() throws {
        let account = "pat:service-repository:github"
        guard let old = try Credentials.secretChecked(for: account) else { return }
        if let current = Secret.publicationToken() {
            guard current == old else { throw StorageMigrationError.collision(account) }
        } else {
            try Secret.savePublicationToken(old)
            guard Secret.publicationToken() == old else {
                throw StorageMigrationError.invalidApplicationStorage("repository publication token")
            }
        }
        try Credentials.deleteSecretChecked(for: account)
        Log.app.info("StorageMigrator.publicationToken migrated=1")
    }

    static func migrate(_ profile: Profile) async throws -> Profile {
        try recoverDurablePublications()
        guard let config = ProfileIO.readConfig(at: profile.url), config.id == profile.id, sourceVersion(for: config.version) != nil else {
            Log.app.error("StorageMigrator.reject unknown version=\(profile.version) id=\(profile.id)")
            throw StorageMigrationError.unsupportedProfileVersion(profile.name, profile.version)
        }
        var migrated = profile
        migrated.version = config.version
        if config.version == durableProfileVersion {
            guard profile.location == .local, FileManager.default.fileExists(atPath: profile.url.appendingPathComponent("state.sqlite").path) else {
                throw StorageMigrationError.invalidApplicationStorage("local Pi Profile database")
            }
            return migrated
        }
        guard profile.location == .local else { throw StorageMigrationError.invalidApplicationStorage("Pi Profiles require an offline local import; live cloud/external database synchronization is unsupported") }
        let working = profile.url.deletingLastPathComponent().appendingPathComponent(".pi-source-work-" + UUID().uuidString)
        let inventory = try await Task.detached(priority: .userInitiated) {
            try copyMigrationSource(from: profile.url, to: working)
        }.value
        var draft = migrated
        draft.url = working
        try await migrateProfile(draft)
        draft.version = nativeProfileVersion
        let destination = profile.url.deletingLastPathComponent().appendingPathComponent(".pi-stage-" + UUID().uuidString)
        let staged = try await stageDurableProfile(draft, at: destination)
        guard var fields = staged.objectValue, try migrationSourceInventory(at: profile.url) == inventory else {
            throw StorageMigrationError.profileMigrationFailed(profile.name)
        }
        fields["sourceInventory"] = .from(inventory)
        let result = JSONValue.object(fields)
        let journalRoot = try durableJournalDirectory(profile.id)
        let backup = journalRoot.appendingPathComponent("source-" + UUID().uuidString)
        let journal: [String: Any] = ["format": 1, "phase": "prepared", "profileID": profile.id.uuidString,
            "root": profile.url.path, "stage": destination.path, "backup": backup.path, "result": result.toAny()]
        try writeDurableJournal(journal, profileID: profile.id)
        try publishDurableJournal(journal)
        do { try FileManager.default.removeItem(at: working) }
        catch { Log.app.warning("StorageMigrator.pi workingCopy cleanup deferred error=\(error.localizedDescription)") }
        migrated.version = durableProfileVersion
        Log.app.info("StorageMigrator.pi activated id=\(profile.id) sourcePreserved=true")
        return migrated
    }

    private static func migrateTheme(
        defaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = UserDefaults(suiteName: AppStoragePaths.appGroupIdentifier)
    ) {
        let key = "app.theme"
        guard let legacyValue = defaults.string(forKey: key) else { return }
        guard let sharedDefaults else {
            Log.app.error("StorageMigrator.theme app-group unavailable")
            return
        }
        if sharedDefaults.string(forKey: key) == nil {
            sharedDefaults.set(legacyValue, forKey: key)
        }
        let saved = sharedDefaults.synchronize()
        if saved {
            defaults.removeObject(forKey: key)
            defaults.synchronize()
        }
        Log.app.info("StorageMigrator.theme migrated saved=\(saved)")
    }

    private static func migrateActionApprovalPolicies(defaults: UserDefaults = .standard) {
        let retired = Set(["ox.app.inspect"])
        if let data = defaults.data(forKey: ServiceManager.actionPoliciesKey) {
            do {
                let stored = try JSONDecoder().decode(ActionPolicyConfiguration.self, from: data)
                let migratedFormat = stored.format == ActionPolicyConfiguration.legacyFormat
                guard stored.format == ActionPolicyConfiguration.currentFormat || migratedFormat else {
                    Log.app.error("StorageMigrator.actionPolicies deferred format=\(stored.format)")
                    return
                }
                var configuration = migratedFormat
                    ? ActionPolicyConfiguration(
                        defaultPolicy: stored.defaultPolicy == .ask ? nil : stored.defaultPolicy,
                        sources: stored.sources,
                        actions: stored.actions
                    )
                    : stored
                let originalCount = configuration.actions.count
                let storedActions = configuration.actions
                let renamedCount = storedActions.keys.filter { canonicalApprovalAction($0) != $0 }.count
                var migratedActions = storedActions.reduce(into: [String: ActionPolicy]()) { actions, entry in
                    guard !isRetiredApproval(entry.key, retired: retired), !entry.key.hasPrefix("ios:files:") else { return }
                    let action = canonicalApprovalAction(entry.key)
                    guard action == entry.key else { return }
                    actions[action] = entry.value
                }
                for entry in storedActions.sorted(by: { $0.key < $1.key }) {
                    guard !isRetiredApproval(entry.key, retired: retired), !entry.key.hasPrefix("ios:files:") else { continue }
                    let action = canonicalApprovalAction(entry.key)
                    if migratedActions[action] == nil { migratedActions[action] = entry.value }
                }
                configuration.actions = migratedActions
                if migratedFormat || configuration.actions != storedActions,
                   let updated = try? JSONEncoder().encode(configuration) {
                    defaults.set(updated, forKey: ServiceManager.actionPoliciesKey)
                }
                defaults.removeObject(forKey: ServiceManager.legacyAutoApproveActionsKey)
                defaults.removeObject(forKey: ServiceManager.legacyAutoApproveAllKey)
                defaults.synchronize()
                Log.app.info("StorageMigrator.actionPolicies current format=\(configuration.format) migrated=\(migratedFormat) actions=\(configuration.actions.count) renamed=\(renamedCount) removed=\(originalCount - configuration.actions.count)")
            } catch {
                Log.app.error("StorageMigrator.actionPolicies invalid preserved=true error=\(error.localizedDescription)")
            }
            return
        }

        let legacy = defaults.stringArray(forKey: ServiceManager.legacyAutoApproveActionsKey) ?? []
        let retained = Set(legacy).filter { !isRetiredApproval($0, retired: retired) && !$0.hasPrefix("ios:files:") }
        let actions = retained.sorted().reduce(into: [String: ActionPolicy]()) { actions, action in
            actions[canonicalApprovalAction(action)] = .allow
        }
        let allowsAll = defaults.bool(forKey: ServiceManager.legacyAutoApproveAllKey)
        let configuration = ActionPolicyConfiguration(
            defaultPolicy: allowsAll ? .allow : nil,
            actions: actions
        )
        do {
            let encoded = try JSONEncoder().encode(configuration)
            defaults.set(encoded, forKey: ServiceManager.actionPoliciesKey)
            guard defaults.synchronize(), defaults.data(forKey: ServiceManager.actionPoliciesKey) == encoded else {
                Log.app.error("StorageMigrator.actionPolicies write failed legacyPreserved=true")
                return
            }
            defaults.removeObject(forKey: ServiceManager.legacyAutoApproveActionsKey)
            defaults.removeObject(forKey: ServiceManager.legacyAutoApproveAllKey)
            defaults.synchronize()
            Log.app.info("StorageMigrator.actionPolicies migrated actions=\(configuration.actions.count) retired=\(legacy.count - retained.count) default=\(configuration.defaultPolicy?.rawValue ?? "automatic")")
        } catch {
            Log.app.error("StorageMigrator.actionPolicies encode failed legacyPreserved=true error=\(error.localizedDescription)")
        }
    }

    private static func isRetiredApproval(_ action: String, retired: Set<String>) -> Bool {
        retired.contains(action) || BrowserFunctionCatalog.isLegacyApproval(action)
    }

    private static func migrateSavedServices(defaults: UserDefaults = .standard) {
        guard let stored = defaults.stringArray(forKey: ServiceManager.savedKey) else { return }
        let retained = stored.filter { $0 != BrowserFunctionCatalog.internalDomain }
        guard retained != stored else { return }
        defaults.set(retained, forKey: ServiceManager.savedKey)
        defaults.synchronize()
        Log.app.info("StorageMigrator.savedServices retiredBrowser=\(stored.count - retained.count)")
    }

    private static func canonicalApprovalAction(_ action: String) -> String {
        switch action {
        case "ox.chat.start": return "ox.conversation.start"
        case "ox.chat.delete": return "ox.conversation.delete"
        default: break
        }
        let renamed = action.replacingOccurrences(of: "ox.service.repository.", with: "ox.repository.")
            .replacingOccurrences(of: "ox.service.git.", with: "ox.repository.git.")
            .replacingOccurrences(of: "ox.app.serviceRepositories", with: "ox.app.repositories")
        if renamed != action { return renamed }
        if action.hasPrefix("ox.") || action.hasPrefix("web:") || action.hasPrefix("api:")
            || action.hasPrefix("ios:") || action.hasPrefix("mcp:") {
            return action
        }
        guard let separator = action.lastIndex(of: ":"), action[..<separator].contains(".") else { return action }
        return "web:\(action)"
    }

    private static func validateApplicationStorage() throws {
        let manager = FileManager.default
        let support = AppStoragePaths.applicationSupport
        let legacyProfiles = support
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent("profiles.json", isDirectory: false)
        if manager.fileExists(atPath: legacyProfiles.path),
           !manager.fileExists(atPath: AppStoragePaths.externalProfiles.path) {
            throw StorageMigrationError.invalidApplicationStorage("Profile catalog")
        }
        try validateFile(
            AppStoragePaths.externalProfiles,
            as: [ProfileStore.ExternalRecord].self,
            component: "Profile catalog"
        )

        let legacyGrants = support
            .appendingPathComponent("device-folders", isDirectory: true)
            .appendingPathComponent("grants.json", isDirectory: false)
        if manager.fileExists(atPath: legacyGrants.path),
           !manager.fileExists(atPath: AppStoragePaths.deviceFolderGrants.path) {
            throw StorageMigrationError.invalidApplicationStorage("folder grants")
        }
        try validateFile(
            AppStoragePaths.deviceFolderGrants,
            as: [DeviceFolderStore.Grant].self,
            component: "folder grants"
        )
        let defaults = UserDefaults.standard
        do {
            guard let data = defaults.data(forKey: ProviderRegistry.catalogKey) else {
                throw StorageMigrationError.invalidApplicationStorage("provider catalog")
            }
            try JSONDecoder().decode(ProviderCatalog.self, from: data).validate()
            if let selection = defaults.data(forKey: ProviderRegistry.defaultModelKey),
               let object = try JSONSerialization.jsonObject(with: selection) as? [String: Any], object["region"] != nil {
                throw StorageMigrationError.invalidApplicationStorage("provider selection")
            }
        } catch { throw StorageMigrationError.invalidApplicationStorage("provider catalog") }
        if defaults.object(forKey: ServiceManager.remoteMCPKey) != nil {
            guard let data = defaults.data(forKey: ServiceManager.remoteMCPKey),
                  (try? JSONDecoder().decode([ServiceManager.PersistedRemoteMCP].self, from: data)) != nil else {
                throw StorageMigrationError.invalidApplicationStorage("remote MCP server")
            }
        }
        if defaults.object(forKey: ProviderRegistry.customProvidersKey) != nil {
            guard let data = defaults.data(forKey: ProviderRegistry.customProvidersKey),
                  (try? JSONDecoder().decode([CustomLLMProvider].self, from: data)) != nil else {
                throw StorageMigrationError.invalidApplicationStorage("custom provider")
            }
        }
        if defaults.object(forKey: ProviderRegistry.defaultModelKey) != nil {
            guard let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
                  (try? JSONDecoder().decode(ModelSelection.self, from: data)) != nil else {
                throw StorageMigrationError.invalidApplicationStorage("default model")
            }
        }
    }

    private static func validateFile<Value: Decodable>(
        _ url: URL,
        as type: Value.Type,
        component: String
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(type, from: data)
        } catch {
            Log.app.error("StorageMigrator.validate component=\(component) failed=\(error.localizedDescription)")
            throw StorageMigrationError.invalidApplicationStorage(component)
        }
    }

    private static func migrateExternalProfiles(
        in support: URL,
        destination: URL? = nil
    ) {
        let destination = destination ?? AppStoragePaths.externalProfiles(in: support)
        let legacyDirectory = support.appendingPathComponent("profiles", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("profiles.json", isDirectory: false)
        if let data = try? Data(contentsOf: destination),
           (try? JSONDecoder().decode([ProfileStore.ExternalRecord].self, from: data)) != nil {
            do {
                try removeLegacyFile(legacyURL, directory: legacyDirectory)
            } catch {
                Log.app.error("StorageMigrator.externalProfiles cleanup failed: \(error.localizedDescription)")
            }
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([LegacyProfileRecord].self, from: data) else {
            return
        }
        let records: [ProfileStore.ExternalRecord] = legacy.compactMap { record in
            guard record.location == .external, let bookmark = record.bookmark else { return nil }
            return ProfileStore.ExternalRecord(id: record.id, bookmark: bookmark)
        }
        do {
            if !records.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var encoded = try encoder.encode(records)
                encoded.append(0x0A)
                try encoded.write(to: destination, options: Data.WritingOptions.atomic)
            }
            try removeLegacyFile(legacyURL, directory: legacyDirectory)
            Log.app.info("StorageMigrator.externalProfiles migrated=\(records.count) discardedManaged=\(legacy.count - records.count)")
        } catch {
            Log.app.error("StorageMigrator.externalProfiles failed: \(error.localizedDescription)")
        }
    }

    private static func migrateDeviceFolderGrants(in support: URL, destination: URL? = nil) {
        let destination = destination ?? AppStoragePaths.deviceFolderGrants(in: support)
        let legacyDirectory = support.appendingPathComponent("device-folders", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("grants.json", isDirectory: false)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: destination),
           (try? decoder.decode([DeviceFolderStore.Grant].self, from: data)) != nil {
            do {
                try removeLegacyFile(legacyURL, directory: legacyDirectory)
            } catch {
                Log.app.error("StorageMigrator.deviceFolderGrants cleanup failed: \(error.localizedDescription)")
            }
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let grants = try? decoder.decode([DeviceFolderStore.Grant].self, from: data) else {
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
            try? AppStoragePaths.excludeFromBackup(destination)
            try removeLegacyFile(legacyURL, directory: legacyDirectory)
            Log.app.info("StorageMigrator.deviceFolderGrants migrated=\(grants.count)")
        } catch {
            Log.app.error("StorageMigrator.deviceFolderGrants failed: \(error.localizedDescription)")
        }
    }

    private static func migrateRemoteMCPServers(
        defaults: UserDefaults,
        currentKey: String
    ) {
        let legacyKey = "remoteMCPEndpoints"
        if let data = defaults.data(forKey: currentKey),
           (try? JSONDecoder().decode([ServiceManager.PersistedRemoteMCP].self, from: data)) != nil {
            defaults.removeObject(forKey: legacyKey)
            return
        }
        let migrated = (defaults.stringArray(forKey: legacyKey) ?? []).map {
            ServiceManager.PersistedRemoteMCP(endpoint: $0, transport: nil)
        }
        guard !migrated.isEmpty else { return }
        do {
            defaults.set(try JSONEncoder().encode(migrated), forKey: currentKey)
            defaults.removeObject(forKey: legacyKey)
            Log.app.info("StorageMigrator.remoteMCPServers migrated=\(migrated.count)")
        } catch {
            Log.app.error("StorageMigrator.remoteMCPServers failed: \(error.localizedDescription)")
        }
    }

    private static func migrateCustomLLMProviders(
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let providers = try JSONDecoder().decode([CustomLLMProvider].self, from: data)
            let legacyModelsStored = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            if legacyModelsStored?.contains(where: { $0["models"] != nil }) == true {
                defaults.set(try JSONEncoder().encode(providers), forKey: key)
                Log.app.info("StorageMigrator.customLLMProviders removed legacy models providers=\(providers.count)")
            }
        } catch {
            Log.app.error("StorageMigrator.customLLMProviders failed error=\(error.localizedDescription)")
        }
    }

    private static func migrateDefaultModel(
        defaults: UserDefaults,
        fallbackRegion: LLMRegion
    ) {
        let selectedModelsKey = "llm.selectedModels"
        let selectedReasoningEffortsKey = "llm.selectedReasoningEfforts"
        let defaultProviderKey = "llm.defaultClient"
        let defaultRegionKey = "llm.defaultRegion"
        let legacyKeys = [
            selectedModelsKey,
            selectedReasoningEffortsKey,
            defaultProviderKey,
            defaultRegionKey,
        ]
        if let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
           let stored = try? JSONDecoder().decode(ModelSelection.self, from: data) {
            var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let region = (object?["region"] as? String).flatMap(LLMRegion.init(rawValue:)) {
                object?["providerID"] = providerIdentity(stored.providerID, region: region, modelID: stored.modelID)
                object?.removeValue(forKey: "region")
                if let object, let current = try? JSONSerialization.data(withJSONObject: object) {
                    defaults.set(current, forKey: ProviderRegistry.defaultModelKey)
                }
            }
            legacyKeys.forEach { defaults.removeObject(forKey: $0) }
            return
        }
        guard defaults.object(forKey: ProviderRegistry.defaultModelKey) == nil else { return }
        let hasLegacyValue = legacyKeys.contains { defaults.object(forKey: $0) != nil }
        guard hasLegacyValue else { return }
        let region = defaults.string(forKey: defaultRegionKey).flatMap(LLMRegion.init(rawValue:)) ?? fallbackRegion
        let providerID = defaults.string(forKey: defaultProviderKey)
        let selectedModels = defaults.dictionary(forKey: selectedModelsKey) as? [String: String] ?? [:]
        let modelID = providerID.flatMap {
            selectedModels["\(region.rawValue)\u{1F}\($0)"] ?? selectedModels[$0]
        }
        let selection: ModelSelection?
        if let providerID, let modelID {
            let efforts = defaults.dictionary(forKey: selectedReasoningEffortsKey) as? [String: String] ?? [:]
            selection = ModelSelection(
                region: region,
                providerID: providerIdentity(providerID, region: region, modelID: modelID),
                modelID: modelID,
                reasoningEffort: efforts["\(providerID)\u{1F}\(modelID)"]
            )
        } else {
            selection = nil
        }
        do {
            if let selection {
                defaults.set(try JSONEncoder().encode(selection), forKey: ProviderRegistry.defaultModelKey)
                guard let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
                      (try? JSONDecoder().decode(ModelSelection.self, from: data)) == selection else {
                    Log.app.error("StorageMigrator.defaultModel verification failed")
                    return
                }
            }
            legacyKeys.forEach { defaults.removeObject(forKey: $0) }
            Log.app.info("StorageMigrator.defaultModel migrated complete=\(selection != nil)")
        } catch {
            Log.app.error("StorageMigrator.defaultModel failed error=\(error.localizedDescription)")
        }
    }

    static func migrateLegacyLocalRepository(at root: URL, seed: URL?) throws {
        let manager = FileManager.default
        let metadata = root.appendingPathComponent(".git", isDirectory: true)
        guard manager.fileExists(atPath: metadata.path) else { return }
        let headURL = metadata.appendingPathComponent("HEAD", isDirectory: false)
        guard let headData = try? Data(contentsOf: headURL),
              String(decoding: headData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                == "ref: refs/heads/master"
        else { return }

        switch try legacyLocalRepositoryState(at: root) {
        case .main(let expectedCommit):
            do {
                try Data("ref: refs/heads/main\n".utf8).write(to: headURL, options: .atomic)
                guard try localRepositoryCommit(at: root) == expectedCommit else {
                    throw StorageMigrationError.invalidRepairedLocalRepository
                }
            } catch {
                do {
                    try headData.write(to: headURL, options: .atomic)
                } catch let rollbackError {
                    throw StorageMigrationError.localRepositoryRollbackFailed(rollbackError.localizedDescription)
                }
                throw error
            }
            Log.service.info("StorageMigrator.localRepository repaired=head commit=\(expectedCommit.prefix(12))")
        case .empty:
            guard let seed, manager.fileExists(atPath: seed.path) else {
                throw StorageMigrationError.invalidLocalRepositorySeed
            }
            try replaceLegacyLocalRepositoryMetadata(at: root, metadata: metadata, seed: seed)
            Log.service.info("StorageMigrator.localRepository repaired=seed preservedWorkingTree=true")
        case .unsupported(let references):
            Log.service.warning("StorageMigrator.localRepository skipped references=\(references.joined(separator: ","))")
        }
    }

    static func migrateLegacyLocalServiceManifests(at root: URL) throws {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard !repository.isHEADDetached else { return }
        let status = try repository.status()
        let changedPaths = Set(status.flatMap {
            [
                $0.workingTree?.newFile.path,
                $0.workingTree?.oldFile.path,
                $0.index?.newFile.path,
                $0.index?.oldFile.path,
            ].compactMap { $0 }
        })
        let hasStagedChanges = status.contains {
            $0.status.contains(where: {
                [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0)
            })
        }
        let manager = FileManager.default
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        guard manager.fileExists(atPath: webRoot.path) else { return }
        var cleanPaths: [String] = []
        var pendingCount = 0
        for directory in try manager.contentsOfDirectory(
            at: webRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let legacyURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            let currentURL = directory.appendingPathComponent("service.json", isDirectory: false)
            guard manager.fileExists(atPath: legacyURL.path),
                  !manager.fileExists(atPath: currentURL.path) else { continue }
            let rootPath = "web/\(directory.lastPathComponent)"
            let legacyPath = "\(rootPath)/manifest.json"
            let currentPath = "\(rootPath)/service.json"
            try manager.moveItem(at: legacyURL, to: currentURL)
            if changedPaths.contains(legacyPath) || changedPaths.contains(currentPath) {
                pendingCount += 1
            } else {
                cleanPaths.append(contentsOf: [legacyPath, currentPath])
            }
        }
        if !cleanPaths.isEmpty, !hasStagedChanges {
            try repository.add(paths: cleanPaths.sorted())
            let commit = try repository.commit(message: "Rename Local service manifests to service.json")
            Log.service.info("StorageMigrator.localServiceManifests saved=\(cleanPaths.count / 2) commit=\(commit.id.abbreviated)")
        } else if hasStagedChanges {
            pendingCount += cleanPaths.count / 2
        }
        if pendingCount > 0 {
            Log.service.info("StorageMigrator.localServiceManifests pending=\(pendingCount)")
        }
    }

    static func migrateLegacyLocalServiceActions(at root: URL) throws {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard !repository.isHEADDetached else { return }
        let status = try repository.status()
        let dirtyPaths = Set(status.compactMap {
            $0.workingTree?.newFile.path ?? $0.index?.newFile.path ?? $0.index?.oldFile.path
        })
        let hasStagedChanges = status.contains {
            $0.status.contains(where: {
                [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0)
            })
        }
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        guard FileManager.default.fileExists(atPath: webRoot.path) else { return }
        var cleanPaths: [String] = []
        var dirtyCount = 0
        for directory in try FileManager.default.contentsOfDirectory(
            at: webRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let actionsURL = directory.appendingPathComponent("actions.js", isDirectory: false)
            let currentManifestURL = directory.appendingPathComponent("service.json", isDirectory: false)
            let legacyManifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            let manifestURL = FileManager.default.fileExists(atPath: currentManifestURL.path) ? currentManifestURL : legacyManifestURL
            guard let source = try? String(contentsOf: actionsURL, encoding: .utf8),
                  source.range(of: #"window\s*\.\s*ox\s*\.\s*install\s*\("#, options: .regularExpression) == nil,
                  source.contains("callServiceAction"),
                  let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  let actions = manifest["actions"] as? [[String: Any]],
                  actions.count > 0
            else { continue }
            let identifiers = actions.compactMap { $0["id"] as? String }
            guard identifiers.count == actions.count else { continue }
            let migrated = try migratedServiceActions(source, identifiers: identifiers)
            try migrated.write(to: actionsURL, atomically: true, encoding: .utf8)
            let path = "web/\(directory.lastPathComponent)/actions.js"
            if dirtyPaths.contains(path) {
                dirtyCount += 1
            } else {
                cleanPaths.append(path)
            }
        }
        if !cleanPaths.isEmpty, !hasStagedChanges {
            try repository.add(paths: cleanPaths.sorted())
            let commit = try repository.commit(message: "Migrate Local service actions to ABI v1")
            Log.service.info("StorageMigrator.localServiceActions saved=\(cleanPaths.count) commit=\(commit.id.abbreviated)")
        }
        if dirtyCount > 0 || (!cleanPaths.isEmpty && hasStagedChanges) {
            Log.service.info("StorageMigrator.localServiceActions pending=\(dirtyCount + (hasStagedChanges ? cleanPaths.count : 0))")
        }
    }

    static func migrateLocalRepositoryVersion(at root: URL) throws {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json", isDirectory: false)
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json", isDirectory: false)
        guard let data = try? Data(contentsOf: packageURL),
              var package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["version"] as? Int == 1 else { return }
        let repository = try SwiftGitX.Repository.open(at: root)
        guard !repository.isHEADDetached else { return }
        let path = packageURL.lastPathComponent
        let status = try repository.status()
        let dirty = status.contains { [$0.workingTree?.newFile.path, $0.index?.newFile.path].contains(path) }
        let hasStagedChanges = status.contains {
            $0.status.contains(where: {
                [.indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange, .conflicted].contains($0)
            })
        }
        package["version"] = 2
        var output = try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
        output.append(0x0A)
        try output.write(to: packageURL, options: .atomic)
        guard !dirty, !hasStagedChanges else {
            Log.service.info("StorageMigrator.localRepositoryVersion from=1 to=2 pending=true")
            return
        }
        try repository.add(paths: [path])
        let commit = try repository.commit(message: "Upgrade Local services repository to version 2")
        Log.service.info("StorageMigrator.localRepositoryVersion from=1 to=2 commit=\(commit.id.abbreviated)")
    }

    static func prepareRepository(at root: URL, local: Bool) throws -> URL {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json")
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json")
        let metadata = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard metadata.isSymbolicLink != true, (metadata.fileSize ?? 0) <= 512_000 else { throw SkillError.invalidPackage }
        let data = try Data(contentsOf: packageURL)
        guard let package = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = package["version"] as? Int else {
            throw StorageMigrationError.invalidApplicationStorage("repository")
        }
        guard version != 3 else { return root }
        guard version == 2 else { throw StorageMigrationError.invalidApplicationStorage("repository version \(version)") }
        if local {
            let git = try SwiftGitX.Repository.open(at: root)
            if git.isHEADDetached {
                guard try git.status().isEmpty, let commit = try git.HEAD.target as? Commit else {
                    throw StorageMigrationError.invalidApplicationStorage("historical repository with unfinished changes; return to latest")
                }
                let identity = SHA256.hash(data: Data((root.path + commit.id.hex).utf8)).map { String(format: "%02x", $0) }.joined()
                let view = AppStoragePaths.caches.appendingPathComponent("RepositoryViews/\(identity)")
                if manager.fileExists(atPath: view.appendingPathComponent("repository.json").path),
                   let saved = try? JSONSerialization.jsonObject(with: Data(contentsOf: view.appendingPathComponent("repository.json"))) as? [String: Any], saved["version"] as? Int == 3 { return view }
                if manager.fileExists(atPath: view.path) { try manager.removeItem(at: view) }
                try manager.createDirectory(at: view, withIntermediateDirectories: true)
                for file in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) where file.lastPathComponent != ".git" {
                    guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkillError.invalidPackage }
                    try manager.copyItem(at: file, to: view.appendingPathComponent(file.lastPathComponent))
                }
                try migrateRepositorySkills(at: view)
                return view
            }
        }
        try migrateRepositorySkills(at: root)
        return root
    }

    private static func migratedSkillName(domain: String, name: String) -> String {
        let known = ["xiaohongshu.com:research": "xiaohongshu-research", "www.1point3acres.com:research": "1point3acres-research", "news.ycombinator.com:display": "hacker-news-display", "x.com:research": "x-research", "amazon.com:product-research": "product-research"]
        return known[domain + ":" + name] ?? SkillFiles.slug(domain + "-" + name)
    }

    private static func migratedSkillInstructions(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "skills/system:", with: "skills/")
            .replacingOccurrences(of: "ox.service.repository.", with: "ox.repository.")
            .replacingOccurrences(of: "ox.service.git.", with: "ox.repository.git.")
            .replacingOccurrences(of: "ox.app.serviceRepositories", with: "ox.app.repositories")
        let regex = try! NSRegularExpression(pattern: "skills/service:([a-z0-9.-]+):([a-z0-9-]+)/")
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: value), let domain = Range(match.range(at: 1), in: value), let name = Range(match.range(at: 2), in: value) else { continue }
            let replacement = "skills/" + migratedSkillName(domain: String(value[domain]), name: String(value[name])) + "/"
            value.replaceSubrange(whole, with: replacement)
        }
        return value
    }

    private static func migrateRepositorySkills(at root: URL) throws {
        let manager = FileManager.default
        let current = root.appendingPathComponent("repository.json")
        let packageURL = manager.fileExists(atPath: current.path) ? current : root.appendingPathComponent("ox.json")
        guard var package = try JSONSerialization.jsonObject(with: Data(contentsOf: packageURL)) as? [String: Any] else { throw SkillError.invalidPackage }
        guard package["version"] as? Int == 2 else { return }
        guard let services = package["services"] as? [String], services.count <= 256 else { throw SkillError.invalidPackage }
        let git = try? SwiftGitX.Repository.open(at: root)
        let clean = try git?.status().isEmpty == true
        let backup = root.deletingLastPathComponent().appendingPathComponent(".\(root.lastPathComponent)-repository-v2-backup", isDirectory: true)
        if !manager.fileExists(atPath: backup.path) { try manager.createDirectory(at: backup, withIntermediateDirectories: true) }
        let packageBackup = backup.appendingPathComponent(packageURL.lastPathComponent)
        if !manager.fileExists(atPath: packageBackup.path) { try manager.copyItem(at: packageURL, to: packageBackup) }
        var names = Set(package["skills"] as? [String] ?? [])
        var oldDirectories: [URL] = []
        var manifests: [(URL, Data)] = []
        var moved: [(URL, Skill)] = []
        for service in services {
            let parts = service.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, ["web", "api", "ios", "mcp"].contains(parts[0]),
                  parts[1].range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else { throw SkillError.invalidPackage }
            let directory = root.appendingPathComponent(parts[0] + "/" + parts[1])
            guard directory.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().appendingPathComponent(parts[0] + "/" + parts[1]).standardizedFileURL.path else { throw SkillError.invalidPackage }
            let file = directory.appendingPathComponent("service.json")
            guard manager.fileExists(atPath: file.path) else { continue }
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkillError.invalidPackage }
            let manifestBackup = backup.appendingPathComponent(parts[0] + "/" + parts[1] + "/service.json")
            guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw SkillError.invalidPackage }
            if manifest["skills"] == nil, manager.fileExists(atPath: manifestBackup.path) {
                guard let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestBackup)) as? [String: Any] else { throw SkillError.invalidPackage }
                manifest = saved
            }
            guard manifest["skills"] == nil || manifest["skills"] is [[String: Any]] else { throw SkillError.invalidPackage }
            let declarations = manifest["skills"] as? [[String: Any]] ?? []
            for declaration in declarations {
                guard let oldName = declaration["name"] as? String, SkillFiles.isLocalName(oldName) else { throw SkillError.invalidPackage }
                let source = directory.appendingPathComponent("skills/\(oldName)")
                let savedSource = backup.appendingPathComponent(parts[0] + "/" + parts[1] + "/skills/" + oldName)
                if !manager.fileExists(atPath: savedSource.path) {
                    try manager.createDirectory(at: savedSource.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: source, to: savedSource)
                }
                guard source.resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().appendingPathComponent("skills/\(oldName)").standardizedFileURL.path else { throw SkillError.invalidPackage }
                var skill = try SkillFiles.load(directory: manager.fileExists(atPath: source.path) ? source : savedSource)
                oldDirectories.append(source)
                skill.name = migratedSkillName(domain: parts[1], name: oldName)
                skill.instructions = migratedSkillInstructions(skill.instructions)
                let dependency = parts[0] == "ios" ? service : parts[1]
                skill.services = Array(Set(skill.services + [dependency])).sorted()
                let destination = root.appendingPathComponent("skills/\(skill.name)")
                if manager.fileExists(atPath: destination.path), try SkillFiles.load(directory: destination) != skill {
                    throw StorageMigrationError.collision("skills/\(skill.name)")
                }
                if moved.contains(where: { $0.1.name == skill.name && $0.1 != skill }) {
                    throw StorageMigrationError.collision("skills/\(skill.name)")
                }
                moved.append((destination, skill))
                names.insert(skill.name)
            }
            if manifest.removeValue(forKey: "skills") != nil {
                manifests.append((file, try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])))
            }
        }
        for (file, _) in manifests {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let destination = backup.appendingPathComponent(relative)
            if !manager.fileExists(atPath: destination.path) {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: file, to: destination)
            }
        }
        for (destination, skill) in moved { try SkillFiles.write(skill, directory: destination) }
        for (file, data) in manifests { try data.write(to: file, options: .atomic) }
        for directory in oldDirectories where manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
            let parent = directory.deletingLastPathComponent()
            if (try? manager.contentsOfDirectory(atPath: parent.path).isEmpty) == true { try manager.removeItem(at: parent) }
        }
        package["version"] = 3
        package["skills"] = names.sorted()
        package.removeValue(forKey: "contentHash")
        try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: current, options: .atomic)
        if clean, let git {
            let paths = ["repository.json"] + manifests.map { String($0.0.path.dropFirst(root.path.count + 1)) } + moved.map { "skills/\($0.1.name)" } + oldDirectories.map { String($0.path.dropFirst(root.path.count + 1)) }
            try git.add(paths: paths)
            let commit = try git.commit(message: "Move shared skills into repository version 3")
            Log.app.info("StorageMigrator.repositorySkills from=2 to=3 count=\(moved.count) commit=\(commit.id.abbreviated)")
        } else {
            Log.app.info("StorageMigrator.repositorySkills from=2 to=3 count=\(moved.count) pending=\(git != nil)")
        }
    }

    static func prepareScheduledSkills(at file: URL) throws -> [ScheduledSkill] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        try migrateScheduledSkillPackages(at: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScheduledSkillsDocument.self, from: Data(contentsOf: file))
        let schedules = try document.validated().schedules
        Log.app.info("StorageMigrator.schedules prepared version=\(document.version) count=\(schedules.count)")
        return schedules
    }

    static func exportRecoverySource(at source: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Ox Recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        _ = try copyMigrationSource(from: source, to: destination)
        return destination
    }

    @MainActor
    static func recoverOptionalStorage(services: ServiceManager) async -> Bool {
        guard !Task.isCancelled else { return false }
        if services.localRecoveryMessage != nil {
            do {
                try await services.retryLocalStorage()
                Log.app.info("StorageMigrator.recovery done resource=local")
            } catch {
                Log.app.warning("StorageMigrator.recovery deferred resource=local error=\(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled else { return false }
        if ScheduledSkills.shared.preparation?.failureMessage != nil {
            do {
                try ScheduledSkills.shared.load(retry: true)
                try ScheduledSkillScheduler.shared.activate()
                Log.app.info("StorageMigrator.recovery done resource=schedules")
            } catch {
                Log.app.warning("StorageMigrator.recovery deferred resource=schedules error=\(error.localizedDescription)")
            }
        }
        return services.localRecoveryMessage == nil && ScheduledSkills.shared.preparation == .ready
    }

    private static func copyMigrationSource(from source: URL, to destination: URL) throws -> [String: String] {
        let inventory = try migrationSourceInventory(at: source)
        try FileManager.default.copyItem(at: source, to: destination)
        guard try migrationSourceInventory(at: source) == inventory,
              try migrationSourceInventory(at: destination) == inventory else {
            throw StorageMigrationError.collision(source.lastPathComponent)
        }
        return inventory
    }

    private static func migrationSourceInventory(at root: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let values = try root.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(root.lastPathComponent) }
        if values.isRegularFile == true {
            return ["": try durableSourceFingerprint(root.lastPathComponent, at: root.deletingLastPathComponent())]
        }
        guard values.isDirectory == true else { throw StorageMigrationError.invalidApplicationStorage(root.lastPathComponent) }
        var files: [String: String] = [:]
        var directories = [root]
        while let directory = directories.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(url.lastPathComponent) }
                if values.isDirectory == true { directories.append(url) }
                else {
                    let path = String(url.path.dropFirst(root.path.count + 1))
                    files[path] = try durableSourceFingerprint(path, at: root)
                }
            }
        }
        return files
    }

    private static func migrateScheduledSkillPackages(at file: URL) throws {
        guard var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              document["version"] as? Int == 1, var schedules = document["schedules"] as? [[String: Any]] else { return }
        for index in schedules.indices {
            guard var skill = schedules[index]["skill"] as? [String: Any], let instructions = skill["instructions"] as? String else { throw SkillError.invalidPackage }
            skill["instructions"] = migratedSkillInstructions(instructions)
            if let name = skill["name"] as? String, ["import-memory", "manage-artifacts", "manage-services", "manage-skills"].contains(name) { skill["name"] = "user-" + name }
            schedules[index]["skill"] = skill
        }
        document["version"] = 2
        document["schedules"] = schedules
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        _ = try decoder.decode(ScheduledSkillsDocument.self, from: data).validated()
        try data.write(to: file, options: .atomic)
        Log.app.info("StorageMigrator.scheduledSkills from=1 to=2 count=\(schedules.count)")
    }

    static func migrateProfileSkillCatalog(at root: URL) throws {
        let manager = FileManager.default
        let skills = root.appendingPathComponent("skills")
        if manager.fileExists(atPath: skills.path) {
            for directory in try manager.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil) where SkillFiles.isLocalName(directory.lastPathComponent) {
                var skill = try SkillFiles.load(directory: directory)
                skill.instructions = migratedSkillInstructions(skill.instructions)
                var destination = directory
                if ["import-memory", "manage-artifacts", "manage-services", "manage-skills"].contains(skill.name) {
                    skill.name = "user-" + skill.name
                    destination = skills.appendingPathComponent(skill.name)
                    if manager.fileExists(atPath: destination.path), try SkillFiles.load(directory: destination) != skill {
                        throw StorageMigrationError.collision(destination.lastPathComponent)
                    }
                }
                try SkillFiles.write(skill, directory: destination)
                if destination != directory { try manager.removeItem(at: directory) }
            }
        }
        let selections = root.appendingPathComponent("skill-selections.json")
        if manager.fileExists(atPath: selections.path) {
            guard try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: selections)).version == 1 else { throw SkillError.invalidPackage }
        }
    }

    static func migrateReservedImportMemorySkill(at root: URL) throws {
        try migrateReservedSkill("import-memory", at: root)
    }

    static func migrateReservedOutcomeSkills(at root: URL) throws {
        for name in ["evolve", "visualize"] {
            try migrateReservedSkill(name, at: root)
        }
    }

    fileprivate static func migrateReservedSkill(_ name: String, at root: URL) throws {
        let manager = FileManager.default
        let source = root.appendingPathComponent("skills/\(name)", isDirectory: true)
        let destination = root.appendingPathComponent("skills/user-\(name)", isDirectory: true)
        let sourceExists = manager.fileExists(atPath: source.path)
        let destinationExists = manager.fileExists(atPath: destination.path)
        if sourceExists {
            var skill = try SkillFiles.load(directory: source)
            skill.name = "user-\(name)"
            if destinationExists {
                guard try SkillFiles.load(directory: destination) == skill else {
                    throw StorageMigrationError.collision("skills/user-\(name)")
                }
            } else {
                try SkillFiles.write(skill, directory: destination)
            }
        }
        let selectionsFile = root.appendingPathComponent("skill-selections.json")
        if manager.fileExists(atPath: selectionsFile.path) {
            var selections = try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: selectionsFile))
            guard selections.version == 1 else { throw SkillError.invalidPackage }
            if selections.sources[name] == "user", sourceExists || destinationExists {
                guard selections.sources["user-\(name)"].map({ $0 == "user" }) ?? true else {
                    throw StorageMigrationError.collision("skill-selections.json:user-\(name)")
                }
                selections.sources["user-\(name)"] = "user"
                selections.sources.removeValue(forKey: name)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(selections).write(to: selectionsFile, options: .atomic)
            }
        }
        if sourceExists { try manager.removeItem(at: source) }
        Log.app.info("StorageMigrator.reservedSkill name=\(name) renamed=\(sourceExists)")
    }

    private static func migrateProfile(_ profile: Profile) async throws {
        guard let sourceVersion = sourceVersion(for: profile.version),
              let from = ProfileSchema.versions.firstIndex(of: sourceVersion) else {
            throw StorageMigrationError.unsupportedProfileVersion(profile.name, profile.version)
        }
        let target = ProfileSchema.versions.firstIndex(of: nativeProfileVersion)!
        guard from < target else { return }
        let url = profile.url
        let id = profile.id
        let was = profile.version
        try await Task.detached(priority: .userInitiated) {
            let complete = await materialize(at: url)
            guard complete else {
                Log.app.warning("StorageMigrator.deferred id=\(id) version=\(was) awaiting downloads")
                throw StorageMigrationError.profileMigrationFailed(profile.name)
            }
            Log.app.info("StorageMigrator.start id=\(id) from=\(was) to=\(ProfileSchema.current)")
            for step in from..<target {
                let version = ProfileSchema.versions[step + 1]
                do {
                    try ProfileSchema.steps[step](url)
                    try stamp(version, at: url)
                } catch {
                    Log.app.error("StorageMigrator.failed id=\(id) step=\(version) error=\(error.localizedDescription)")
                    throw error
                }
            }
            Log.app.info("StorageMigrator.done id=\(id) version=\(nativeProfileVersion)")
        }.value
    }

    private static func sourceVersion(for version: String) -> String? {
        let normalized = ["2026-07-12", "2026-07-12-ids"].contains(version) ? "2026-07-11" : version
        return ProfileSchema.versions.contains(normalized) ? normalized : nil
    }

    nonisolated private static func materialize(at root: URL, timeout: TimeInterval = 60) async -> Bool {
        var evicted = requestDownloads(at: root)
        guard evicted > 0 else { return true }
        Log.app.info("StorageMigrator.materialize waiting evicted=\(evicted) root=\(root.lastPathComponent)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            evicted = requestDownloads(at: root)
            if evicted == 0 { return true }
        }
        Log.app.warning("StorageMigrator.materialize timeout evicted=\(evicted) root=\(root.lastPathComponent)")
        return false
    }

    private static func migratedServiceActions(_ source: String, identifiers: [String]) throws -> String {
        let registrations = try identifiers.map { identifier in
            let data = try JSONEncoder().encode(identifier)
            let encoded = String(decoding: data, as: UTF8.self)
            return "  action(\(encoded), { async invoke(args) { return __oxLegacyCall(\(encoded), args); } });"
        }.joined(separator: "\n")
        return """
        {
          const __oxRuntime = window.ox;
          const __oxRuntimeCallServiceAction = __oxRuntime.callServiceAction;
          let __oxLegacyCall;
          try {
        \(source)
            if (typeof window.ox?.callServiceAction === "function") {
              __oxLegacyCall = window.ox.callServiceAction.bind(window.ox);
            }
          } finally {
            window.ox = __oxRuntime;
            __oxRuntime.callServiceAction = __oxRuntimeCallServiceAction;
          }
          if (typeof __oxLegacyCall !== "function") throw new Error("legacy service dispatcher is unavailable");
          window.ox.install(1, ({ action }) => {
        \(registrations)
          });
        }
        """
    }

    nonisolated private static func requestDownloads(at root: URL) -> Int {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]) else { return 0 }
        var evicted = 0
        for case let url as URL in files {
            let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            guard status == .notDownloaded else { continue }
            try? fm.startDownloadingUbiquitousItem(at: url)
            evicted += 1
        }
        return evicted
    }

    nonisolated private static func stamp(_ version: String, at url: URL) throws {
        guard var config = ProfileIO.readConfig(at: url) else { throw StorageMigrationError.missingConfig }
        config.version = version
        try ProfileIO.writeConfig(config, to: url)
    }

    nonisolated private static func removeLegacyFile(_ url: URL, directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
        if try manager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try manager.removeItem(at: directory)
        }
    }

    private static func legacyLocalRepositoryState(at root: URL) throws -> LegacyLocalRepositoryState {
        let repository = try SwiftGitX.Repository.open(at: root)
        if let main = repository.reference["refs/heads/main"], let commit = main.target as? Commit {
            return .main(commit.id.hex)
        }
        let references = try repository.reference.list().map(\.fullName).sorted()
        return references.isEmpty && repository.isEmpty ? .empty : .unsupported(references)
    }

    private static func replaceLegacyLocalRepositoryMetadata(
        at root: URL,
        metadata: URL,
        seed: URL
    ) throws {
        let manager = FileManager.default
        let parent = metadata.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".git-repair-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".git-legacy-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.copyItem(at: seed, to: staging)
            try manager.moveItem(at: metadata, to: backup)
            do {
                try manager.moveItem(at: staging, to: metadata)
                _ = try localRepositoryCommit(at: root)
            } catch {
                do {
                    if manager.fileExists(atPath: metadata.path) {
                        try manager.removeItem(at: metadata)
                    }
                    try manager.moveItem(at: backup, to: metadata)
                } catch let rollbackError {
                    throw StorageMigrationError.localRepositoryRollbackFailed(rollbackError.localizedDescription)
                }
                throw error
            }
            do {
                try manager.removeItem(at: backup)
            } catch {
                Log.service.warning("StorageMigrator.localRepository backup cleanup failed error=\(error.localizedDescription)")
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    private static func localRepositoryCommit(at root: URL) throws -> String {
        let repository = try SwiftGitX.Repository.open(at: root)
        guard let head = try repository.HEAD.target as? Commit,
              let main = repository.reference["refs/heads/main"],
              let tip = main.target as? Commit,
              head.id == tip.id else {
            throw StorageMigrationError.invalidRepairedLocalRepository
        }
        return head.id.hex
    }

    static func moveAttachmentsToArtifacts(at root: URL) throws {
        let fm = FileManager.default
        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        guard fm.fileExists(atPath: attachments.path) else { return }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        var references = 0
        for transcript in try transcriptURLs(at: root) {
            let data = try Data(contentsOf: transcript)
            var output = Data()
            var changed = false
            for line in data.split(separator: 0x0A) {
                let original = Data(line)
                guard var object = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
                      object["type"] as? String == "user",
                      var user = object["user"] as? [String: Any],
                      let values = user["attachments"] as? [Any] else {
                    output.append(original)
                    output.append(0x0A)
                    continue
                }
                var converted: [Any] = []
                var lineChanged = false
                for value in values {
                    guard let legacy = value as? [String: Any] else {
                        converted.append(value)
                        continue
                    }
                    guard let idString = legacy["id"] as? String,
                          let id = UUID(uuidString: idString),
                          let oldFileName = legacy["fileName"] as? String,
                          URL(fileURLWithPath: oldFileName).lastPathComponent == oldFileName,
                          let displayName = legacy["displayName"] as? String,
                          let mimeType = legacy["mimeType"] as? String,
                          let kindString = legacy["kind"] as? String,
                          let kind = Artifact.Kind(rawValue: kindString) else {
                        throw StorageMigrationError.invalidAttachment(transcript.path)
                    }
                    let ext = URL(fileURLWithPath: oldFileName).pathExtension
                    let metadata = ArtifactMetadata(
                        id: id,
                        fileName: ext.isEmpty ? "content" : "content.\(ext)",
                        displayName: displayName,
                        mimeType: mimeType,
                        kind: kind
                    )
                    let source = attachments.appendingPathComponent(oldFileName, isDirectory: false)
                    try importLegacyArtifact(metadata, source: source, into: artifacts)
                    try finishLegacyImport(metadata, source: source, artifacts: artifacts)
                    converted.append(id.uuidString)
                    lineChanged = true
                    references += 1
                }
                user["attachments"] = converted
                object["user"] = user
                let encoded = try JSONSerialization.data(withJSONObject: object)
                output.append(encoded)
                output.append(0x0A)
                changed = changed || lineChanged
            }
            if changed { try output.write(to: transcript, options: .atomic) }
        }
        let leftovers = try fm.contentsOfDirectory(at: attachments, includingPropertiesForKeys: [.isRegularFileKey])
        var recovered = 0
        for source in leftovers {
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw StorageMigrationError.invalidAttachment(source.path)
            }
            let ext = source.pathExtension
            let type = UTType(filenameExtension: ext) ?? .data
            let kind: Artifact.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .pdf) ? .pdf : .text
            let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent) ?? UUID()
            let metadata = ArtifactMetadata(
                id: id,
                fileName: ext.isEmpty ? "content" : "content.\(ext)",
                displayName: source.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                kind: kind
            )
            try importLegacyArtifact(metadata, source: source, into: artifacts)
            try finishLegacyImport(metadata, source: source, artifacts: artifacts)
            recovered += 1
        }
        guard try fm.contentsOfDirectory(atPath: attachments.path).isEmpty else {
            throw StorageMigrationError.invalidAttachment(attachments.path)
        }
        try fm.removeItem(at: attachments)
        Log.app.info("StorageMigrator.moveAttachmentsToArtifacts root=\(root.lastPathComponent) references=\(references) recovered=\(recovered)")
    }

    static func renameLibraryToArtifacts(at root: URL) throws {
        let fm = FileManager.default
        let library = root.appendingPathComponent("library", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        guard fm.fileExists(atPath: library.path) else { return }
        if !fm.fileExists(atPath: artifacts.path) {
            try fm.moveItem(at: library, to: artifacts)
            Log.app.info("StorageMigrator.renameLibraryToArtifacts root=\(root.lastPathComponent) moved=directory")
            return
        }
        let items = try fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        for item in items {
            let destination = artifacts.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            if fm.fileExists(atPath: destination.path) {
                guard try equivalent(item, destination) else {
                    throw StorageMigrationError.collision(destination.path)
                }
                try fm.removeItem(at: item)
            } else {
                try fm.moveItem(at: item, to: destination)
            }
        }
        try fm.removeItem(at: library)
        Log.app.info("StorageMigrator.renameLibraryToArtifacts root=\(root.lastPathComponent) moved=\(items.count)")
    }

    static func moveChatsIntoDirectories(at root: URL) throws {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return }
        let entries = try fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isRegularFileKey])
        let legacy = try entries.filter { item in
            guard ["json", "jsonl"].contains(item.pathExtension),
                  UUID(uuidString: item.deletingPathExtension().lastPathComponent) != nil else { return false }
            return try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
        let grouped = Dictionary(grouping: legacy) {
            UUID(uuidString: $0.deletingPathExtension().lastPathComponent)!
        }
        var moved = 0
        for (id, files) in grouped {
            let directory = chats.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for source in files {
                let name = source.pathExtension == "json" ? "chat.json" : "turns.jsonl"
                let destination = directory.appendingPathComponent(name, isDirectory: false)
                if fm.fileExists(atPath: destination.path) {
                    guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
                        throw StorageMigrationError.collision(destination.path)
                    }
                    try fm.removeItem(at: source)
                } else {
                    try fm.moveItem(at: source, to: destination)
                }
                moved += 1
            }
        }
        Log.app.info("StorageMigrator.moveChatsIntoDirectories root=\(root.lastPathComponent) chats=\(grouped.count) files=\(moved)")
    }

    static func repairStorage(at root: URL) throws {
        try moveAttachmentsToArtifacts(at: root)
        try renameLibraryToArtifacts(at: root)
        try flattenLegacyArtifacts(at: root)
        try migrateLegacySkills(at: root)
        try moveChatsIntoDirectories(at: root)
    }

    private static func legacyTurn(from data: Data, decoder: JSONDecoder) throws -> Turn {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard root["type"] as? String == "agent",
              var agent = root["agent"] as? [String: Any] else {
            return try decoder.decode(Turn.self, from: data)
        }
        var steps = (agent["steps"] ?? agent["content"]) as? [[String: Any]] ?? []
        let generation = legacyGenerationID(agent: &agent, steps: steps)
        steps = steps.map { canonicalLegacyStep($0, generation: generation) }
        agent["steps"] = steps
        agent.removeValue(forKey: "content")
        agent.removeValue(forKey: "model")
        root["agent"] = agent
        return try decoder.decode(Turn.self, from: try JSONSerialization.data(withJSONObject: root))
    }

    private static func legacyGenerationID(
        agent: inout [String: Any],
        steps: [[String: Any]]
    ) -> String? {
        if let generations = agent["generations"] as? [[String: Any]],
           let id = generations.first?["id"] as? String {
            return id
        }
        guard let model = agent["model"] as? String,
              let at = agent["at"],
              let outcome = agent["outcome"] else { return nil }
        let seed = (steps.first?["id"] as? String) ?? "\(at).\(model)"
        let id = StableID.uuid("legacy-generation.\(seed)").uuidString
        agent["generations"] = [[
            "id": id,
            "at": at,
            "model": model,
            "outcome": outcome,
        ]]
        return id
    }

    private static func canonicalLegacyStep(
        _ value: [String: Any],
        generation: String?
    ) -> [String: Any] {
        var step = value
        if step["generation"] == nil {
            step["generation"] = generation ?? step["id"]
        }
        guard step["type"] as? String == "action",
              var action = step["action"] as? [String: Any],
              action["type"] as? String == "execute",
              var execution = action["execute"] as? [String: Any] else { return step }
        let effects = (execution["effects"] ?? execution["trace"]) as? [[String: Any]] ?? []
        execution["effects"] = effects.compactMap(canonicalLegacyEffect)
        execution.removeValue(forKey: "trace")
        action["execute"] = execution
        step["action"] = action
        return step
    }

    private static func canonicalLegacyEffect(_ value: [String: Any]) -> [String: Any]? {
        var effect = value
        switch effect["type"] as? String {
        case "step":
            effect["type"] = "invocation"
            effect["invocation"] = effect.removeValue(forKey: "step")
        case "widget":
            return nil
        case "media":
            if effect["media"] == nil { effect["media"] = effect.removeValue(forKey: "artifact") }
        default:
            break
        }
        return effect
    }

    static func migrateAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let encoder = JSONEncoder()
        let directories = try fm.contentsOfDirectory(
            at: chats,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.path < $1.path }
        var upgraded = 0
        var refreshed = 0
        for directory in directories {
            let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard fm.fileExists(atPath: metadataURL.path) else { continue }
            var metadata = try decoder.decode(ChatMeta.self, from: Data(contentsOf: metadataURL))
            guard [ChatFormat.currentSchemaVersion, legacyChatSchemaVersion].contains(metadata.schemaVersion) else {
                Log.app.warning("StorageMigrator.agentContext skipped=\(directory.lastPathComponent) schema=\(metadata.schemaVersion)")
                continue
            }
            let transcriptURL = directory.appendingPathComponent("turns.jsonl", isDirectory: false)
            let lines = fm.fileExists(atPath: transcriptURL.path) ? try transcriptLines(transcriptURL) : []
            let legacy = metadata.schemaVersion == legacyChatSchemaVersion
            let decoded = try lines.map {
                legacy
                    ? try legacyTurn(from: $0, decoder: decoder)
                    : try decoder.decode(Turn.self, from: $0)
            }
            let turns = ChatFormat.normalize(decoded)
            if legacy || turns != decoded {
                try blob(turns, encoder: encoder).write(to: transcriptURL, options: .atomic)
            }
            if legacy {
                metadata.schemaVersion = ChatFormat.currentSchemaVersion
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
                upgraded += 1
            }
            let contextURL = directory.appendingPathComponent("context.json", isDirectory: false)
            guard let lastAgent = turns.lastIndex(where: { turn in
                if case .agent = turn { return true }
                return false
            }) else {
                if fm.fileExists(atPath: contextURL.path) { try fm.removeItem(at: contextURL) }
                continue
            }
            let stored = try? decoder.decode(AgentContextCheckpoint.self, from: Data(contentsOf: contextURL))
            let messages: [Message]
            let tokensBefore: Int
            if !legacy, let stored, let boundary = stored.boundary(in: turns), boundary <= lastAgent {
                let tail = boundary == lastAgent
                    ? []
                    : ChatProjection.makeWireMessages(from: Array(turns[(boundary + 1)...lastAgent]))
                messages = stored.messages + tail
                tokensBefore = stored.tokensBefore
            } else {
                messages = ChatProjection.makeWireMessages(from: Array(turns[...lastAgent]))
                tokensBefore = 0
            }
            let context = AgentContextCheckpoint(
                messages: messages,
                tokensBefore: tokensBefore,
                turns: turns,
                through: lastAgent
            )
            try encoder.encode(context).write(to: contextURL, options: .atomic)
            refreshed += 1
        }
        Log.app.info("StorageMigrator.agentContexts root=\(root.lastPathComponent) chats=\(directories.count) refreshed=\(refreshed) upgraded=\(upgraded)")
    }

    static func removeRedundantAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let directories = try fm.contentsOfDirectory(
            at: chats,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.path < $1.path }
        var scanned = 0
        var removed = 0
        var retained = 0
        var unreadable = 0
        for directory in directories {
            let contextURL = directory.appendingPathComponent("context.json", isDirectory: false)
            guard fm.fileExists(atPath: contextURL.path) else { continue }
            let transcriptURL = directory.appendingPathComponent("turns.jsonl", isDirectory: false)
            scanned += 1
            guard fm.fileExists(atPath: transcriptURL.path) else {
                unreadable += 1
                Log.app.warning("StorageMigrator.redundantAgentContexts retained=missing-transcript chat=\(directory.lastPathComponent)")
                continue
            }
            let turns: [Turn]
            do {
                let lines = try transcriptLines(transcriptURL)
                turns = try lines.map { try decoder.decode(Turn.self, from: $0) }
            } catch {
                unreadable += 1
                Log.app.warning("StorageMigrator.redundantAgentContexts retained=unreadable chat=\(directory.lastPathComponent) error=\(error.localizedDescription)")
                continue
            }
            if turns.requiresContextCheckpoint {
                retained += 1
            } else {
                try fm.removeItem(at: contextURL)
                removed += 1
            }
        }
        Log.app.info("StorageMigrator.redundantAgentContexts root=\(root.lastPathComponent) scanned=\(scanned) removed=\(removed) retained=\(retained) unreadable=\(unreadable)")
    }

    private static func providerIdentity(_ id: String, region: LLMRegion, modelID: String) -> String {
        if id == "amazon-bedrock" {
            return "amazon-bedrock:\(modelID.hasPrefix("claude") || modelID.hasPrefix("anthropic.") ? "messages" : "responses")"
        }
        let profiles = BuiltInProviders.planProfiles + [ModelArkProvider.profile] + BuiltInProviders.trailingProfiles
        if let profile = profiles.first(where: { $0.id == id }),
           profile.regionalCredentials || !profile.endpoint.overrides.isEmpty || !(profile.models?.overrides.isEmpty ?? true) {
            return "\(id):\(region.rawValue)"
        }
        return id
    }

    private static func migrateProviderCatalog(defaults: UserDefaults) throws {
        func copyCredential(_ source: String, _ destination: String) throws {
            guard source != destination, let value = Credentials.legacyKey(for: source) else { return }
            if let existing = Credentials.legacyKey(for: destination), existing != value {
                throw StorageMigrationError.collision("provider credential")
            }
            try Credentials.setSecretChecked(value, for: "api:\(destination)")
        }
        let existing = defaults.data(forKey: ProviderRegistry.catalogKey)
        if let existing {
            let catalog = try JSONDecoder().decode(ProviderCatalog.self, from: existing)
            if catalog.format == 2 {
                try removeWebsiteProviderOverrides(from: catalog, defaults: defaults)
                return
            }
            guard catalog.format == 1 else {
                throw StorageMigrationError.invalidApplicationStorage("provider catalog")
            }
        }
        let bundled = ProviderRegistry.bundledDefinitions()
        for entry in bundled {
            _ = try ProviderDefinition.decode(entry.definition.json)
            try ProviderClientFactory.validateAdapter(entry.definition)
        }
        var catalog = ProviderCatalog()
        let selection = defaults.data(forKey: ProviderRegistry.defaultModelKey).flatMap { try? JSONDecoder().decode(ModelSelection.self, from: $0) }
        if let existing {
            struct Overlay: Decodable {
                let providers: [ProviderDefinition]
                let deleted: [String]
            }
            let overlay = try JSONDecoder().decode(Overlay.self, from: existing)
            let providers = overlay.providers.filter { $0.api != .web }
            try ProviderCatalog(providers: providers).validate()
            guard Set(overlay.deleted).count == overlay.deleted.count,
                  Set(overlay.deleted).isDisjoint(with: Set(overlay.providers.map(\.id))) else {
                throw StorageMigrationError.invalidApplicationStorage("provider catalog")
            }
            catalog.providers = providers
            for entry in bundled where overlay.deleted.contains(entry.definition.id) {
                var disabled = entry.definition
                disabled.models = []
                catalog.providers.append(disabled)
            }
        } else if let data = defaults.data(forKey: ProviderRegistry.customProvidersKey) {
            let custom = try JSONDecoder().decode([CustomLLMProvider].self, from: data)
            for provider in custom {
                var definition = provider.definition
                if selection?.providerID == provider.clientID, let modelID = selection?.modelID {
                    var model = ProviderDefinition.Model(ProviderModel(id: modelID, displayName: modelID, maxTokens: 4_096, maxContext: 32_768))
                    model.contextTokens = nil
                    model.outputTokens = nil
                    model.input = nil
                    model.output = nil
                    definition.models = [model]
                }
                catalog.providers.append(definition)
            }
        }
        try catalog.validate()
        if existing == nil {
            for entry in bundled { try copyCredential(entry.legacyCredentialID, entry.definition.credentialID) }
            for provider in catalog.providers where !bundled.contains(where: { $0.definition.id == provider.id }) {
                try copyCredential(provider.id, provider.credentialID)
            }
        }
        let encoded = try JSONEncoder().encode(catalog)
        defaults.set(encoded, forKey: ProviderRegistry.catalogKey)
        guard defaults.data(forKey: ProviderRegistry.catalogKey) == encoded else {
            throw StorageMigrationError.invalidApplicationStorage("provider catalog")
        }
        defaults.removeObject(forKey: ProviderRegistry.customProvidersKey)
        Log.app.info("StorageMigrator.providerCatalog migrated format=\(catalog.format) providers=\(catalog.providers.count) source=\(existing == nil ? "legacy" : "overlay")")
    }

    private static func removeWebsiteProviderOverrides(from catalog: ProviderCatalog, defaults: UserDefaults) throws {
        var next = catalog
        next.providers.removeAll { $0.api == .web }
        try next.validate()
        let removed = catalog.providers.count - next.providers.count
        guard removed > 0 else { return }
        let encoded = try JSONEncoder().encode(next)
        defaults.set(encoded, forKey: ProviderRegistry.catalogKey)
        guard defaults.data(forKey: ProviderRegistry.catalogKey) == encoded else {
            throw StorageMigrationError.invalidApplicationStorage("provider catalog")
        }
        Log.app.info("StorageMigrator.providerCatalog removedWebsiteOverrides=\(removed) providers=\(next.providers.count)")
    }

    static func migrateChatProviderDefinitions(at root: URL) throws {
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard FileManager.default.fileExists(atPath: chats.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isDirectoryKey])
        var count = 0
        for directory in directories {
            guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let file = directory.appendingPathComponent("chat.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            guard var selection = object["model"]?.objectValue,
                  let id = selection["providerID"]?.stringValue,
                  let modelID = selection["modelID"]?.stringValue,
                  let region = selection["region"]?.stringValue.flatMap(LLMRegion.init(rawValue:)) else { continue }
            selection["providerID"] = .string(providerIdentity(id, region: region, modelID: modelID))
            selection.removeValue(forKey: "region")
            object["model"] = .object(selection)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(object)
            data.append(0x0A)
            try data.write(to: file, options: .atomic)
            count += 1
        }
        Log.app.info("StorageMigrator.chatProviders migrated=\(count)")
    }

    static func removeBrowserServiceAttachments(at root: URL) throws {
        let manager = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard manager.fileExists(atPath: chats.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: chats,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var chatsChanged = 0
        var attachmentsRemoved = 0
        for directory in directories {
            let file = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard manager.fileExists(atPath: file.path) else { continue }
            var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
            guard let domains = object["attachedServiceDomains"]?.arrayValue else { continue }
            let retained = domains.filter { $0.stringValue != BrowserFunctionCatalog.internalDomain }
            guard retained.count != domains.count else { continue }
            object["attachedServiceDomains"] = .array(retained)
            var data = try encoder.encode(object)
            data.append(0x0A)
            try data.write(to: file, options: .atomic)
            chatsChanged += 1
            attachmentsRemoved += domains.count - retained.count
        }
        Log.app.info("StorageMigrator.browserAttachments chats=\(chatsChanged) removed=\(attachmentsRemoved)")
    }

    static func migrateChatModelSelections(at root: URL) throws {
        let manager = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard manager.fileExists(atPath: chats.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: chats,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        let fallbackRegion = modelMigrationFallbackRegion()
        let legacyKeys = ["clientID", "modelID", "region", "reasoningEffort"]
        var migrated = 0
        var incomplete = 0
        for directory in directories {
            let metadataURL = directory.appendingPathComponent("chat.json", isDirectory: false)
            guard manager.fileExists(atPath: metadataURL.path) else { continue }
            let data = try Data(contentsOf: metadataURL)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let hasLegacyValue = legacyKeys.contains { object[$0] != nil }
            guard hasLegacyValue else { continue }
            if object["model"] == nil,
               let providerID = object["clientID"] as? String,
               let modelID = object["modelID"] as? String {
                let region = (object["region"] as? String).flatMap(LLMRegion.init(rawValue:)) ?? fallbackRegion
                var selection: [String: Any] = [
                    "region": region.rawValue,
                    "providerID": providerID,
                    "modelID": modelID,
                ]
                if let reasoningEffort = object["reasoningEffort"] as? String {
                    selection["reasoningEffort"] = reasoningEffort
                }
                object["model"] = selection
                migrated += 1
            } else if object["model"] == nil {
                incomplete += 1
            }
            legacyKeys.forEach { object.removeValue(forKey: $0) }
            var encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            encoded.append(0x0A)
            try encoded.write(to: metadataURL, options: .atomic)
        }
        Log.app.info("StorageMigrator.chatModelSelections root=\(root.lastPathComponent) migrated=\(migrated) incomplete=\(incomplete)")
    }

    private static func modelMigrationFallbackRegion(defaults: UserDefaults = .standard) -> LLMRegion {
        if let data = defaults.data(forKey: ProviderRegistry.defaultModelKey),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let region = (object["region"] as? String).flatMap(LLMRegion.init(rawValue:)) {
            return region
        }
        if let region = defaults.string(forKey: "app.region").flatMap(LLMRegion.init(rawValue:)) {
            return region
        }
        return Locale.current.region?.identifier == "CN" ? .china : .global
    }

    static func migrateLegacySkills(at root: URL) throws {
        let legacy = root.appendingPathComponent("COMMANDS.md")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let text = try String(contentsOf: legacy, encoding: .utf8)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        var existing = Set(try manager.contentsOfDirectory(atPath: skillsRoot.path))
        var claimed: Set<String> = []
        var migrated = 0
        for legacySkill in parseLegacySkills(text) {
            let base = SkillFiles.slug(legacySkill.name)
            guard !base.isEmpty else { continue }
            var suffix = 1
            while true {
                let name = suffix == 1 ? base : "\(base)-\(suffix)"
                suffix += 1
                guard !claimed.contains(name) else { continue }
                let description = legacySkill.instructions
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? name
                let skill = Skill(
                    name: name,
                    description: description,
                    instructions: legacySkill.instructions,
                    services: legacySkill.services
                )
                let directory = skillsRoot.appendingPathComponent(name, isDirectory: true)
                let file = directory.appendingPathComponent(SkillFiles.fileName)
                if existing.contains(name) {
                    guard let current = try? String(contentsOf: file, encoding: .utf8),
                          SkillFiles.parse(current, directoryName: name) == skill else { continue }
                } else {
                    let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                    defer { FileStaging.cleanup(staging, operation: "legacy-skill-migration") }
                    try SkillFiles.serialize(skill).write(
                        to: staging.appendingPathComponent(SkillFiles.fileName),
                        atomically: true,
                        encoding: .utf8
                    )
                    try manager.moveItem(at: staging, to: directory)
                    existing.insert(name)
                }
                claimed.insert(name)
                migrated += 1
                break
            }
        }
        try manager.removeItem(at: legacy)
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.commandsToSkills root=\(root.lastPathComponent) count=\(migrated)")
    }

    static func namespaceUserSkills(at root: URL) throws {
        let namespace = "profile"
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: skillsRoot.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var migrated = 0
        for source in directories {
            guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  !source.lastPathComponent.hasPrefix("."),
                  !source.lastPathComponent.hasPrefix("\(namespace):"),
                  let localName = legacySkillLocalName(source.lastPathComponent, namespace: namespace),
                  let text = try? String(
                    contentsOf: source.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: source.lastPathComponent) else { continue }
            let destinationName = "\(namespace):\(localName)"
            let migratedSkill = Skill(
                name: destinationName,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services
            )
            let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
            let destinationFile = destination.appendingPathComponent(SkillFiles.fileName)
            if manager.fileExists(atPath: destination.path) {
                guard let existing = try? String(contentsOf: destinationFile, encoding: .utf8),
                      SkillFiles.parse(existing, directoryName: destinationName) == migratedSkill else {
                    throw StorageMigrationError.collision(destination.path)
                }
            } else {
                let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                defer { FileStaging.cleanup(staging, operation: "skill-namespace-migration") }
                try SkillFiles.serialize(migratedSkill).write(
                    to: staging.appendingPathComponent(SkillFiles.fileName),
                    atomically: true,
                    encoding: .utf8
                )
                try manager.moveItem(at: staging, to: destination)
            }
            try manager.removeItem(at: source)
            migrated += 1
        }
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.namespaceUserSkills root=\(root.lastPathComponent) count=\(migrated)")
    }

    private static func legacySkillLocalName(_ name: String, namespace: String) -> String? {
        if SkillFiles.isLocalName(name) { return name }
        let parts = name
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2,
              !["system", "service", namespace].contains(parts[0]),
              SkillFiles.isLocalName(parts[0]),
              SkillFiles.isLocalName(parts[1]) else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    private static func parseLegacySkills(_ text: String) -> [Skill] {
        var skills: [Skill] = []
        var name: String?
        var services: [String] = []
        var body: [Substring] = []
        func flush() {
            guard let name, !name.isEmpty else { return }
            let instructions = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            skills.append(Skill(
                name: name,
                description: instructions,
                instructions: instructions,
                services: services
            ))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                name = String(line.dropFirst(3))
                services = []
                body = []
            } else if name != nil {
                if body.isEmpty, services.isEmpty, line.hasPrefix("services:") {
                    services = line.dropFirst("services:".count)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else {
                    body.append(line)
                }
            }
        }
        flush()
        return skills
    }

    static func removeUserSkillNamespace(at root: URL) throws {
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: skillsRoot.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var migrated = 0
        for source in directories {
            let sourceName = source.lastPathComponent
            let prefix = "profile:"
            guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  sourceName.hasPrefix(prefix),
                  SkillFiles.isUserName(String(sourceName.dropFirst(prefix.count))),
                  let text = try? String(
                    contentsOf: source.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: sourceName) else { continue }
            let destinationName = String(sourceName.dropFirst(prefix.count))
            let migratedSkill = Skill(
                name: destinationName,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services
            )
            let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
            let destinationFile = destination.appendingPathComponent(SkillFiles.fileName)
            if manager.fileExists(atPath: destination.path) {
                guard let existing = try? String(contentsOf: destinationFile, encoding: .utf8),
                      SkillFiles.parse(existing, directoryName: destinationName) == migratedSkill else {
                    throw StorageMigrationError.collision(destination.path)
                }
            } else {
                let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                defer { FileStaging.cleanup(staging, operation: "plain-skill-name-migration") }
                try SkillFiles.serialize(migratedSkill).write(
                    to: staging.appendingPathComponent(SkillFiles.fileName),
                    atomically: true,
                    encoding: .utf8
                )
                try manager.moveItem(at: staging, to: destination)
            }
            try manager.removeItem(at: source)
            migrated += 1
        }
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.removeUserSkillNamespace root=\(root.lastPathComponent) count=\(migrated)")
    }

    private static func finishLegacyImport(_ metadata: ArtifactMetadata, source: URL, artifacts: URL) throws {
        let destination = artifacts
            .appendingPathComponent(metadata.id.uuidString, isDirectory: true)
            .appendingPathComponent(metadata.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw StorageMigrationError.missingArtifact(destination.path)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
            throw StorageMigrationError.collision(destination.path)
        }
        try FileManager.default.removeItem(at: source)
    }

    private static func importLegacyArtifact(
        _ metadata: ArtifactMetadata,
        source: URL,
        into directory: URL
    ) throws {
        let folder = directory.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        let metadataURL = folder.appendingPathComponent(ArtifactStore.metadataName, isDirectory: false)
        if FileManager.default.fileExists(atPath: metadataURL.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: source.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private static func flattenLegacyArtifacts(at root: URL) throws {
        let fm = FileManager.default
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        guard fm.fileExists(atPath: artifacts.path) else { return }
        let entries = try fm.contentsOfDirectory(at: artifacts, includingPropertiesForKeys: [.isDirectoryKey])
        let folders = try entries.filter { entry in
            guard UUID(uuidString: entry.lastPathComponent) != nil else { return false }
            return try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        var replacements: [String: String] = [:]
        for folder in folders {
            let metadataURL = folder.appendingPathComponent(ArtifactStore.metadataName, isDirectory: false)
            let metadata: ArtifactMetadata
            do {
                metadata = try JSONDecoder().decode(ArtifactMetadata.self, from: Data(contentsOf: metadataURL))
            } catch {
                throw StorageMigrationError.invalidArtifact(folder.path)
            }
            guard metadata.id.uuidString.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame,
                  URL(fileURLWithPath: metadata.fileName).lastPathComponent == metadata.fileName else {
                throw StorageMigrationError.invalidArtifact(folder.path)
            }
            let source = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
            guard fm.fileExists(atPath: source.path) else {
                throw StorageMigrationError.missingArtifact(source.path)
            }
            let data = try Data(contentsOf: source)
            let fileName = reusableFilename(
                suggested: displayName(metadata.displayName, contentName: metadata.fileName),
                id: metadata.id,
                data: data,
                directory: artifacts
            )
            let destination = artifacts.appendingPathComponent(fileName, isDirectory: false)
            if !fm.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            replacements[metadata.id.uuidString.lowercased()] = fileName
        }
        for transcript in try transcriptURLs(at: root) {
            try rewriteArtifactReferences(in: transcript, replacements: replacements)
        }
        for folder in folders { try fm.removeItem(at: folder) }
        if !folders.isEmpty {
            Log.app.info("StorageMigrator.flattenLegacyArtifacts root=\(root.lastPathComponent) artifacts=\(folders.count)")
        }
    }

    private static func reusableFilename(suggested: String, id: UUID, data: Data, directory: URL) -> String {
        let cleaned = ArtifactStore.sanitizedFilename(suggested)
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let tag = String(id.uuidString.prefix(8)).lowercased()
        var candidates = [cleaned, ext.isEmpty ? "\(stem) \(tag)" : "\(stem) \(tag).\(ext)"]
        var suffix = 2
        while true {
            let candidate = candidates.removeFirst()
            let destination = directory.appendingPathComponent(candidate, isDirectory: false)
            if !FileManager.default.fileExists(atPath: destination.path) { return candidate }
            if let existing = try? Data(contentsOf: destination), existing == data { return candidate }
            candidates.append(ext.isEmpty ? "\(stem) \(tag)-\(suffix)" : "\(stem) \(tag)-\(suffix).\(ext)")
            suffix += 1
        }
    }

    private static func displayName(_ displayName: String, contentName: String) -> String {
        let cleaned = ArtifactStore.sanitizedFilename(displayName)
        guard URL(fileURLWithPath: cleaned).pathExtension.isEmpty else { return cleaned }
        let ext = URL(fileURLWithPath: contentName).pathExtension
        return ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    }

    private static func rewriteArtifactReferences(in transcript: URL, replacements: [String: String]) throws {
        guard !replacements.isEmpty else { return }
        let data = try Data(contentsOf: transcript)
        var output = Data()
        var changed = false
        for line in data.split(separator: 0x0A) {
            let original = Data(line)
            guard let object = try? JSONSerialization.jsonObject(with: original) else {
                output.append(original)
                output.append(0x0A)
                continue
            }
            let replacement = replaceArtifactReferences(object, replacements: replacements, enabled: false)
            if replacement.changed {
                output.append(try JSONSerialization.data(withJSONObject: replacement.value))
                changed = true
            } else {
                output.append(original)
            }
            output.append(0x0A)
        }
        if changed { try output.write(to: transcript, options: .atomic) }
    }

    private static func replaceArtifactReferences(_ value: Any, replacements: [String: String], enabled: Bool) -> (value: Any, changed: Bool) {
        if let string = value as? String, enabled, let replacement = replacements[string.lowercased()] {
            return (replacement, true)
        }
        if let values = value as? [Any] {
            var changed = false
            let output = values.map {
                let replacement = replaceArtifactReferences($0, replacements: replacements, enabled: enabled)
                changed = changed || replacement.changed
                return replacement.value
            }
            return (output, changed)
        }
        if let fields = value as? [String: Any] {
            var changed = false
            var output: [String: Any] = [:]
            for (key, child) in fields {
                let replaceStrings = enabled || ["attachments", "artifact", "media"].contains(key)
                let replacement = replaceArtifactReferences(child, replacements: replacements, enabled: replaceStrings)
                output[key] = replacement.value
                changed = changed || replacement.changed
            }
            return (output, changed)
        }
        return (value, false)
    }

    private static func transcriptURLs(at root: URL) throws -> [URL] {
        let fm = FileManager.default
        let chats = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: chats.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
        var transcripts: [URL] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isRegularFile == true, entry.pathExtension == "jsonl" {
                transcripts.append(entry)
            } else if values.isDirectory == true {
                let transcript = entry.appendingPathComponent("turns.jsonl", isDirectory: false)
                if fm.fileExists(atPath: transcript.path) { transcripts.append(transcript) }
            }
        }
        return transcripts.sorted { $0.path < $1.path }
    }

    private static func transcriptLines(_ url: URL) throws -> [Data] {
        try [UInt8](Data(contentsOf: url)).split(separator: 0x0A).map { Data($0) }
    }

    private static func blob(_ turns: [Turn], encoder: JSONEncoder) throws -> Data {
        try turns.reduce(into: Data()) { output, turn in
            output.append(try encoder.encode(turn))
            output.append(0x0A)
        }
    }

    private static func equivalent(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let left = try lhs.resourceValues(forKeys: keys)
        let right = try rhs.resourceValues(forKeys: keys)
        guard left.isDirectory == right.isDirectory, left.isRegularFile == right.isRegularFile else { return false }
        if left.isRegularFile == true { return try Data(contentsOf: lhs) == Data(contentsOf: rhs) }
        guard left.isDirectory == true else { return false }
        let fm = FileManager.default
        let leftNames = try fm.contentsOfDirectory(atPath: lhs.path).sorted()
        let rightNames = try fm.contentsOfDirectory(atPath: rhs.path).sorted()
        guard leftNames == rightNames else { return false }
        for name in leftNames {
            guard try equivalent(lhs.appendingPathComponent(name), rhs.appendingPathComponent(name)) else { return false }
        }
        return true
    }
}
