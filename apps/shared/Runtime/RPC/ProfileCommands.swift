import Foundation

@MainActor
enum ProfileCommands {
    private(set) static var operation: String?

    static func perform(
        _ name: String, runtime: any ProfileRuntime, reply: ProfileRPC.Reply,
        mutation: Bool = false, body: @escaping @MainActor () async throws -> JSONValue
    ) {
        guard operation == nil, !StorageRoot.shared.isBusy else {
            reply.failure("A Profile operation is in progress; retry after it completes")
            return
        }
        if mutation { operation = name }
        Task {
            defer { if mutation { operation = nil } }
            do {
                try await runtime.prepare()
                let result = try await body()
                Log.app.info("ProfileAdministration completed operation=\(name)")
                reply.success(result)
            } catch {
                Log.app.error("ProfileAdministration failed operation=\(name) error=\(error.localizedDescription)")
                reply.failure(error.localizedDescription)
            }
        }
    }

    static func profile(_ id: String) throws -> Profile {
        guard let uuid = UUID(uuidString: id), uuid == StorageRoot.shared.activeId,
              let profile = StorageRoot.shared.active else {
            throw RuntimeError.bridge("Only the Profile this connection opened is available: \(id)")
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
            guard profile.version == ProfileSchema.current else {
                throw RuntimeError.bridge("Select a supported local Profile before reading or updating its contents")
            }
            let scope = ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
            result["memory"] = .string(try await ProfileRepository.shared.readTextFile(named: "MEMORY.md", in: scope) ?? "")
            result["soul"] = .string("")
        }
        return .object(result)
    }

    static func requireIdle(_ runtime: any ProfileRuntime) throws {
        guard !runtime.conversations.activities.values.contains(where: {
            if case .running = $0 { return true }
            return false
        }) else { throw RuntimeError.bridge("Stop running conversations before updating the Profile") }
    }
}

extension ProfileProtocol {
    @MainActor
    static func handleInspectProfile(_ command: ProfileRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("inspect", runtime: runtime, reply: reply) {
            try await ProfileCommands.result(ProfileCommands.profile(command.profileId), contents: true)
        }
    }

    @MainActor
    static func handleUpdateProfile(_ command: UpdateProfileRequest, runtime: any ProfileRuntime, reply: ProfileRPC.Reply) {
        ProfileCommands.perform("update", runtime: runtime, reply: reply, mutation: true) {
            try ProfileCommands.requireIdle(runtime)
            let storage = StorageRoot.shared
            var profile = try ProfileCommands.profile(command.profileId)
            guard profile.version == ProfileSchema.current else {
                throw RuntimeError.bridge("Select a supported local Profile before updating it")
            }
            guard command.soul == nil else { throw RuntimeError.bridge("Voice preferences now live in MEMORY.md. Update memory instead.") }
            guard command.name != nil || command.memory != nil else { throw RuntimeError.bridge("No Profile updates supplied") }
            if let name = command.name {
                guard profile.location != .external else { throw RuntimeError.bridge("Rename this Profile folder in Files, then open it again.") }
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.count <= 100, !storage.nameTaken(name, excluding: profile.id) else { throw RuntimeError.bridge("Invalid or duplicate Profile name") }
            }
            if let memory = command.memory {
                guard memory.utf8.count <= 512 * 1024 else { throw RuntimeError.bridge("Profile document is too large") }
            }
            if let name = command.name {
                try await storage.rename(profile, to: name)
                profile = try ProfileCommands.profile(command.profileId)
            }
            let scope = ProfileScope(profileID: profile.id, root: profile.url, location: profile.location)
            if let memory = command.memory { try await ProfileRepository.shared.writeTextFile(memory, named: "MEMORY.md", in: scope) }
            if profile.id == storage.activeId {
                UserMemory.shared.reload()
                try await UserMemory.shared.waitUntilCurrent()
            }
            return try await ProfileCommands.result(profile, contents: true)
        }
    }
}
