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
    let kind: Repository.ServiceKind
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
        let kind: Repository.ServiceKind
        let domain: String
    }

    static let maximumPackageBytes = 4_500_000
    private static let maximumSourceBytes = 4_000_000
    private static let maximumFiles = 64

    static func encode(kind: Repository.ServiceKind, domain: String, files: [ZipArchiveCodec.File]) throws -> Data {
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
              let definition = try? ServiceDefinition(manifest: raw, repositoryID: Repository.localID, provenance: .local),
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
    private enum State {
        case idle
        case loading(Task<Void, Never>)
        case reviewing(ServiceImportProposal)
        case saving(ServiceImportProposal)
        case imported(String)
    }

    let manager: ServiceManager
    private var state = State.idle
    private(set) var errorMessage: String?
    var proposal: ServiceImportProposal? {
        switch state {
        case .reviewing(let proposal), .saving(let proposal): proposal
        case .idle, .loading, .imported: nil
        }
    }
    var isSaving: Bool {
        if case .saving = state { true } else { false }
    }
    var importedDomain: String? {
        if case .imported(let domain) = state { domain } else { nil }
    }

    init(manager: ServiceManager) {
        self.manager = manager
    }

    func receive(_ url: URL) {
        guard !isSaving else {
            errorMessage = "Wait for the current service import to finish."
            Log.ui.info("ServiceImport.rejected reason=saving source=\(url.lastPathComponent)")
            return
        }
        if case .loading(let operation) = state { operation.cancel() }
        errorMessage = nil
        state = .loading(Task {
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
                state = .reviewing(proposal)
                Log.ui.info("ServiceImport.ready id=\(proposal.payload.domain) source=\(proposal.sourceName)")
            } catch {
                guard !Task.isCancelled else { return }
                state = .idle
                errorMessage = error.localizedDescription
                Log.ui.error("ServiceImport.open source=\(url.lastPathComponent) failed=\(error.localizedDescription)")
            }
        })
    }

    func install(replacing: Bool) {
        guard case .reviewing(let proposal) = state else { return }
        state = .saving(proposal)
        Task {
            do {
                try await manager.importServicePackage(
                    proposal.payload,
                    replacing: replacing,
                    locale: AppLocale.shared.serviceLocale(for: AppRegion.shared.region)
                )
                state = .imported(proposal.payload.domain)
                Log.ui.info("ServiceImport.saved id=\(proposal.payload.domain) replaced=\(replacing)")
            } catch {
                state = .reviewing(proposal)
                errorMessage = error.localizedDescription
                Log.ui.error("ServiceImport.save id=\(proposal.payload.domain) failed=\(error.localizedDescription)")
            }
        }
    }

    func dismissProposal() {
        guard case .reviewing = state else { return }
        state = .idle
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissSuccess() {
        guard case .imported = state else { return }
        state = .idle
    }
}
