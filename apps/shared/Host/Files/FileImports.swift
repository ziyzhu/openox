import Foundation
import UniformTypeIdentifiers

extension Conversation {
    func importAttachments(_ staged: [FileImporter.StagedFile]) async throws -> [FileItem] {
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Conversation files are unavailable") }
        var published: [FileItem] = []
        do {
            for source in staged {
                let draft = try await Task.detached(priority: .userInitiated) {
                    FileImporter.Draft(data: try Data(contentsOf: source.file.fileURL), fileName: source.file.displayName)
                }.value
                published.append(try await importAttachment(draft))
            }
            Log.session.info("Conversation.importAttachments conversation=\(id) count=\(published.count) temporary=\(isTemporary)")
            return published
        } catch {
            for file in published {
                do {
                    _ = try await route.session.runtime.command(.object([
                        "action": .string("fileDiscard"), "reference": route.runtimeReference, "path": .string(file.fileName),
                    ]))
                } catch {
                    Log.session.error("Conversation.importAttachments rollback conversation=\(id) file=\(file.fileName) error=\(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    func importAttachment(data: Data, suggestedName: String) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try FileImporter.dataDraft(data, suggestedName: suggestedName)
        }.value
        return try await importAttachment(draft)
    }

    func importAttachment(_ draft: FileImporter.Draft) async throws -> FileItem {
        try await durablePreparation?.value
        guard let route = durableRoute else { throw RuntimeError.bridge("Conversation files are unavailable") }
        if let reference = route.reference {
            return try await FileImporter.write(draft, in: scope, conversation: reference)
        }
        let folder = "conversations/\(route.conversationID)/"
        var name = draft.fileName
        let existing = try await route.session.runtime.command(.object([
            "action": .string("fileStat"), "path": .string(folder + name), "byPath": .bool(true),
        ]))
        if existing.objectValue?["file"] != .null {
            name = FileStore.sanitizedFilename(UUID().uuidString + "-" + name)
        }
        let path = folder + name
        let file = FileItem(fileName: name, directory: scope.root)
        if file.kind == .text || file.kind == .html, let text = String(data: draft.data, encoding: .utf8) {
            _ = try await route.session.runtime.command(.object([
                "action": .string("fileWrite"), "path": .string(path), "text": .string(text),
            ]))
        } else {
            try await route.session.runtime.writeFile(data: draft.data, path: path)
        }
        guard let published = await durableFile(path: path) else { throw RuntimeError.bridge("Imported file is unavailable") }
        return published.file
    }

    func importRemoteMCPFiles(_ values: [RemoteMCPFile]) async throws {
        guard !values.isEmpty else { return }
        try requireProfileMutation(Actions.fsWrite)
        var files: [FileItem] = []
        for value in values {
            files.append(try await importAttachment(data: value.data, suggestedName: value.suggestedFilename))
        }
        for file in files { embedFile(file) }
        Log.session.info("Conversation.importRemoteMCPFiles count=\(files.count) bytes=\(values.reduce(0) { $0 + $1.data.count })")
    }
}

nonisolated public enum FileImporter {
    static let stagingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DraftFiles", isDirectory: true)

    final class StagedFile: Sendable, Equatable {
        let file: FileItem

        fileprivate init(file: FileItem) { self.file = file }

        static func == (lhs: StagedFile, rhs: StagedFile) -> Bool { lhs === rhs }

        func discard() { Self.discard(directory: file.fileURL.deletingLastPathComponent()) }

        deinit { Self.discard(directory: file.fileURL.deletingLastPathComponent()) }

        private static func discard(directory: URL) {
            Task.detached(priority: .utility) {
                do {
                    try FileManager.default.removeItem(at: directory)
                    Log.session.info("FileImporter.stage removed draft=\(directory.lastPathComponent)")
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    return
                } catch {
                    Log.session.error("FileImporter.stage cleanup draft=\(directory.lastPathComponent) error=\(error.localizedDescription)")
                }
            }
        }
    }

    static func stage(_ draft: Draft) throws -> StagedFile {
        let id = UUID().uuidString
        let directory = stagingDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try draft.data.write(to: directory.appendingPathComponent(draft.fileName), options: .atomic)
            Log.session.info("FileImporter.stage ready draft=\(id) bytes=\(draft.data.count)")
            return StagedFile(file: FileItem(fileName: "draft-" + id, directory: directory, relativePath: draft.fileName))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    struct Draft: Sendable {
        let data: Data
        let fileName: String
    }

    public static func importImageDataAsync(_ data: Data, suggestedName: String?) async throws -> FileItem {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        return try await importImageDataAsync(data, suggestedName: suggestedName, in: scope)
    }

    static func importImageDataAsync(
        _ data: Data,
        suggestedName: String?,
        in scope: ProfileScope
    ) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try imageDataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope)
    }

    public static func importFileAsync(at url: URL) async throws -> FileItem {
        guard let scope = StorageRoot.currentScope else { throw CocoaError(.fileNoSuchFile) }
        return try await importFileAsync(at: url, in: scope)
    }

    static func importFileAsync(at url: URL, in scope: ProfileScope) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try fileDraft(at: url)
        }.value
        return try await write(draft, in: scope)
    }

    static func importDataAsync(_ data: Data, suggestedName: String, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        let draft = try await Task.detached(priority: .userInitiated) {
            try dataDraft(data, suggestedName: suggestedName)
        }.value
        return try await write(draft, in: scope, conversation: conversation)
    }

    static func imageDataDraft(_ data: Data, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(data)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw FileError.imageEncodeFailed
        } catch {
            throw FileError.imageDecodeFailed
        }
    }

    static func fileDraft(at url: URL) throws -> Draft {
        let data = try Data(contentsOf: url)
        return try dataDraft(data, suggestedName: url.lastPathComponent)
    }

    static func dataDraft(_ data: Data, suggestedName: String) throws -> Draft {
        let fileName = FileStore.sanitizedFilename(suggestedName)
        let type = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension) ?? .data
        if type.conforms(to: .image) {
            return try imageDataDraft(data, suggestedName: fileName)
        }
        if type.conforms(to: .pdf) {
            _ = try PDFPreparer.prepareFile(data)
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode)
            || type.conforms(to: .json) || type.conforms(to: .commaSeparatedText) {
            guard data.count <= FileLimits.textBytes else {
                throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes)
            }
            guard String(data: data, encoding: .utf8) != nil else { throw FileError.textNotUTF8 }
        } else if data.count > FileLimits.fileBytes {
            throw FileError.fileTooLarge(bytes: data.count, limit: FileLimits.fileBytes)
        }
        return Draft(data: data, fileName: fileName)
    }

    static func write(_ draft: Draft, in scope: ProfileScope, conversation: DurableConversationReference? = nil) async throws -> FileItem {
        try await ProfileRepository.shared.importFile(data: draft.data, suggestedName: draft.fileName, in: scope, conversation: conversation)
    }

}
