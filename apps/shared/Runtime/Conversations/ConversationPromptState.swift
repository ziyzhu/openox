import Foundation

nonisolated struct RenderedConversationPrompt: Decodable, Sendable {
    let scaffold: String
    let memory: String
    let rendered: String
}

nonisolated enum ConversationPromptState {
    static func system(memory: String, deviceID: String, profileID: String) -> JSONValue {
        .object(["memory": .string(memory), "deviceContext": deviceContext(deviceID: deviceID, profileID: profileID)])
    }

    private static func deviceContext(deviceID: String, profileID: String) -> JSONValue {
        let scope: [String: JSONValue] = ["deviceID": .string(deviceID), "profileID": .string(profileID)]
        var device = scope
        device["functions"] = .array((OxFunctionCatalog.build().objectValue ?? [:]).keys.sorted().map(JSONValue.string))
        device["serviceKinds"] = .array(["web", "api", "ios", "mcp"].map(JSONValue.string))
        device["presentation"] = .string("conversation-bubbles")
        device["externalFiles"] = .bool(true)
        return .object(["active": .object(scope), "devices": .array([.object(device)])])
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
        children: [ChildConversationSnapshot],
        deviceID: String,
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
            "deviceContext": deviceContext(deviceID: deviceID, profileID: profileID),
            "filePaths": .array(filePaths.map(JSONValue.string)),
            "fileRoots": .array(fileRoots.map(JSONValue.string)),
            "grantedFolders": .array(grantedFolders.map { .object(["path": .string("mounts/\($0.id)"), "name": .string($0.name)]) }),
            "storageMode": .string(isTemporary ? "temporary" : "persisted"),
            "responseLanguage": responseLanguage,
            "children": .array(children.map(\.value)),
        ])
    }

}
