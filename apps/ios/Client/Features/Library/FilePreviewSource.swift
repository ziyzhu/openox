import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct FilePreviewSource: Sendable {
    let artifact: FileItem
    let scope: ProfileScope?

    init(artifact: FileItem, scope: ProfileScope? = StorageRoot.currentScope) {
        self.artifact = artifact
        let root = scope?.root.standardizedFileURL.pathComponents
        let path = artifact.fileURL.standardizedFileURL.pathComponents
        self.scope = root.map { path.count > $0.count && path.starts(with: $0) } == true ? scope : nil
    }

    func read() async throws -> Data {
        guard let scope, scope.profileID != nil else { throw CocoaError(.fileReadNoPermission) }
        try Task.checkCancellation()
        let data = try await ProfileRepository.shared.readFileData(named: artifact.fileName, in: scope)
        try Task.checkCancellation()
        return data
    }

    func snapshot() async throws -> FilePreviewSnapshot {
        let data = try await read()
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try FilePreviewSnapshot(artifact: artifact, data: data)
        }.value
        try Task.checkCancellation()
        return snapshot
    }
}

nonisolated final class FilePreviewSnapshot: Sendable {
    let url: URL
    private let directory: URL

    init(artifact: FileItem, data: Data) throws {
        let name = try FileStore.validatedFilename(artifact.displayName)
        directory = try FileStaging.createDirectory(in: FileManager.default.temporaryDirectory, prefix: "artifact-preview")
        url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        } catch {
            FileStaging.cleanup(directory, operation: "artifact-preview")
            throw error
        }
    }

    deinit { FileStaging.cleanup(directory, operation: "artifact-preview") }
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
                Log.ui.error("FileShare.read file=\(content.source.artifact.fileName) error=\(error.localizedDescription)")
                throw error
            }
        }
        .exportingCondition { UTType($0.source.artifact.typeIdentifier)?.conforms(to: type) == true }
        .suggestedFileName { $0.source.artifact.displayName }
    }
}

struct FileShareButton<Label: View>: View {
    private let source: FilePreviewSource
    private let label: Label

    init(artifact: FileItem, scope: ProfileScope? = StorageRoot.currentScope, @ViewBuilder label: () -> Label) {
        source = FilePreviewSource(artifact: artifact, scope: scope)
        self.label = label()
    }

    var body: some View {
        ShareLink(item: FileShareContent(source: source), preview: SharePreview(Text(source.artifact.userFacingName))) {
            label
        }
        .disabled(source.scope == nil)
    }
}
