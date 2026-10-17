import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

extension ProfileMigrator {
    static func moveAttachmentsToFiles(at root: URL) throws {
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
                          let kind = FileItem.Kind(rawValue: kindString) else {
                        throw StorageMigrationError.invalidAttachment(transcript.path)
                    }
                    let ext = URL(fileURLWithPath: oldFileName).pathExtension
                    let metadata = FileMetadata(
                        id: id,
                        fileName: ext.isEmpty ? "content" : "content.\(ext)",
                        displayName: displayName,
                        mimeType: mimeType,
                        kind: kind
                    )
                    let source = attachments.appendingPathComponent(oldFileName, isDirectory: false)
                    try importLegacyFile(metadata, source: source, into: artifacts)
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
            let kind: FileItem.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .pdf) ? .pdf : .text
            let id = UUID(uuidString: source.deletingPathExtension().lastPathComponent) ?? UUID()
            let metadata = FileMetadata(
                id: id,
                fileName: ext.isEmpty ? "content" : "content.\(ext)",
                displayName: source.lastPathComponent,
                mimeType: type.preferredMIMEType ?? "application/octet-stream",
                kind: kind
            )
            try importLegacyFile(metadata, source: source, into: artifacts)
            try finishLegacyImport(metadata, source: source, artifacts: artifacts)
            recovered += 1
        }
        guard try fm.contentsOfDirectory(atPath: attachments.path).isEmpty else {
            throw StorageMigrationError.invalidAttachment(attachments.path)
        }
        try fm.removeItem(at: attachments)
        Log.app.info("StorageMigrator.moveAttachmentsToFiles root=\(root.lastPathComponent) references=\(references) recovered=\(recovered)")
    }

    static func renameLibraryToFiles(at root: URL) throws {
        let fm = FileManager.default
        let library = root.appendingPathComponent("library", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        guard fm.fileExists(atPath: library.path) else { return }
        if !fm.fileExists(atPath: artifacts.path) {
            try fm.moveItem(at: library, to: artifacts)
            Log.app.info("StorageMigrator.renameLibraryToFiles root=\(root.lastPathComponent) moved=directory")
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
        Log.app.info("StorageMigrator.renameLibraryToFiles root=\(root.lastPathComponent) moved=\(items.count)")
    }

    static func moveConversationsIntoDirectories(at root: URL) throws {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return }
        let entries = try fm.contentsOfDirectory(at: conversations, includingPropertiesForKeys: [.isRegularFileKey])
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
            let directory = conversations.appendingPathComponent(id.uuidString, isDirectory: true)
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
        Log.app.info("StorageMigrator.moveConversationsIntoDirectories root=\(root.lastPathComponent) conversations=\(grouped.count) files=\(moved)")
    }

    static func repairStorage(at root: URL) throws {
        try moveAttachmentsToFiles(at: root)
        try renameLibraryToFiles(at: root)
        try flattenLegacyFiles(at: root)
        try migrateLegacySkills(at: root)
        try moveConversationsIntoDirectories(at: root)
    }

    static func migrateAgentContexts(at root: URL) throws {
        try ConversationMigrator.migrateLegacyAgentContexts(at: root)
    }

    static func removeRedundantAgentContexts(at root: URL) throws {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return }
        guard let config = ProfileIO.readConfig(at: root) else { throw StorageMigrationError.missingConfig }
        let scope = ProfileScope(profileID: config.id, root: root, location: .local)
        let decoder = JSONDecoder()
        decoder.userInfo[.profileScope] = scope
        let directories = try fm.contentsOfDirectory(
            at: conversations,
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
                Log.app.warning("StorageMigrator.redundantAgentContexts retained=missing-transcript conversation=\(directory.lastPathComponent)")
                continue
            }
            let turns: [Turn]
            do {
                let lines = try transcriptLines(transcriptURL)
                turns = try lines.map { try decoder.decode(Turn.self, from: $0) }
            } catch {
                unreadable += 1
                Log.app.warning("StorageMigrator.redundantAgentContexts retained=unreadable conversation=\(directory.lastPathComponent) error=\(error.localizedDescription)")
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

    static func migrateConversationProviderDefinitions(at root: URL) throws {
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard FileManager.default.fileExists(atPath: conversations.path) else { return }
        let directories = try FileManager.default.contentsOfDirectory(at: conversations, includingPropertiesForKeys: [.isDirectoryKey])
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
            selection["providerID"] = .string(StorageMigrationSupport.providerIdentity(id, region: region, modelID: modelID))
            selection.removeValue(forKey: "region")
            object["model"] = .object(selection)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(object)
            data.append(0x0A)
            try data.write(to: file, options: .atomic)
            count += 1
        }
        Log.app.info("StorageMigrator.conversationProviders migrated=\(count)")
    }

    static func retainedServiceDomains(_ domains: [String]) -> [String] {
        domains.filter { $0 != "ios:files" }
    }

    static func removeBrowserServiceAttachments(at root: URL) throws {
        let manager = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard manager.fileExists(atPath: conversations.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: conversations,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var conversationsChanged = 0
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
            conversationsChanged += 1
            attachmentsRemoved += domains.count - retained.count
        }
        Log.app.info("StorageMigrator.browserAttachments chats=\(conversationsChanged) removed=\(attachmentsRemoved)")
    }

    static func migrateConversationModelSelections(at root: URL) throws {
        let manager = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard manager.fileExists(atPath: conversations.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: conversations,
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
        Log.app.info("StorageMigrator.conversationModelSelections root=\(root.lastPathComponent) migrated=\(migrated) incomplete=\(incomplete)")
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

    private static func finishLegacyImport(_ metadata: FileMetadata, source: URL, artifacts: URL) throws {
        let destination = artifacts
            .appendingPathComponent(metadata.id.uuidString, isDirectory: true)
            .appendingPathComponent(metadata.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw StorageMigrationError.missingFile(destination.path)
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard try Data(contentsOf: source) == Data(contentsOf: destination) else {
            throw StorageMigrationError.collision(destination.path)
        }
        try FileManager.default.removeItem(at: source)
    }

    private static func importLegacyFile(
        _ metadata: FileMetadata,
        source: URL,
        into directory: URL
    ) throws {
        let folder = directory.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        let metadataURL = folder.appendingPathComponent(FileStore.metadataName, isDirectory: false)
        if FileManager.default.fileExists(atPath: metadataURL.path) { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
        if FileManager.default.fileExists(atPath: source.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private static func flattenLegacyFiles(at root: URL) throws {
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
            let metadataURL = folder.appendingPathComponent(FileStore.metadataName, isDirectory: false)
            let metadata: FileMetadata
            do {
                metadata = try JSONDecoder().decode(FileMetadata.self, from: Data(contentsOf: metadataURL))
            } catch {
                throw StorageMigrationError.invalidFile(folder.path)
            }
            guard metadata.id.uuidString.caseInsensitiveCompare(folder.lastPathComponent) == .orderedSame,
                  URL(fileURLWithPath: metadata.fileName).lastPathComponent == metadata.fileName else {
                throw StorageMigrationError.invalidFile(folder.path)
            }
            let source = folder.appendingPathComponent(metadata.fileName, isDirectory: false)
            guard fm.fileExists(atPath: source.path) else {
                throw StorageMigrationError.missingFile(source.path)
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
            try rewriteFileReferences(in: transcript, replacements: replacements)
        }
        for folder in folders { try fm.removeItem(at: folder) }
        if !folders.isEmpty {
            Log.app.info("StorageMigrator.flattenLegacyFiles root=\(root.lastPathComponent) artifacts=\(folders.count)")
        }
    }

    private static func reusableFilename(suggested: String, id: UUID, data: Data, directory: URL) -> String {
        let cleaned = FileStore.sanitizedFilename(suggested)
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
        let cleaned = FileStore.sanitizedFilename(displayName)
        guard URL(fileURLWithPath: cleaned).pathExtension.isEmpty else { return cleaned }
        let ext = URL(fileURLWithPath: contentName).pathExtension
        return ext.isEmpty ? cleaned : "\(cleaned).\(ext)"
    }

    private static func rewriteFileReferences(in transcript: URL, replacements: [String: String]) throws {
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
            let replacement = replaceFileReferences(object, replacements: replacements, enabled: false)
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

    private static func replaceFileReferences(_ value: Any, replacements: [String: String], enabled: Bool) -> (value: Any, changed: Bool) {
        if let string = value as? String, enabled, let replacement = replacements[string.lowercased()] {
            return (replacement, true)
        }
        if let values = value as? [Any] {
            var changed = false
            let output = values.map {
                let replacement = replaceFileReferences($0, replacements: replacements, enabled: enabled)
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
                let replacement = replaceFileReferences(child, replacements: replacements, enabled: replaceStrings)
                output[key] = replacement.value
                changed = changed || replacement.changed
            }
            return (output, changed)
        }
        return (value, false)
    }

    private static func transcriptURLs(at root: URL) throws -> [URL] {
        let fm = FileManager.default
        let conversations = root.appendingPathComponent("chats", isDirectory: true)
        guard fm.fileExists(atPath: conversations.path) else { return [] }
        let entries = try fm.contentsOfDirectory(at: conversations, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
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
