import Foundation

@MainActor
enum HostProfileCommands {
    private(set) static var operation: String?

    static func perform(
        _ name: String, host: any OxHost, reply: OxHostRPC.Reply,
        mutation: Bool = false, body: @escaping @MainActor () async throws -> JSONValue
    ) {
        guard operation == nil, !StorageRoot.shared.isBusy else {
            reply.failure("A Host administration operation is in progress; retry after it completes")
            return
        }
        if mutation { operation = name }
        Task {
            defer { if mutation { operation = nil } }
            do {
                try await host.prepare()
                let result = try await body()
                Log.app.info("HostAdministration completed operation=\(name)")
                reply.success(result)
            } catch {
                Log.app.error("HostAdministration failed operation=\(name) error=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
            }
        }
    }

    static func profile(_ id: String) throws -> Profile {
        guard let uuid = UUID(uuidString: id),
              let profile = StorageRoot.shared.profiles.first(where: { $0.id == uuid }) else {
            throw RuntimeError.bridge("Unknown Host Profile: \(id)")
        }
        return profile
    }

    static func row(_ profile: Profile) -> JSONValue {
        .object([
            "id": .string(profile.id.uuidString), "name": .string(profile.name),
            "location": .string(profile.location.rawValue), "version": .string(profile.version),
            "active": .bool(StorageRoot.shared.activeId == profile.id),
        ])
    }

    static func result(_ profile: Profile, contents: Bool = false) async throws -> JSONValue {
        var result: [String: JSONValue] = ["profile": row(profile)]
        if contents {
            guard profile.version == ProfileSchema.current, profile.location == .local else {
                throw RuntimeError.bridge("Select a supported local Profile before reading or updating its contents")
            }
            let scope = ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
            result["memory"] = .string(try await ProfileRepository.shared.readTextFile(named: "MEMORY.md", in: scope) ?? "")
            result["soul"] = .string(try await ProfileRepository.shared.readTextFile(named: "SOUL.md", in: scope) ?? "")
        }
        return .object(result)
    }

    static func requireIdle(_ host: any OxHost) throws {
        guard !host.conversations.activities.values.contains(where: {
            if case .running = $0 { return true }
            return false
        }) else { throw RuntimeError.bridge("Stop running conversations before updating or selecting a Profile") }
    }
}

extension OxHostProtocol {
    @MainActor
    static func handleListProfiles(_ command: EmptyRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("list", host: host, reply: reply) {
            .object(["profiles": .array(StorageRoot.shared.profiles.map(HostProfileCommands.row))])
        }
    }

    @MainActor
    static func handleInspectProfile(_ command: ProfileRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("inspect", host: host, reply: reply) {
            try await HostProfileCommands.result(HostProfileCommands.profile(command.profileId), contents: true)
        }
    }

    @MainActor
    static func handleCreateProfile(_ command: CreateProfileRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("create", host: host, reply: reply, mutation: true) {
            let storage = StorageRoot.shared
            let name = StorageRoot.cleanName(command.name)
            guard !command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 100, !storage.nameTaken(name) else { throw RuntimeError.bridge("Invalid or duplicate Profile name") }
            let existing = Set(storage.profiles.map(\.id))
            try await storage.createProfile(name: name, location: .local)
            guard let created = storage.profiles.first(where: { !existing.contains($0.id) }) else { throw RuntimeError.bridge("Profile was not created") }
            return try await HostProfileCommands.result(created)
        }
    }

    @MainActor
    static func handleSelectProfile(_ command: ProfileRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("select", host: host, reply: reply, mutation: true) {
            try HostProfileCommands.requireIdle(host)
            let profile = try HostProfileCommands.profile(command.profileId)
            try await StorageRoot.shared.switchTo(profile)
            return try await HostProfileCommands.result(HostProfileCommands.profile(command.profileId))
        }
    }

    @MainActor
    static func handleUpdateProfile(_ command: UpdateProfileRequest, host: any OxHost, reply: OxHostRPC.Reply) {
        HostProfileCommands.perform("update", host: host, reply: reply, mutation: true) {
            try HostProfileCommands.requireIdle(host)
            let storage = StorageRoot.shared
            var profile = try HostProfileCommands.profile(command.profileId)
            guard profile.version == ProfileSchema.current, profile.location == .local else {
                throw RuntimeError.bridge("Select a supported local Profile before updating it")
            }
            guard command.name != nil || command.memory != nil || command.soul != nil else { throw RuntimeError.bridge("No Profile updates supplied") }
            if let name = command.name {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.count <= 100, !storage.nameTaken(name, excluding: profile.id) else { throw RuntimeError.bridge("Invalid or duplicate Profile name") }
            }
            for text in [command.memory, command.soul].compactMap({ $0 }) {
                guard text.utf8.count <= VirtualFileSystem.maximumReadBytes else { throw RuntimeError.bridge("Profile document is too large") }
            }
            if let name = command.name {
                try await storage.rename(profile, to: name)
                profile = try HostProfileCommands.profile(command.profileId)
            }
            let scope = ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
            if let memory = command.memory { try await ProfileRepository.shared.writeTextFile(memory, named: "MEMORY.md", in: scope) }
            if let soul = command.soul { try await ProfileRepository.shared.writeTextFile(soul, named: "SOUL.md", in: scope) }
            if profile.id == storage.activeId {
                Soul.shared.reload()
                UserMemory.shared.reload()
                try await Soul.shared.waitUntilCurrent()
                try await UserMemory.shared.waitUntilCurrent()
            }
            return try await HostProfileCommands.result(profile, contents: true)
        }
    }
}
