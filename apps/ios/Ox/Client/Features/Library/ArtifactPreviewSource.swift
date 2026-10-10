import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ArtifactPreviewSource: Sendable {
    let artifact: Artifact
    let scope: ProfileScope?

    init(artifact: Artifact, scope: ProfileScope? = StorageRoot.currentScope) {
        self.artifact = artifact
        let root = scope?.root.standardizedFileURL.pathComponents
        let path = artifact.fileURL.standardizedFileURL.pathComponents
        self.scope = root.map { path.count > $0.count && path.starts(with: $0) } == true ? scope : nil
    }

    func read() async throws -> Data {
        guard let scope, scope.profileID != nil else { throw CocoaError(.fileReadNoPermission) }
        try Task.checkCancellation()
        let data = try await ProfileRepository.shared.readArtifactData(named: artifact.fileName, in: scope)
        try Task.checkCancellation()
        return data
    }

    func snapshot() async throws -> ArtifactPreviewSnapshot {
        let data = try await read()
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try ArtifactPreviewSnapshot(artifact: artifact, data: data)
        }.value
        try Task.checkCancellation()
        return snapshot
    }
}

nonisolated final class ArtifactPreviewSnapshot: Sendable {
    let url: URL
    private let directory: URL

    init(artifact: Artifact, data: Data) throws {
        let name = try ArtifactStore.validatedFilename(artifact.displayName)
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

nonisolated private struct ArtifactShareContent: Transferable, Sendable {
    let source: ArtifactPreviewSource

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

    private static func representation(for type: UTType) -> some TransferRepresentation<ArtifactShareContent> {
        DataRepresentation(exportedContentType: type) { (content: ArtifactShareContent) in
            do { return try await content.source.read() }
            catch {
                Log.ui.error("ArtifactShare.read file=\(content.source.artifact.fileName) error=\(error.localizedDescription)")
                throw error
            }
        }
        .exportingCondition { UTType($0.source.artifact.typeIdentifier)?.conforms(to: type) == true }
        .suggestedFileName { $0.source.artifact.displayName }
    }
}

struct ArtifactShareButton<Label: View>: View {
    private let source: ArtifactPreviewSource
    private let label: Label

    init(artifact: Artifact, scope: ProfileScope? = StorageRoot.currentScope, @ViewBuilder label: () -> Label) {
        source = ArtifactPreviewSource(artifact: artifact, scope: scope)
        self.label = label()
    }

    var body: some View {
        ShareLink(item: ArtifactShareContent(source: source), preview: SharePreview(Text(source.artifact.userFacingName))) {
            label
        }
        .disabled(source.scope == nil)
    }
}
