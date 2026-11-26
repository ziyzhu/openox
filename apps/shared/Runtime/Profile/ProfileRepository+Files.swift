import Foundation

extension ProfileRepository {
    nonisolated struct DurableProfileFile: Codable, Equatable, Sendable {
        let path: String
        let size: Int
        let mtime: Double
        let binary: Bool
        let saved: Bool
        let sha256: String?
        let reference: String?
        let aliases: [String]?
    }

    nonisolated private struct DurableFileRecord: Codable, Sendable {
        let path: String
        let size: Int
        let sha256: String
        let binary: Bool
        let saved: Bool
        let reference: String?
        let hidden: Bool?
        let aliases: [String]?

        func file(in scope: ProfileScope) -> FileItem {
            FileItem(fileName: reference ?? path.split(separator: "/").last.map(String.init) ?? path,
                     directory: scope.root, relativePath: path, virtualPath: "/" + path, size: size)
        }
    }

    func profileFiles(prefix: String, in scope: ProfileScope) async throws -> [DurableProfileFile] {
        var files: [DurableProfileFile] = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let page = try await profileFilesPage(prefix: prefix, cursor: cursor, in: scope)
            files.append(contentsOf: page.files)
            cursor = page.next
        } while cursor != nil
        guard Set(files.map(\.path)).count == files.count else { throw CocoaError(.fileReadCorruptFile) }
        return files
    }

    func profileFilesPage(prefix: String, cursor: String? = nil, in scope: ProfileScope) async throws -> (files: [DurableProfileFile], next: String?) {
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileList"), "prefix": .string(prefix), "limit": .int(100),
            "fileCursor": cursor.map(JSONValue.string) ?? .null,
        ]))
        guard let values = result.objectValue?["files"]?.arrayValue, values.count <= 100,
              let nextValue = result.objectValue?["next"], nextValue == .null || nextValue.stringValue != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let files = try JSONDecoder().decode([DurableProfileFile].self, from: JSONEncoder().encode(JSONValue.array(values)))
        guard files.allSatisfy({ $0.path.hasPrefix(prefix) && $0.size >= 0 && $0.size <= FileLimits.fileBytes && $0.mtime.isFinite && $0.mtime >= 0 }),
              nextValue.stringValue == nil || (nextValue.stringValue == files.last?.path && nextValue.stringValue != cursor) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (files, nextValue.stringValue)
    }

    func removeProfileFile(path: String, in scope: ProfileScope) async throws {
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileRemove"), "path": .string(path),
        ]))
    }

    func fileListing(for turns: [Turn], in scope: ProfileScope) async throws -> FileDirectoryListing {
        var names = Set<String>()
        for turn in turns {
            _ = turn.mappingFiles { file in
                names.insert(file.fileName)
                return file
            }
        }
        let ordered = names.sorted()
        var references: [String: FileItem] = [:]
        for offset in stride(from: 0, to: ordered.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ordered[offset..<min(offset + 100, ordered.count)])
            let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
                "action": .string("fileResolve"), "paths": .array(batch.map(JSONValue.string)),
            ]))
            guard let values = result.objectValue?["files"]?.arrayValue, values.count == batch.count else { throw CocoaError(.fileReadCorruptFile) }
            for (name, value) in zip(batch, values) where value != .null {
                let record = try JSONDecoder().decode(DurableFileRecord.self, from: JSONEncoder().encode(value))
                guard record.reference == name || record.aliases?.contains(name) == true,
                      record.hidden != true, record.size >= 0, record.size <= (record.binary ? FileLimits.fileBytes : FileLimits.textBytes),
                      record.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
                let file = record.file(in: scope)
                references[name] = file
                references[name.lowercased()] = file
            }
        }
        return FileDirectoryListing(files: references)
    }

    func files(in scope: ProfileScope) async throws -> [FileItem] {
        let files = try await profileFiles(prefix: "", in: scope).filter { $0.reference != nil }
        return try files.map { file in
            guard let name = file.reference, try profileFileName(name) == name,
                  file.sha256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.fileReadCorruptFile) }
            return FileItem(fileName: name, directory: scope.root, relativePath: file.path, virtualPath: "/" + file.path, size: file.size,
                            modifiedAt: Date(timeIntervalSince1970: file.mtime / 1000))
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func materializeFile(_ file: FileItem, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: file.fileName, in: scope)
        let expectedURL = scope.root.appendingPathComponent(record.path)
        let legacyURL = scope.root.appendingPathComponent("artifacts").appendingPathComponent(file.fileName)
        guard [expectedURL.standardizedFileURL, legacyURL.standardizedFileURL].contains(file.fileURL.standardizedFileURL) else { throw CocoaError(.fileReadNoPermission) }
        return try await self.file(named: file.fileName, in: scope)
    }

    func file(named name: String, in scope: ProfileScope) async throws -> FileItem {
        try await requiredFileRecord(named: name, in: scope).file(in: scope)
    }

    func importFile(data: Data, suggestedName: String, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        if let conversation {
            guard conversation.profileID == scope.profileID else { throw CocoaError(.fileReadNoPermission) }
            let folder = "conversations/\(conversation.conversationID)"
            let cleaned = FileStore.sanitizedFilename(suggestedName)
            let files = try await profileFiles(prefix: folder + "/", in: scope)
            let name = files.contains(where: { $0.path.caseInsensitiveCompare(folder + "/" + cleaned) == .orderedSame }) ? versionedFileName(cleaned) : cleaned
            return try await writeFile(data: data, named: name, in: scope, conversation: conversation)
        }
        let name = try await availableFileName(suggestedName, in: scope)
        return try await writeFile(data: data, named: name, in: scope)
    }

    func writeFile(data: Data, named name: String, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        let name = try profileFileName(name)
        guard data.count <= FileLimits.fileBytes else {
            throw FileError.fileTooLarge(bytes: data.count, limit: FileLimits.fileBytes)
        }
        let file = FileItem(fileName: name, directory: scope.root.appendingPathComponent("artifacts", isDirectory: true))
        let text = file.kind == .text || file.kind == .html ? try fileText(data) : nil
        let path: String
        if let conversation {
            guard conversation.profileID == scope.profileID else { throw CocoaError(.fileReadNoPermission) }
            path = "conversations/\(conversation.conversationID)/" + name
        } else {
            path = try await fileRecord(named: name, in: scope)?.path ?? "imports/" + name
        }
        if let text {
            _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
                "action": .string("fileWrite"), "path": .string(path), "text": .string(text),
            ]))
        } else {
            try await DurableProfileStore.shared.writeFile(data: data, path: path, in: scope)
        }
        let published = try await self.file(named: path, in: scope)
        Log.app.info("ProfileRepository.file publish profile=\(scope.profileID?.uuidString ?? "temporary") file=\(name) bytes=\(data.count) binary=\(text == nil)")
        return published
    }

    func readMarkdownFile(named name: String, in scope: ProfileScope) async throws -> MarkdownFileDocument {
        let record = try await requiredFileRecord(named: name, in: scope)
        guard record.file(in: scope).isMarkdown else { throw FileError.unsupportedType(name) }
        let bytes = try await readFileBytes(record, in: scope)
        return MarkdownFileDocument(source: try fileText(bytes), byteCount: bytes.count)
    }

    func writeMarkdownFile(_ source: String, named name: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        guard record.file(in: scope).isMarkdown else { throw FileError.unsupportedType(name) }
        return try await publishFileVersion(source, of: record, in: scope)
    }

    func renameFile(named name: String, to newName: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        let destination = try profileFileName(newName)
        let source = record.file(in: scope)
        if destination == source.fileURL.lastPathComponent { return try await file(named: name, in: scope) }
        let relative = (record.path.split(separator: "/").dropLast().map(String.init) + [destination]).joined(separator: "/")
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileMove"), "path": .string(record.path), "prefix": .string(relative),
        ]))
        Log.app.info("ProfileRepository.file move profile=\(scope.profileID?.uuidString ?? "temporary") from=\(record.path) to=\(relative)")
        return try await file(named: relative, in: scope)
    }

    func deleteFile(named name: String, in scope: ProfileScope) async throws -> FileItem {
        let record = try await requiredFileRecord(named: name, in: scope)
        try await removeProfileFile(path: record.reference ?? record.path, in: scope)
        Log.app.info("ProfileRepository.file remove profile=\(scope.profileID?.uuidString ?? "temporary") file=\(name) physicalBytesRemoved=true")
        return record.file(in: scope)
    }

    private func fileRecord(named name: String, in scope: ProfileScope) async throws -> DurableFileRecord? {
        let path = name.contains("/") ? name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : try profileFileName(name)
        let result = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileStat"), "path": .string(path), "byPath": .bool(name.contains("/")),
        ]))
        guard let value = result.objectValue?["file"] else { throw CocoaError(.fileReadCorruptFile) }
        if value == .null { return nil }
        let record = try JSONDecoder().decode(DurableFileRecord.self, from: JSONEncoder().encode(value))
        guard record.hidden != true, record.path == path || record.reference == path || record.aliases?.contains(path) == true, record.size >= 0, record.size <= (record.binary ? FileLimits.fileBytes : FileLimits.textBytes),
              record.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    private func requiredFileRecord(named name: String, in scope: ProfileScope) async throws -> DurableFileRecord {
        guard let record = try await fileRecord(named: name, in: scope) else { throw FileError.missing(name) }
        return record
    }

    func readFileData(named name: String, in scope: ProfileScope) async throws -> Data {
        let record = try await requiredFileRecord(named: name, in: scope)
        return try await readFileBytes(record, in: scope)
    }

    func copyFile(named name: String, to destination: URL, in scope: ProfileScope) async throws {
        let record = try await requiredFileRecord(named: name, in: scope)
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        try await DurableProfileStore.shared.copyFile(scope: scope, file: value, to: destination)
    }

    private func readFileBytes(_ record: DurableFileRecord, in scope: ProfileScope) async throws -> Data {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
        let bytes = try await DurableProfileStore.shared.readFile(scope: scope, file: value)
        guard bytes.count == record.size else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }

    private func fileText(_ data: Data) throws -> String {
        guard data.count <= FileLimits.textBytes else {
            throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
        return text
    }

    private func publishFileVersion(_ text: String, of record: DurableFileRecord, in scope: ProfileScope) async throws -> FileItem {
        let data = Data(text.utf8)
        _ = try fileText(data)
        _ = try await DurableProfileStore.shared.command(scope: scope, value: .object([
            "action": .string("fileWrite"), "path": .string(record.path), "text": .string(text),
        ]))
        return try await file(named: record.file(in: scope).fileName, in: scope)
    }

    private func availableFileName(_ suggested: String, in scope: ProfileScope) async throws -> String {
        let cleaned = FileStore.sanitizedFilename(suggested.replacingOccurrences(of: "\\", with: " "))
        let files = try await profileFiles(prefix: "imports/", in: scope)
        let visibleCollision = files.contains { $0.path.caseInsensitiveCompare("imports/" + cleaned) == .orderedSame }
        if !visibleCollision, !cleaned.hasPrefix("."), cleaned.utf8.count <= 240,
           try await fileRecord(named: cleaned, in: scope) == nil { return cleaned }
        return versionedFileName(cleaned)
    }

    private func profileFileName(_ name: String) throws -> String {
        let normalized = try FileStore.validatedFilename(name)
        guard !normalized.hasPrefix("."), !normalized.contains("\\"), normalized.utf8.count <= 240 else {
            throw FileError.invalidFilename(name)
        }
        return normalized
    }

    private func versionedFileName(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        var ext = String(url.pathExtension.prefix(32))
        while ext.utf8.count > 64 { ext.removeLast() }
        var stem = String(url.deletingPathExtension().lastPathComponent.prefix(80))
        while stem.utf8.count > 100 { stem.removeLast() }
        if stem.hasPrefix(".") { stem = "File" }
        let version = "\(stem)-\(UUID().uuidString)"
        return ext.isEmpty ? version : "\(version).\(ext)"
    }
}
