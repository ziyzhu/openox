#if targetEnvironment(simulator)
import Foundation
import UIKit
import UniformTypeIdentifiers

extension OxHostProtocol {
    @MainActor
    static func handleSetRegion(_ command: SetRegionRequest, reply: OxHostRPC.Reply) {
        guard let region = LLMRegion(rawValue: command.region) else {
            reply.failure("invalid region: \(command.region)")
            return
        }
        AppRegion.shared.setForTesting(region)
        reply.success()
    }

    @MainActor
    static func handleSetKey(_ command: SetKeyRequest, reply: OxHostRPC.Reply) {
        guard !command.clientId.isEmpty else {
            reply.failure("missing clientId")
            return
        }
        let clientId = command.clientId
        guard let client = ProviderRegistry.shared.client(id: clientId, in: command.region ?? ProviderRegistry.shared.defaultRegion) else {
            reply.failure("unknown client: \(clientId)")
            return
        }
        let credentialID = client.credentialID
        let key = command.key ?? ""
        do {
            if key.isEmpty {
                try Secret.unbind(.provider, id: credentialID)
            } else {
                let definition = try ProviderRegistry.shared.definition(id: clientId)
                try Secret.saveProviderKey(key, definition: definition)
            }
        } catch {
            reply.failure(error.localizedDescription)
            return
        }
        Log.agent.info("OxHostRPC.debug.providers.setKey client=\(clientId) credential=\(credentialID) chars=\(key.count)")
        reply.success()
    }

    @MainActor
    static func handleBootstrapArtifacts(
        _ command: BootstrapArtifactsRequest,
        reply: OxHostRPC.Reply
    ) {
        guard !command.artifacts.isEmpty else {
            reply.failure("no artifacts")
            return
        }
        guard let scope = StorageRoot.currentScope else {
            reply.failure("active Profile unavailable")
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
                Log.app.info("OxHostRPC.debug.artifacts.bootstrap count=\(names.count) files=\(names.joined(separator: ","))")
                reply.success(BootstrapArtifactsResult(artifacts: names))
            } catch {
                for artifact in created.reversed() {
                    _ = try? await ProfileRepository.shared.deleteArtifact(named: artifact.fileName, in: scope)
                }
                Log.app.error("OxHostRPC.debug.artifacts.bootstrap imported=\(created.count) failed=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
            }
        }
    }

    @MainActor
    static func handleWriteArtifact(
        _ command: WriteArtifactRequest,
        reply: OxHostRPC.Reply
    ) {
        guard let scope = StorageRoot.currentScope else {
            reply.failure("active Profile unavailable")
            return
        }
        Task { @MainActor in
            do {
                let artifact = try await ProfileRepository.shared.writeArtifact(
                    data: command.data,
                    named: command.name,
                    in: scope
                )
                Log.app.info("OxHostRPC.debug.artifacts.write file=\(artifact.fileName) bytes=\(command.data.count)")
                reply.success()
            } catch {
                reply.failure(error.localizedDescription)
            }
        }
    }

    @MainActor
    static func handleExportWebsiteData(
        _ command: EmptyRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        Task { @MainActor in
            do {
                let data = try await serviceManager.exportWebsiteData()
                guard data.count <= 64 * 1024 * 1024 else {
                    reply.failure("website data exceeds 67108864 bytes")
                    return
                }
                reply.success(WebsiteDataResult(data: data, bytes: data.count))
            } catch {
                Log.service.error("OxHostProtocol.websiteData export failed scope=global error=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
            }
        }
    }

    @MainActor
    static func handleRestoreWebsiteData(
        _ command: RestoreWebsiteDataRequest,
        serviceManager: ServiceManager,
        reply: OxHostRPC.Reply
    ) {
        guard !command.data.isEmpty else {
            reply.failure("invalid data")
            return
        }
        guard command.data.count <= 64 * 1024 * 1024 else {
            reply.failure("website data exceeds 67108864 bytes")
            return
        }
        Task { @MainActor in
            do {
                try await serviceManager.restoreWebsiteData(command.data)
                reply.success(WebsiteDataResult(data: nil, bytes: command.data.count))
            } catch {
                Log.service.error("OxHostProtocol.websiteData restore failed scope=global error=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
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
