import Foundation
import UniformTypeIdentifiers

extension Conversation {
    func importRemoteMCPFiles(_ values: [RemoteMCPFile]) async throws {
        guard !values.isEmpty else { return }
        try requireProfileMutation(Actions.fsWrite)
        var files: [FileItem] = []
        for value in values {
            files.append(try await FileImporter.importDataAsync(
                value.data,
                suggestedName: value.suggestedFilename,
                in: scope,
                conversation: durableRoute?.reference
            ))
        }
        for file in files { embedFile(file) }
        Log.session.info("Conversation.importRemoteMCPFiles count=\(files.count) bytes=\(values.reduce(0) { $0 + $1.data.count })")
    }
}

nonisolated public enum FileImporter {
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

    private static func imageDataDraft(_ data: Data, suggestedName: String?) throws -> Draft {
        do {
            let prepared = try ImagePreparer.prepare(data)
            return Draft(data: prepared.data, fileName: prepared.filename(from: suggestedName))
        } catch ImagePreparationError.encode {
            throw FileError.imageEncodeFailed
        } catch {
            throw FileError.imageDecodeFailed
        }
    }

    private static func fileDraft(at url: URL) throws -> Draft {
        let data = try Data(contentsOf: url)
        return try dataDraft(data, suggestedName: url.lastPathComponent)
    }

    private static func dataDraft(_ data: Data, suggestedName: String) throws -> Draft {
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
