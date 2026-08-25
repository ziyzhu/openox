#if targetEnvironment(simulator)
import Foundation
import UIKit
import UniformTypeIdentifiers

extension OxHostAPI {
    @MainActor
    static func handleSetRegion(_ command: SetRegionRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let region = LLMRegion(rawValue: command.region) else {
            reply(encode(StatusResult(kind: "set-region-result", id: command.id, error: "invalid region: \(command.region)")))
            return
        }
        AppRegion.shared.setForTesting(region)
        reply(encode(StatusResult(kind: "set-region-result", id: command.id)))
    }

    @MainActor
    static func handleSetKey(_ command: SetKeyRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard !command.clientId.isEmpty else {
            reply(encode(StatusResult(kind: "set-key-result", id: command.id, error: "missing clientId")))
            return
        }
        let clientId = command.clientId
        guard let client = LLMRegistry.shared.client(id: clientId) else {
            reply(encode(StatusResult(kind: "set-key-result", id: command.id, error: "unknown client: \(clientId)")))
            return
        }
        let credentialID = client.credentialID
        let key = command.key ?? ""
        if key.isEmpty {
            Credentials.clear(for: credentialID)
        } else {
            Credentials.set(key, for: credentialID)
        }
        Log.agent.info("OxHostAPI.set-key client=\(clientId) credential=\(credentialID) chars=\(key.count)")
        reply(encode(StatusResult(kind: "set-key-result", id: command.id)))
    }

    @MainActor
    static func handleBootstrapArtifacts(
        _ command: BootstrapArtifactsRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard !command.artifacts.isEmpty else {
            reply(encode(BootstrapArtifactsResult(
                id: command.id,
                ok: false,
                artifacts: nil,
                error: "no artifacts"
            )))
            return
        }
        guard let scope = StorageRoot.currentScope else {
            reply(encode(BootstrapArtifactsResult(
                id: command.id,
                ok: false,
                artifacts: nil,
                error: "active Profile unavailable"
            )))
            return
        }
        Task { @MainActor in
            var installed: [Artifact] = []
            var created: [Artifact] = []
            do {
                for artifact in command.artifacts {
                    let existing = await ProfileRepository.shared.artifacts(in: scope)
                    let imported = try await ArtifactImporter.importDataAsync(
                        artifact.data,
                        suggestedName: artifact.name,
                        in: scope
                    )
                    if let duplicate = existing.first(where: { sameBootstrapArtifact($0, imported) }) {
                        _ = try await ProfileRepository.shared.deleteArtifact(named: imported.fileName, in: scope)
                        installed.append(duplicate)
                    } else {
                        installed.append(imported)
                        created.append(imported)
                    }
                }
                let names = installed.map(\.fileName)
                Log.app.info("OxHostAPI.bootstrap-artifacts count=\(names.count) files=\(names.joined(separator: ","))")
                reply(encode(BootstrapArtifactsResult(
                    id: command.id,
                    ok: true,
                    artifacts: names,
                    error: nil
                )))
            } catch {
                for artifact in created.reversed() {
                    _ = try? await ProfileRepository.shared.deleteArtifact(named: artifact.fileName, in: scope)
                }
                Log.app.error("OxHostAPI.bootstrap-artifacts imported=\(created.count) failed=\(error.localizedDescription)")
                reply(encode(BootstrapArtifactsResult(
                    id: command.id,
                    ok: false,
                    artifacts: nil,
                    error: error.localizedDescription
                )))
            }
        }
    }

    @MainActor
    static func handleWriteArtifact(
        _ command: WriteArtifactRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let scope = StorageRoot.currentScope else {
            reply(encode(StatusResult(kind: "write-artifact-result", id: command.id, error: "active Profile unavailable")))
            return
        }
        Task { @MainActor in
            do {
                let artifact = try await ProfileRepository.shared.writeArtifact(
                    data: command.data,
                    named: command.name,
                    in: scope
                )
                Log.app.info("OxHostAPI.write-artifact file=\(artifact.fileName) bytes=\(command.data.count)")
                reply(encode(StatusResult(kind: "write-artifact-result", id: command.id)))
            } catch {
                reply(encode(StatusResult(
                    kind: "write-artifact-result",
                    id: command.id,
                    error: error.localizedDescription
                )))
            }
        }
    }

    @MainActor
    static func handleExportWebsiteData(
        _ command: IDRequest,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard !command.id.isEmpty else {
            reply(encode(WebsiteDataResult(kind: "export-website-data-result", id: command.id, ok: false, data: nil, bytes: nil, error: "invalid request")))
            return
        }
        Task { @MainActor in
            do {
                let data = try await serviceManager.exportWebsiteData()
                guard data.count <= 64 * 1024 * 1024 else {
                    reply(encode(WebsiteDataResult(kind: "export-website-data-result", id: command.id, ok: false, data: nil, bytes: nil, error: "website data exceeds 67108864 bytes")))
                    return
                }
                reply(encode(WebsiteDataResult(kind: "export-website-data-result", id: command.id, ok: true, data: data, bytes: data.count, error: nil)))
            } catch {
                Log.service.error("OxHostAPI.websiteData export failed scope=global error=\(error.localizedDescription)")
                reply(encode(WebsiteDataResult(kind: "export-website-data-result", id: command.id, ok: false, data: nil, bytes: nil, error: error.localizedDescription)))
            }
        }
    }

    @MainActor
    static func handleRestoreWebsiteData(
        _ command: RestoreWebsiteDataRequest,
        serviceManager: ServiceManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard !command.id.isEmpty, !command.data.isEmpty else {
            reply(encode(WebsiteDataResult(kind: "restore-website-data-result", id: command.id, ok: false, data: nil, bytes: nil, error: "invalid data")))
            return
        }
        guard command.data.count <= 64 * 1024 * 1024 else {
            reply(encode(WebsiteDataResult(kind: "restore-website-data-result", id: command.id, ok: false, data: nil, bytes: nil, error: "website data exceeds 67108864 bytes")))
            return
        }
        Task { @MainActor in
            do {
                try await serviceManager.restoreWebsiteData(command.data)
                reply(encode(WebsiteDataResult(kind: "restore-website-data-result", id: command.id, ok: true, data: nil, bytes: command.data.count, error: nil)))
            } catch {
                Log.service.error("OxHostAPI.websiteData restore failed scope=global error=\(error.localizedDescription)")
                reply(encode(WebsiteDataResult(kind: "restore-website-data-result", id: command.id, ok: false, data: nil, bytes: nil, error: error.localizedDescription)))
            }
        }
    }

    static func sameBootstrapArtifact(_ existing: Artifact, _ imported: Artifact) -> Bool {
        guard bootstrapArtifactFamily(existing.fileName) == bootstrapArtifactFamily(imported.fileName),
              existing.size == imported.size,
              let existingData = try? Data(contentsOf: existing.fileURL),
              let importedData = try? Data(contentsOf: imported.fileURL) else { return false }
        return existingData == importedData
    }

    static func bootstrapArtifactFamily(_ fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        var stem = url.deletingPathExtension().lastPathComponent
        if let space = stem.lastIndex(of: " "), Int(stem[stem.index(after: space)...]) != nil {
            stem = String(stem[..<space])
        }
        return "\(stem.lowercased()).\(url.pathExtension.lowercased())"
    }

}
#endif
