import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct LocalRepositoryExport: Transferable, Sendable {
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { export in
            SentTransferredFile(export.file, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { _ in "Local Repository" }
    }
}
