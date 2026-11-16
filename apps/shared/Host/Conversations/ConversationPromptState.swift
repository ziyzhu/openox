import Foundation

nonisolated struct RenderedConversationPrompt: Decodable, Sendable {
    let scaffold: String
    let memory: String
    let rendered: String
}

nonisolated enum ConversationPromptState {
    static func system(memory: String, hostID: String, profileID: String) -> JSONValue {
        .object(["memory": .string(memory), "hostContext": hostContext(hostID: hostID, profileID: profileID)])
    }

    private static func hostContext(hostID: String, profileID: String) -> JSONValue {
        let scope: [String: JSONValue] = ["hostID": .string(hostID), "profileID": .string(profileID)]
        var host = scope
        host["functions"] = .array((OxFunctionCatalog.build().objectValue ?? [:]).keys.sorted().map(JSONValue.string))
        host["serviceKinds"] = .array(["web", "api", "ios", "mcp"].map(JSONValue.string))
        host["presentation"] = .string("conversation-bubbles")
        host["externalFiles"] = .bool(true)
        return .object(["active": .object(scope), "hosts": .array([.object(host)])])
    }

    static func turn(
        skills: [Skill],
        skillConflicts: [String],
        services: [Service.Snapshot],
        fileRoots: [String],
        grantedFolders: [DeviceFolderStore.Grant],
        filePaths: [String],
        isTemporary: Bool,
        responseLanguage: JSONValue,
        hostID: String,
        profileID: String
    ) -> JSONValue {
        .object([
            "skills": .array(skills.map { .object(["name": .string($0.name), "description": .string($0.description)]) }),
            "skillConflicts": .array(skillConflicts.map(JSONValue.string)),
            "services": .array(services.map { service in
                var fields: [String: JSONValue] = ["domain": .string(service.domain)]
                if let description = service.description { fields["description"] = .string(description) }
                return .object(fields)
            }),
            "hostContext": hostContext(hostID: hostID, profileID: profileID),
            "filePaths": .array(filePaths.map(JSONValue.string)),
            "fileRoots": .array(fileRoots.map(JSONValue.string)),
            "grantedFolders": .array(grantedFolders.map { .object(["path": .string("mounts/\($0.id)"), "name": .string($0.name)]) }),
            "storageMode": .string(isTemporary ? "temporary" : "persisted"),
            "responseLanguage": responseLanguage,
        ])
    }

}
