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

nonisolated struct LocalPackageExport: Sendable {
    let name: String
    let services: [String]
    let skills: [String]
    let manifest: String
    let files: [ZipArchiveCodec.File]
}

extension Repository {
    func exportLocalPackage(named name: String, services: [String], skills: [String]) throws -> LocalPackageExport {
        try materializeLocalRepository()
        let local = try Self.loadPackage(at: localRoot, provenance: .local)
        let chosenServices = try services.map { id in
            guard let service = local.services.first(where: { $0.id.runtimeID == id }) else {
                throw Failure(message: "No Local service exists for \(id).")
            }
            try Self.validateService(service, root: localRoot)
            return service
        }.sorted { $0.id.rawValue < $1.id.rawValue }
        let chosenSkills = try skills.map { skill in
            guard local.skills.contains(skill) else { throw Failure(message: "No Local skill exists for \(skill).") }
            return skill
        }.sorted()
        let package = Package(version: RuntimeProtocols.repository.last!, name: name, contentHash: nil, services: chosenServices, skills: chosenSkills)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var manifest = try encoder.encode(package)
        manifest.append(0x0A)
        var files = [ZipArchiveCodec.File(path: "repository.json", data: manifest)]
        for path in chosenServices.map({ $0.id.path }) + chosenSkills.map({ "skills/\($0)" }) {
            let available = try Self.forEachFile(in: localRoot.appendingPathComponent(path, isDirectory: true)) { url, values, relative in
                guard values.isSymbolicLink != true else { throw Failure(message: "Local source contains a symbolic link: \(path)") }
                guard values.isRegularFile == true else { return true }
                files.append(.init(path: "\(path)/\(relative)", data: try Data(contentsOf: url)))
                return true
            }
            guard available else { throw Failure(message: "Local source is unavailable: \(path)") }
        }
        Log.service.info("Repository.export repository=local services=\(chosenServices.count) skills=\(chosenSkills.count) files=\(files.count)")
        return LocalPackageExport(
            name: name, services: chosenServices.map { $0.id.rawValue }, skills: chosenSkills,
            manifest: String(decoding: manifest, as: UTF8.self), files: files.sorted { $0.path < $1.path }
        )
    }
}
