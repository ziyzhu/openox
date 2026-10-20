import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

extension ProfileMigrator {
    static func durableJournalDirectory(_ id: UUID) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StorageMigration/PiProfiles/" + id.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    static func writeDurableJournal(_ journal: [String: Any], profileID: UUID) throws {
        let directory = try durableJournalDirectory(profileID)
        let file = directory.appendingPathComponent("journal.json")
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: file, options: .atomic)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration journal") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration journal durability") }
        try syncDurableDirectory(directory)
    }

    static func syncDurableDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration directory") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw StorageMigrationError.invalidApplicationStorage("Pi migration directory durability") }
    }

    static func publishDurableJournal(_ journal: [String: Any]) throws {
        guard journal["format"] as? Int == 1, let text = journal["profileID"] as? String, let id = UUID(uuidString: text),
              let rootPath = journal["root"] as? String, let stagePath = journal["stage"] as? String, let backupPath = journal["backup"] as? String else {
            throw StorageMigrationError.invalidApplicationStorage("Pi migration journal")
        }
        let root = URL(fileURLWithPath: rootPath), stage = URL(fileURLWithPath: stagePath), backup = URL(fileURLWithPath: backupPath)
        guard stage.deletingLastPathComponent() == root.deletingLastPathComponent(), stage.lastPathComponent.hasPrefix(".pi-stage-"),
              backup.deletingLastPathComponent() == (try durableJournalDirectory(id)), root != stage, root != backup else {
            throw StorageMigrationError.invalidApplicationStorage("Pi migration publication paths")
        }
        if let manifest = ProfileIO.readConfig(at: root), manifest.id == id, [durableProfileVersion, lazyConversationVersion].contains(manifest.version) {
            var published = journal; published["phase"] = "published"
            try writeDurableJournal(published, profileID: id)
            return
        }
        guard let manifest = ProfileIO.readConfig(at: stage), manifest.id == id, [durableProfileVersion, lazyConversationVersion].contains(manifest.version),
              FileManager.default.fileExists(atPath: stage.appendingPathComponent(manifest.version == lazyConversationVersion ? ".ox/state.sqlite" : "state.sqlite").path) else {
            throw StorageMigrationError.invalidApplicationStorage("validated staged Pi Profile")
        }
        if FileManager.default.fileExists(atPath: root.path) {
            guard !FileManager.default.fileExists(atPath: backup.path),
                  let result = journal["result"] as? [String: Any], let inventory = result["sourceInventory"] as? [String: String],
                  try StorageMigrationSupport.migrationSourceInventory(at: root) == inventory else { throw StorageMigrationError.profileMigrationFailed(root.lastPathComponent) }
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

    static func recoverDurablePublications() throws {
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

    static func stageDurableProfile(_ profile: Profile, at destination: URL, progress: @Sendable @escaping (String) async -> Void = { _ in }) async throws -> JSONValue {
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
        let runtime = DurableRuntime(databaseURL: destination.appendingPathComponent("state.sqlite"), fileRoot: destination) { method, params, _ in
            guard method == "profileInstallConversation", let index = params.objectValue?["index"]?.intValue,
                  (0..<prepared.conversationCount).contains(index) else {
                throw StorageMigrationError.invalidApplicationStorage("staged conversation request")
            }
            await progress(String(localized: "Migrating conversation \(index + 1) of \(prepared.conversationCount)…"))
            return try await Task.detached(priority: .userInitiated) {
                let data = try durableSourceFile("\(index).json", at: prepared.conversationDirectory)
                Log.app.info("StorageMigrator.pi installing conversation=\(index + 1)/\(prepared.conversationCount) bytes=\(data.count)")
                return try JSONDecoder().decode(JSONValue.self, from: data)
            }.value
        }
        do {
            let result = try await runtime.command(JSONValue.object(["action": .string("installProfile"), "draft": prepared.draft,
                "conversationCount": .int(prepared.conversationCount)]).jsonString())
            await runtime.dispose()
            try await prepareFiles(at: destination, profileID: profile.id)
            let state = ProfileIO.portableStateDirectory(destination)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
            for name in ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm"] {
                let source = destination.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: state.appendingPathComponent(name)) }
            }
            let archives = prepared.draft.objectValue?["payloads"]?.arrayValue ?? []
            if !archives.isEmpty {
                let payloadDirectory = state.appendingPathComponent("payloads")
                try FileManager.default.createDirectory(at: payloadDirectory, withIntermediateDirectories: false)
                for archive in archives {
                    guard let path = archive.objectValue?["path"]?.stringValue else { throw StorageMigrationError.invalidApplicationStorage("conversation source") }
                    let source = destination.appendingPathComponent(path)
                    try FileManager.default.moveItem(at: source, to: payloadDirectory.appendingPathComponent(source.lastPathComponent))
                }
            }
            let staging = destination.appendingPathComponent(".files")
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            try await preparePublicFiles(content: destination, state: state, profileID: profile.id)
            try await Task.detached(priority: .userInitiated) {
                let current = try durableSourceInventory(at: profile.url)
                guard current == prepared.inventory else { throw StorageMigrationError.profileMigrationFailed(profile.name) }
                try FileManager.default.removeItem(at: prepared.conversationDirectory)
                var manifest = prepared.manifest
                manifest["version"] = lazyConversationVersion
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
            try syncImportedTree(destination)
            Log.app.info("StorageMigrator.pi staged id=\(profile.id) target=\(lazyConversationVersion) activated=false")
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
        let conversationDirectory: URL
        let conversationCount: Int
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
        decoder.userInfo[.fileDirectoryListing] = FileDirectoryListing()
        var documents: [[String: Any]] = []
        var artifacts: [[String: Any]] = []
        let conversationDirectory = destination.appendingPathComponent(".migration-conversations", isDirectory: true)
        try manager.createDirectory(at: conversationDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var payloads: [String: JSONValue] = [:]
        let payloadStore = DurableFileStore(root: destination)
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
                guard !name.contains("/"), try FileStore.validatedFilename(name) == name else { throw StorageMigrationError.invalidFile(path) }
                let data = try durableSourceFile(path, at: profile.url, limit: 32 * 1024 * 1024)
                let binary = data.count > 200 * 1024 || String(data: data, encoding: .utf8) == nil
                try data.write(to: artifactDirectory.appendingPathComponent(name), options: .withoutOverwriting)
                artifacts.append(["path": path, "size": data.count, "sha256": ConversationMigrator.durableDigest(data), "binary": binary,
                    "saved": saved.contains { $0.caseInsensitiveCompare(name) == .orderedSame }])
            }
        }
        let names = Set(artifacts.compactMap { $0["path"] as? String }.map { String($0.dropFirst("artifacts/".count)).lowercased() })
        guard saved.allSatisfy({ names.contains($0.lowercased()) }) else { throw StorageMigrationError.invalidFile(savedPath) }
        let conversationFiles = inventory.keys.filter { $0.hasPrefix("chats/") }
        guard conversationFiles.allSatisfy({ path in
            let parts = path.split(separator: "/")
            return parts.count == 3 && UUID(uuidString: String(parts[1])) != nil && inventory["\(parts[0])/\(parts[1])/chat.json"] != nil
        }) else { throw StorageMigrationError.invalidApplicationStorage("chats") }
        let conversationPaths = conversationFiles.filter { $0.hasSuffix("/chat.json") }.sorted()
        for (ordinal, path) in conversationPaths.enumerated() {
            try autoreleasepool {
                let prefix = String(path.dropLast("chat.json".count))
                let data = try durableSourceFile(path, at: profile.url)
                let metadata = try ConversationMigrator.decodeMigrationValue(ConversationMeta.self, from: data, decoder: decoder, path: path)
                guard metadata.schemaVersion == ConversationFormat.currentSchemaVersion,
                      UUID(uuidString: String(prefix.split(separator: "/")[1])) == metadata.id else {
                    throw StorageMigrationError.invalidApplicationStorage(path)
                }
                var entries: [[String: Any]] = [["kind": "ox.native.conversation", "data": ["source": try archive(data).toAny()]]]
                for (name, kind) in [("turns.jsonl", "ox.native.transcript"), ("context.json", "ox.native.context")] {
                    let sourcePath = prefix + name
                    guard inventory[sourcePath] != nil else { continue }
                    let descriptor = try StorageMigrationSupport.durableSourceDescriptor(sourcePath, at: profile.url)
                    defer { Darwin.close(descriptor) }
                    let writer = try payloadStore.payloadWriter()
                    var buffer = [UInt8](repeating: 0, count: 128 * 1024)
                    while true {
                        let count = Darwin.read(descriptor, &buffer, buffer.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count >= 0 else { throw StorageMigrationError.invalidApplicationStorage(sourcePath) }
                        if count == 0 { break }
                        try writer.append(Data(buffer.prefix(count)))
                    }
                    let source = try writer.finish()
                    payloads[source.objectValue!["path"]!.stringValue!] = source
                    entries.append(["kind": kind, "data": ["source": source.toAny()]])
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
                let conversation: [String: Any] = ["key": metadata.id.uuidString, "title": metadata.title ?? "", "favorite": metadata.isFavorite,
                    "unread": metadata.hasUnreadResponse, "agent": agent, "metadata": applicationMetadata, "entries": entries, "expectedContext": []]
                let encoded = try JSONSerialization.data(withJSONObject: conversation, options: [.sortedKeys])
                try encoded.write(to: conversationDirectory.appendingPathComponent("\(ordinal).json"), options: .withoutOverwriting)
                Log.app.info("StorageMigrator.pi conversation staged ordinal=\(ordinal + 1)/\(conversationPaths.count) bytes=\(encoded.count)")
            }
        }
        return DurableProfileDraft(draft: .from(["format": 1, "profileID": profile.id.uuidString, "documents": documents,
            "artifacts": artifacts, "payloads": payloads.values.map { $0.toAny() }, "conversations": []]), manifest: manifest, inventory: inventory,
            conversationDirectory: conversationDirectory, conversationCount: conversationPaths.count)
    }

    private static func durableSourceInventory(at root: URL) throws -> [String: String] {
        var files: [String: String] = [:]
        var directories = [(root, "")]
        while let (directory, prefix) = directories.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(url.lastPathComponent) }
                let path = prefix + url.lastPathComponent
                if values.isDirectory == true {
                    guard ["chats", "skills", "artifacts"].contains(path) || path.hasPrefix("chats/") || path.hasPrefix("skills/") else {
                        throw StorageMigrationError.invalidApplicationStorage(path)
                    }
                    directories.append((url, path + "/")); continue
                }
                guard values.isRegularFile == true,
                    [ProfileIO.configName, "MEMORY.md", "SOUL.md", "skill-selections.json", "artifacts/.saved.json"].contains(path)
                    || path.hasPrefix("skills/") || path.hasPrefix("artifacts/")
                    || (path.hasPrefix("chats/") && ["chat.json", "turns.jsonl", "context.json"].contains(url.lastPathComponent)) else {
                    throw StorageMigrationError.invalidApplicationStorage(path)
                }
                files[path] = try StorageMigrationSupport.durableSourceFingerprint(path, at: root)
            }
        }
        return files
    }

    private static func durableSourceFile(_ path: String, at root: URL, limit: Int = 64 * 1024 * 1024) throws -> Data {
        let descriptor = try StorageMigrationSupport.durableSourceDescriptor(path, at: root)
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
}
