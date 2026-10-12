import Foundation

extension OxHostProtocol {
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
        if let id { return try HostProfileCommands.profile(id).id }
        guard let id = StorageRoot.shared.activeId else { throw RuntimeError.bridge("Select a Profile before managing mounts") }
        return id
    }

    @MainActor
    static func handleAssignFolder(_ command: FolderGrantRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("files.assign", host: host, reply: reply, mutation: true) {
            try await DeviceFolderStore.shared.assign(command.grantId, profileId: folderProfile(command.profileId))
            await host.services.refreshServices(locale: repositoryLocale)
            return .object([:])
        }
    }

    @MainActor
    static func handleListFolderGrants(_ command: FolderProfileRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("files.list", host: host, reply: reply) {
            .object(["folders": .array(DeviceFolderStore.shared.grants(for: try folderProfile(command.profileId)).map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            }), "unassignedFolders": .array(DeviceFolderStore.shared.grants.filter { $0.profileId == nil }.map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            })])
        }
    }

    @MainActor
    static func handleMountFolder(_ command: FolderProfileRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("files.mount", host: host, reply: reply, mutation: true) {
            guard host.executionAvailable else { throw RuntimeError.bridge("Bring the Host app to the foreground to authorize folder access") }
            let profileId = try folderProfile(command.profileId)
            let url = try await HostFolderPicker.choose()
            _ = try HostProfileCommands.profile(profileId.uuidString)
            let grant = try await DeviceFolderStore.shared.add(url, profileId: profileId)
            return .object(["folder": .object(["id": .string(grant.id), "name": .string(grant.name)])])
        }
    }

    @MainActor
    static func handleUnmountFolder(_ command: FolderGrantRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("files.unmount", host: host, reply: reply, mutation: true) {
            try await DeviceFolderStore.shared.remove(command.grantId, profileId: folderProfile(command.profileId))
            await host.services.refreshServices(locale: repositoryLocale)
            return .object([:])
        }
    }

    @MainActor
    static func handleListRepositories(_ command: EmptyRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("repositories.list", host: host, reply: reply) {
            await host.services.refreshServices(locale: repositoryLocale)
            return .object(["repositories": .array(host.services.repositories.map(repositoryRow))])
        }
    }

    @MainActor
    static func handleConnectRepositoryFolder(_ command: MountedRepositoryRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("repositories.connectFolder", host: host, reply: reply, mutation: true) {
            let repository = try await host.services.connectMountedRepository(path: command.path, locale: repositoryLocale)
            return .object(["repository": repositoryRow(repository)])
        }
    }

    @MainActor
    static func handleDisconnectRepositoryFolder(_ command: RepositoryIDRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("repositories.disconnectFolder", host: host, reply: reply, mutation: true) {
            try await host.services.disconnectMountedRepository(command.repositoryId, locale: repositoryLocale)
            return .object([:])
        }
    }
}
