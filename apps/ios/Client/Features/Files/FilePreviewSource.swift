import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct FilePreviewSource: Sendable {
    nonisolated enum Origin: Sendable {
        case profile(ProfileScope)
        case draft
        case device(grantID: String, path: [String], profileID: UUID)
        case unavailable
    }

    let file: FileItem
    let origin: Origin

    var scope: ProfileScope? {
        guard case .profile(let scope) = origin else { return nil }
        return scope
    }

    var canShare: Bool {
        if case .draft = origin { return true }
        return scope != nil
    }

    init(file: FileItem, scope: ProfileScope? = StorageRoot.currentScope) {
        self.file = file
        let root = scope?.root.standardizedFileURL.pathComponents
        let path = file.fileURL.standardizedFileURL.pathComponents
        let draftRoot = FileImporter.stagingDirectory.standardizedFileURL.pathComponents
        let reference = file.fileName.split(separator: "/").map(String.init)
        if path.count > draftRoot.count, path.starts(with: draftRoot) {
            origin = .draft
        } else if let scope, let root, path.count > root.count, path.starts(with: root) {
            origin = .profile(scope)
        } else if let profileID = scope?.profileID, reference.count > 2, reference[0] == "files" {
            origin = .device(grantID: reference[1], path: Array(reference.dropFirst(2)), profileID: profileID)
        } else {
            origin = .unavailable
        }
    }

    func read() async throws -> Data {
        try Task.checkCancellation()
        let data: Data
        switch origin {
        case .profile(let scope) where scope.profileID != nil:
            data = try await ProfileRepository.shared.readFileData(named: file.fileName, in: scope)
        case .draft:
            data = try await Task.detached(priority: .userInitiated) {
                let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= FileLimits.fileBytes else { throw FileError.fileTooLarge(bytes: size, limit: FileLimits.fileBytes) }
                return try Data(contentsOf: file.fileURL)
            }.value
        case .device(let grantID, let path, let profileID):
            data = try await DeviceFolderStore.shared.coordinate(grantID: grantID, relativePath: path, profileId: profileID, mode: .read) { url in
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= FileLimits.fileBytes else { throw FileError.fileTooLarge(bytes: size, limit: FileLimits.fileBytes) }
                return try Data(contentsOf: url)
            }
        case .profile, .unavailable:
            throw CocoaError(.fileReadNoPermission)
        }
        try Task.checkCancellation()
        return data
    }

    func readMarkdown() async throws -> MarkdownFileDocument {
        switch origin {
        case .profile(let scope):
            return try await ProfileRepository.shared.readMarkdownFile(named: file.fileName, in: scope)
        case .device, .draft:
            guard file.isMarkdown else { throw FileError.unsupportedType(file.fileName) }
            let data = try await read()
            return MarkdownFileDocument(source: try Self.text(data), byteCount: data.count)
        case .unavailable:
            throw CocoaError(.fileReadNoPermission)
        }
    }

    func writeMarkdown(_ source: String, replacing previous: String) async throws -> FileItem {
        switch origin {
        case .profile(let scope):
            return try await ProfileRepository.shared.writeMarkdownFile(source, named: file.fileName, in: scope)
        case .device(let grantID, let path, let profileID):
            guard file.isMarkdown else { throw FileError.unsupportedType(file.fileName) }
            let data = Data(source.utf8)
            guard data.count <= FileLimits.textBytes else { throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes) }
            try await DeviceFolderStore.shared.coordinate(grantID: grantID, relativePath: path, profileId: profileID, mode: .write) { url in
                guard try Self.text(Data(contentsOf: url)) == previous else { throw FileError.changedSinceRead(url.lastPathComponent) }
                try data.write(to: url, options: .atomic)
            }
            return file
        case .draft:
            let data = Data(source.utf8)
            guard data.count <= FileLimits.textBytes else { throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes) }
            try await Task.detached(priority: .userInitiated) {
                guard try Self.text(Data(contentsOf: file.fileURL)) == previous else { throw FileError.changedSinceRead(file.displayName) }
                try data.write(to: file.fileURL, options: .atomic)
            }.value
            return file
        case .unavailable:
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func text(_ data: Data) throws -> String {
        guard data.count <= FileLimits.textBytes else { throw FileError.textTooLarge(bytes: data.count, limit: FileLimits.textBytes) }
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.textNotUTF8 }
        return text
    }

    func snapshot() async throws -> FilePreviewSnapshot {
        try Task.checkCancellation()
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try FilePreviewSnapshot(file: file)
        }.value
        switch origin {
        case .profile(let scope) where scope.profileID != nil:
            try await ProfileRepository.shared.copyFile(named: file.fileName, to: snapshot.url, in: scope)
        case .draft:
            let data = try await read()
            try await Task.detached(priority: .userInitiated) { try data.write(to: snapshot.url, options: .atomic) }.value
        case .profile, .device, .unavailable:
            throw CocoaError(.fileReadNoPermission)
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: snapshot.url.path)
        }.value
        return snapshot
    }
}

nonisolated final class FilePreviewSnapshot: Sendable {
    let url: URL
    private let directory: URL

    init(file: FileItem) throws {
        let name = try FileStore.validatedFilename(file.displayName)
        directory = try FileStaging.createDirectory(in: FileManager.default.temporaryDirectory, prefix: "file-preview")
        url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            FileStaging.cleanup(directory, operation: "file-preview")
            throw error
        }
    }

    deinit { FileStaging.cleanup(directory, operation: "file-preview") }
}

nonisolated private struct FileShareContent: Transferable, Sendable {
    let source: FilePreviewSource

    static var transferRepresentation: some TransferRepresentation {
        representation(for: .pdf)
        representation(for: .png)
        representation(for: .jpeg)
        representation(for: .image)
        representation(for: .html)
        representation(for: .json)
        representation(for: .movie)
        representation(for: .audio)
        representation(for: .text)
        representation(for: .data)
    }

    private static func representation(for type: UTType) -> some TransferRepresentation<FileShareContent> {
        DataRepresentation(exportedContentType: type) { (content: FileShareContent) in
            do { return try await content.source.read() }
            catch {
                Log.ui.error("FileShare.read file=\(content.source.file.fileName) error=\(error.localizedDescription)")
                throw error
            }
        }
        .exportingCondition { UTType($0.source.file.typeIdentifier)?.conforms(to: type) == true }
        .suggestedFileName { $0.source.file.displayName }
    }
}

struct FileShareButton<Label: View>: View {
    private let source: FilePreviewSource
    private let label: Label

    init(file: FileItem, scope: ProfileScope? = StorageRoot.currentScope, @ViewBuilder label: () -> Label) {
        source = FilePreviewSource(file: file, scope: scope)
        self.label = label()
    }

    var body: some View {
        ShareLink(item: FileShareContent(source: source), preview: SharePreview(Text(source.file.userFacingName))) {
            label
        }
        .disabled(!source.canShare)
    }
}
