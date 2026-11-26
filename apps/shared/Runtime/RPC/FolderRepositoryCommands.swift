import Foundation

extension ProfileProtocol {
    @MainActor
    private static var repositoryLocale: String? { AppLocale.shared.serviceLocale(for: AppRegion.shared.region) }

    @MainActor
    private static func repositoryRow(_ repository: Repository.Descriptor) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(repository.id), "name": .string(repository.name),
            "provenance": .string(repository.provenance.rawValue), "enabled": .bool(repository.isEnabled),
        ]
        switch repository.state {
        case .ready: value["state"] = .string("ready")
        case .failed(let message):
            value["state"] = .string("failed")
            value["error"] = .string(message)
        }
        return .object(value)
    }

    @MainActor
    private static func folderProfile(_ id: String?) throws -> UUID {
        if let id { return try ProfileCommands.profile(id).id }
        guard let id = StorageRoot.shared.activeId else { throw RuntimeError.bridge("Select a Profile before managing mounts") }
        return id
    }

    @MainActor
    static func handleAssignFolder(_ command: FolderGrantRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("files.assign", runtime: runtime, reply: reply, mutation: true) {
            try await DeviceFolderStore.shared.assign(command.grantId, profileId: folderProfile(command.profileId))
            await runtime.services.refreshServices(locale: repositoryLocale)
            return .object([:])
        }
    }

    @MainActor
    static func handleListFolderGrants(_ command: FolderProfileRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("files.list", runtime: runtime, reply: reply) {
            .object(["folders": .array(DeviceFolderStore.shared.grants(for: try folderProfile(command.profileId)).map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            }), "unassignedFolders": .array(DeviceFolderStore.shared.grants.filter { $0.profileId == nil }.map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            })])
        }
    }

    @MainActor
    static func handleMountFolder(_ command: FolderProfileRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("files.mount", runtime: runtime, reply: reply, mutation: true) {
            guard runtime.executionAvailable else { throw RuntimeError.bridge("Bring Ox to the foreground to authorize folder access") }
            let profileId = try folderProfile(command.profileId)
            let url = try await FolderPicker.choose()
            _ = try ProfileCommands.profile(profileId.uuidString)
            let grant = try await DeviceFolderStore.shared.add(url, profileId: profileId)
            return .object(["folder": .object(["id": .string(grant.id), "name": .string(grant.name)])])
        }
    }

    @MainActor
    static func handleUnmountFolder(_ command: FolderGrantRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("files.unmount", runtime: runtime, reply: reply, mutation: true) {
            try await DeviceFolderStore.shared.remove(command.grantId, profileId: folderProfile(command.profileId))
            await runtime.services.refreshServices(locale: repositoryLocale)
            return .object([:])
        }
    }

    @MainActor
    static func handleListRepositories(_ command: EmptyRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("repositories.list", runtime: runtime, reply: reply) {
            await runtime.services.refreshServices(locale: repositoryLocale)
            return .object(["repositories": .array(runtime.services.repositories.map(repositoryRow))])
        }
    }

    @MainActor
    static func handleConnectRepositoryFolder(_ command: MountedRepositoryRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("repositories.connectFolder", runtime: runtime, reply: reply, mutation: true) {
            let repository = try await runtime.services.connectMountedRepository(path: command.path, locale: repositoryLocale)
            return .object(["repository": repositoryRow(repository)])
        }
    }

    @MainActor
    static func handleDisconnectRepositoryFolder(_ command: RepositoryIDRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("repositories.disconnectFolder", runtime: runtime, reply: reply, mutation: true) {
            try await runtime.services.disconnectMountedRepository(command.repositoryId, locale: repositoryLocale)
            return .object([:])
        }
    }
}
