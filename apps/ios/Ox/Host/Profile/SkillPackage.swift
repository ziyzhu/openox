import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let agentSkill = UTType(exportedAs: AppConfiguration.agentSkillTypeIdentifier, conformingTo: .zip)
}

nonisolated struct SkillPackageDocument: Transferable, Sendable {
    let skill: Skill

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .agentSkill) { document in
            let data = try SkillPackageCodec.encode(document.skill)
            Log.ui.info("SkillPackage.export name=\(document.skill.name) bytes=\(data.count)")
            return data
        }
        .suggestedFileName { "\($0.skill.name).skill" }
    }
}

nonisolated struct SkillImportProposal: Identifiable, Equatable, Sendable {
    let id = UUID()
    let skill: Skill
    let sourceName: String
}

nonisolated enum SkillPackageError: LocalizedError, Sendable {
    case tooLarge
    case invalidArchive
    case encrypted
    case unsupportedCompression
    case unsafePath
    case unsupportedResources
    case invalidSkill
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .tooLarge: "This skill package is too large."
        case .invalidArchive: "This isn't a valid skill package."
        case .encrypted: "Encrypted skill packages aren't supported."
        case .unsupportedCompression: "This skill package uses unsupported compression."
        case .unsafePath: "This skill package contains an unsafe path."
        case .unsupportedResources: "This skill includes additional files that Ox doesn't support yet."
        case .invalidSkill: "This package doesn't contain a valid SKILL.md."
        case .checksumMismatch: "This skill package appears to be damaged."
        }
    }
}

nonisolated enum SkillPackageCodec {
    static let maximumPackageBytes = 1_048_576
    static let maximumSkillBytes = 524_288
    private static let maximumEntries = 64

    static func encode(_ skill: Skill) throws -> Data {
        try SkillFiles.validate(skill)
        var resources = skill.resources ?? [:]
        resources[SkillFiles.fileName] = SkillFiles.serialize(skill)
        return try zip {
            try ZipArchiveCodec.encode(
                resources.sorted { $0.key < $1.key }.map { .init(path: "\(skill.name)/\($0.key)", data: Data($0.value.utf8)) },
                maximumArchiveBytes: maximumPackageBytes
            )
        }
    }

    static func decode(_ data: Data, sourceName: String) throws -> SkillImportProposal {
        let files = try zip {
            try ZipArchiveCodec.decode(
                data,
                maximumArchiveBytes: maximumPackageBytes,
                maximumEntryBytes: maximumSkillBytes,
                maximumEntries: maximumEntries
            )
        }
        guard let main = files.first(where: { $0.path.hasSuffix("/SKILL.md") }),
              let name = main.path.split(separator: "/").first.map(String.init),
              main.path == "\(name)/SKILL.md", SkillFiles.isUserName(name),
              !SkillFiles.reservedNames.contains(name),
              let text = String(data: main.data, encoding: .utf8),
              var skill = SkillFiles.parse(text, directoryName: name) else { throw SkillPackageError.invalidSkill }
        var resources: [String: String] = [:]
        for file in files where file.path != main.path {
            guard file.path.hasPrefix(name + "/") else { throw SkillPackageError.unsafePath }
            let relative = String(file.path.dropFirst(name.count + 1))
            guard SkillFiles.isResourcePath(relative), resources[relative] == nil,
                  let content = String(data: file.data, encoding: .utf8) else { throw SkillPackageError.invalidSkill }
            resources[relative] = content
        }
        skill.resources = resources.isEmpty ? nil : resources
        try SkillFiles.validate(skill)
        return SkillImportProposal(skill: skill, sourceName: sourceName)
    }

    private static func zip<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as ZipArchiveError {
            switch error {
            case .tooLarge: throw SkillPackageError.tooLarge
            case .invalidArchive: throw SkillPackageError.invalidArchive
            case .encrypted: throw SkillPackageError.encrypted
            case .unsupportedCompression: throw SkillPackageError.unsupportedCompression
            case .unsafePath: throw SkillPackageError.unsafePath
            case .checksumMismatch: throw SkillPackageError.checksumMismatch
            }
        }
    }
}
@MainActor
@Observable
final class SkillImportCoordinator {
    enum Resolution: Sendable {
        case add
        case replace
        case copy
    }

    private(set) var proposal: SkillImportProposal?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var importedSkill: Skill?
    @ObservationIgnored private var operation: Task<Void, Never>?

    func receive(_ url: URL) {
        operation?.cancel()
        let request = UUID()
        isLoading = true
        isSaving = false
        proposal = nil
        errorMessage = nil
        importedSkill = nil
        operation = Task {
            do {
                let proposal = try await Task.detached(priority: .userInitiated) {
                    guard url.pathExtension.lowercased() == "skill" else {
                        throw SkillPackageError.invalidSkill
                    }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       size > SkillPackageCodec.maximumPackageBytes {
                        throw SkillPackageError.tooLarge
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try SkillPackageCodec.decode(data, sourceName: url.lastPathComponent)
                }.value
                guard !Task.isCancelled else { return }
                self.proposal = proposal
                self.isLoading = false
                Log.ui.info("SkillImport.ready request=\(request) name=\(proposal.skill.name) source=\(proposal.sourceName)")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                Log.ui.error("SkillImport.open request=\(request) source=\(url.lastPathComponent) failed=\(error.localizedDescription)")
            }
        }
    }

    func install(_ resolution: Resolution) {
        guard let proposal,
              let scope = StorageRoot.currentScope,
              scope.profileID != nil else {
            errorMessage = "Your Profile is still opening. Try again in a moment."
            return
        }
        isSaving = true
        operation = Task {
            do {
                let repository = ProfileRepository.shared
                var skill = proposal.skill
                var replacing: String?
                switch resolution {
                case .add:
                    break
                case .replace:
                    replacing = skill.name
                case .copy:
                    let existing = Set(await repository.skills(in: scope).map(\.name))
                    let base = skill.name
                    var suffix = 2
                    while existing.contains(skill.name) {
                        skill.name = "\(base)-\(suffix)"
                        suffix += 1
                    }
                }
                let saved = try await repository.saveSkill(
                    name: skill.name,
                    description: skill.description,
                    instructions: skill.instructions,
                    services: skill.services,
                    replacing: replacing,
                    resources: proposal.skill.resources,
                    in: scope
                )
                guard !Task.isCancelled else { return }
                self.proposal = nil
                isSaving = false
                importedSkill = saved
                Skills.shared.refresh()
                Log.ui.info("SkillImport.saved name=\(saved.name) resolution=\(String(describing: resolution))")
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                isSaving = false
                errorMessage = error.localizedDescription
                Log.ui.error("SkillImport.save name=\(proposal.skill.name) failed=\(error.localizedDescription)")
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

    func consumeImportedSkill() {
        importedSkill = nil
    }
}
