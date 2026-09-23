import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let oxService = UTType(exportedAs: AppConfiguration.serviceTypeIdentifier, conformingTo: .zip)
}

nonisolated struct ServicePackageDocument: Transferable, Sendable {
    let domain: String
    let manager: ServiceManager

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .oxService) { document in
            try await document.manager.exportServicePackage(domain: document.domain)
        }
        .suggestedFileName { "\($0.domain).service" }
    }
}

nonisolated struct ServicePackagePayload: Sendable {
    let kind: ServiceRepository.ServiceKind
    let domain: String
    let definition: ServiceDefinition
    let files: [ZipArchiveCodec.File]

    var sourcePrefix: String { "services/\(kind.rawValue)/\(domain)/" }

    func read(_ path: String) throws -> Data {
        guard let file = files.first(where: { $0.path == sourcePrefix + path }) else {
            throw ServicePackageError.invalidSource
        }
        return file.data
    }
}

nonisolated enum ServicePackageError: LocalizedError, Sendable {
    case tooLarge
    case invalidPackage
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This service package is too large."
        case .invalidPackage: "This isn't a valid Ox service package."
        case .invalidSource: "This service package has missing or invalid source files."
        }
    }
}

nonisolated enum ServicePackageCodec {
    private struct Header: Codable {
        let version: Int
        let kind: ServiceRepository.ServiceKind
        let domain: String
    }

    static let maximumPackageBytes = 4_500_000
    private static let maximumSourceBytes = 4_000_000
    private static let maximumFiles = 64

    static func encode(kind: ServiceRepository.ServiceKind, domain: String, files: [ZipArchiveCodec.File]) throws -> Data {
        let header = Header(version: 1, kind: kind, domain: domain)
        let metadata = try JSONEncoder().encode(header)
        let archive = [ZipArchiveCodec.File(path: "package.json", data: metadata)] + files
        let data = try ZipArchiveCodec.encode(archive, maximumArchiveBytes: maximumPackageBytes)
        _ = try decode(data)
        return data
    }

    static func decode(_ data: Data) throws -> ServicePackagePayload {
        let archive: [ZipArchiveCodec.File]
        do {
            archive = try ZipArchiveCodec.decode(
                data,
                maximumArchiveBytes: maximumPackageBytes,
                maximumEntryBytes: maximumSourceBytes,
                maximumEntries: maximumFiles + 1,
                maximumTotalBytes: maximumSourceBytes + 1_000
            )
        } catch ZipArchiveError.tooLarge {
            throw ServicePackageError.tooLarge
        } catch {
            throw ServicePackageError.invalidPackage
        }
        guard let metadata = archive.first(where: { $0.path == "package.json" })?.data,
              let header = try? JSONDecoder().decode(Header.self, from: metadata),
              header.version == 1,
              header.kind == .web || header.kind == .api,
              header.domain.range(of: "^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$", options: .regularExpression) != nil,
              header.kind == .api || header.domain.contains(".") else {
            throw ServicePackageError.invalidPackage
        }
        let prefix = "services/\(header.kind.rawValue)/\(header.domain)/"
        let files = archive.filter { $0.path != "package.json" }
        guard !files.isEmpty,
              files.count <= maximumFiles,
              files.allSatisfy({ $0.path.hasPrefix(prefix) && $0.path.count > prefix.count }),
              files.reduce(0, { $0 + $1.data.count }) <= maximumSourceBytes,
              let manifest = files.first(where: { $0.path == prefix + "service.json" })?.data,
              files.contains(where: { $0.path == prefix + "actions.js" }),
              let raw = try? JSONDecoder().decode(JSONValue.self, from: manifest),
              let definition = try? ServiceDefinition(manifest: raw, repositoryID: ServiceRepository.localID, provenance: .local),
              definition.domain == header.domain,
              definition.isAPI == (header.kind == .api) else {
            throw ServicePackageError.invalidSource
        }
        return ServicePackagePayload(kind: header.kind, domain: header.domain, definition: definition, files: files)
    }
}

nonisolated struct ServiceImportProposal: Identifiable, Sendable {
    let id = UUID()
    let payload: ServicePackagePayload
    let sourceName: String
}

@MainActor
@Observable
final class ServiceImportCoordinator {
    let manager: ServiceManager
    private(set) var proposal: ServiceImportProposal?
    private(set) var errorMessage: String?
    private(set) var importedDomain: String?
    private(set) var isSaving = false
    @ObservationIgnored private var operation: Task<Void, Never>?

    init(manager: ServiceManager) {
        self.manager = manager
    }

    func receive(_ url: URL) {
        guard !isSaving else {
            errorMessage = "Wait for the current service import to finish."
            return
        }
        operation?.cancel()
        proposal = nil
        errorMessage = nil
        importedDomain = nil
        operation = Task {
            do {
                let proposal = try await Task.detached(priority: .userInitiated) {
                    guard url.pathExtension.lowercased() == "service" else {
                        throw ServicePackageError.invalidPackage
                    }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > ServicePackageCodec.maximumPackageBytes {
                        throw ServicePackageError.tooLarge
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try ServiceImportProposal(
                        payload: ServicePackageCodec.decode(data),
                        sourceName: url.lastPathComponent
                    )
                }.value
                guard !Task.isCancelled else { return }
                self.proposal = proposal
                Log.ui.info("ServiceImport.ready id=\(proposal.payload.domain) source=\(proposal.sourceName)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                Log.ui.error("ServiceImport.open source=\(url.lastPathComponent) failed=\(error.localizedDescription)")
            }
        }
    }

    func install(replacing: Bool) {
        guard let proposal else { return }
        isSaving = true
        operation = Task {
            do {
                try await manager.importServicePackage(
                    proposal.payload,
                    replacing: replacing,
                    locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
                )
                guard !Task.isCancelled else { return }
                self.proposal = nil
                importedDomain = proposal.payload.domain
                isSaving = false
                Log.ui.info("ServiceImport.saved id=\(proposal.payload.domain) replaced=\(replacing)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isSaving = false
                errorMessage = error.localizedDescription
                Log.ui.error("ServiceImport.save id=\(proposal.payload.domain) failed=\(error.localizedDescription)")
            }
        }
    }

    func dismissProposal() {
        guard !isSaving else { return }
        proposal = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissSuccess() {
        importedDomain = nil
    }
}
