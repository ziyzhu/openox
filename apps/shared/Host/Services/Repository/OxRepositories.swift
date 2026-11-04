import Foundation
import JavaScriptCore

nonisolated enum OxRepositories {
    static let function = OxFunction(
        namespace: "repository",
        schema: {
            [
                (
                    "ox.repository.list",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.list")),
                        "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
                        "outputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "status": .object(["type": .string("string"), "enum": .array(["idle", "syncing", "ready", "failed"].map(JSONValue.string))]),
                                "repositories": .object([
                                    "type": .string("array"),
                                    "maxItems": .int(50),
                                    "items": .object([
                                        "type": .string("object"),
                                        "properties": .object([
                                            "id": .object(["type": .string("string")]),
                                            "path": .object(["type": .string("string")]),
                                            "name": .object(["type": .string("string")]),
                                            "provenance": .object(["type": .string("string"), "enum": .array(["bundled", "local", "development", "remote", "mounted"].map(JSONValue.string))]),
                                            "enabled": .object(["type": .string("boolean")]),
                                            "state": .object(["type": .string("string"), "enum": .array(["ready", "failed"].map(JSONValue.string))]),
                                            "serviceCount": .object(["type": .string("integer"), "minimum": .int(0)]),
                                            "skillCount": .object(["type": .string("integer"), "minimum": .int(0)]),
                                        ]),
                                        "required": .array(["id", "path", "name", "provenance", "enabled", "state", "serviceCount", "skillCount"].map(JSONValue.string)),
                                        "additionalProperties": .bool(false),
                                    ]),
                                ]),
                                "truncated": .object(["type": .string("boolean")]),
                            ]),
                            "required": .array(["status", "repositories", "truncated"].map(JSONValue.string)),
                            "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.repository.conflicts",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.conflicts")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "service": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                                "compare": .object(["type": .string("boolean")]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"), "properties": .object([
                                "conflicts": .object(["type": .string("array"), "items": .object([
                                    "type": .string("object"), "properties": .object([
                                        "service": .object(["type": .string("string")]),
                                        "selectedRepository": .object(["type": .array([.string("string"), .string("null")])]),
                                        "candidates": .object(["type": .string("array"), "items": .object([
                                            "type": .string("object"), "properties": .object(["repository": .object(["type": .string("string")]), "name": .object(["type": .string("string")]), "path": .object(["type": .string("string")])]),
                                            "required": .array(["repository", "name", "path"].map(JSONValue.string)), "additionalProperties": .bool(false),
                                        ])]),
                                    ]), "required": .array(["service", "selectedRepository", "candidates"].map(JSONValue.string)), "additionalProperties": .bool(false),
                                ])]),
                                "truncated": .object(["type": .string("boolean")]),
                                "comparison": .object([
                                    "type": .string("object"), "properties": .object([
                                        "identical": .object(["type": .string("boolean")]),
                                        "candidates": .object(["type": .string("array"), "items": .object([
                                            "type": .string("object"), "properties": .object([
                                                "repository": .object(["type": .string("string")]),
                                                "files": .object(["type": .string("array"), "items": .object([
                                                    "type": .string("object"), "properties": .object(["path": .object(["type": .string("string")]), "bytes": .object(["type": .string("integer")]), "sha256": .object(["type": .string("string")])]),
                                                    "required": .array(["path", "bytes", "sha256"].map(JSONValue.string)), "additionalProperties": .bool(false),
                                                ])]),
                                            ]), "required": .array(["repository", "files"].map(JSONValue.string)), "additionalProperties": .bool(false),
                                        ])]),
                                    ]), "required": .array(["identical", "candidates"].map(JSONValue.string)), "additionalProperties": .bool(false),
                                ]),
                            ]), "required": .array(["conflicts", "truncated"].map(JSONValue.string)), "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.repository.resolve",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.resolve")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "service": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                            ]),
                            "required": .array([.string("service"), .string("repository")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"), "properties": .object([
                                "service": .object(["type": .string("string")]), "selectedRepository": .object(["type": .string("string")]), "reloadRequired": .object(["type": .string("boolean")]),
                            ]), "required": .array(["service", "selectedRepository", "reloadRequired"].map(JSONValue.string)), "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.repository.connect",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.connect")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "origin": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048)]),
                            ]),
                            "required": .array([.string("origin")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"), "properties": .object([
                                "id": .object(["type": .string("string")]), "name": .object(["type": .string("string")]), "origin": .object(["type": .string("string")]),
                                "serviceCount": .object(["type": .string("integer")]), "skillCount": .object(["type": .string("integer")]), "connected": .object(["type": .string("boolean"), "const": .bool(true)]),
                            ]), "required": .array(["id", "name", "origin", "serviceCount", "skillCount", "connected"].map(JSONValue.string)), "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.repository.sync",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.sync")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                            ]),
                            "required": .array([.string("repository")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"), "properties": .object([
                                "id": .object(["type": .string("string")]), "name": .object(["type": .string("string")]),
                                "serviceCount": .object(["type": .string("integer")]), "skillCount": .object(["type": .string("integer")]), "synced": .object(["type": .string("boolean"), "const": .bool(true)]),
                            ]), "required": .array(["id", "name", "serviceCount", "skillCount", "synced"].map(JSONValue.string)), "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.repository.enable",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.enable")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                                "enabled": .object(["type": .string("boolean")]),
                            ]),
                            "required": .array([.string("repository"), .string("enabled")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "id": .object(["type": .string("string")]),
                                "enabled": .object(["type": .string("boolean")]),
                                "changed": .object(["type": .string("boolean")]),
                                "serviceCount": .object(["type": .string("integer"), "minimum": .int(0)]),
                                "skillCount": .object(["type": .string("integer"), "minimum": .int(0)]),
                            ]),
                            "required": .array(["id", "enabled", "changed", "serviceCount", "skillCount"].map(JSONValue.string)),
                            "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.repository.disconnect",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.disconnect")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                            ]),
                            "required": .array([.string("repository")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"), "properties": .object(["id": .object(["type": .string("string")]), "disconnected": .object(["type": .string("boolean"), "const": .bool(true)])]),
                            "required": .array(["id", "disconnected"].map(JSONValue.string)), "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
            ]
        },
        installNatives: { ctx, env in
            let list: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.appRepositories(purpose: purpose) }
            }
            ctx.setObject(list, forKeyedSubscript: "__nativeRepositoryList" as NSString)
            let conflictsBlock: @convention(block) (JSValue, Bool, JSValue) -> JSValue = { serviceValue, compare, purposeValue in
                let service = serviceValue.isString ? serviceValue.toString() : nil
                return env.call { try await $0.repositoryConflicts(service: service, compare: compare, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(conflictsBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryConflicts" as NSString)

            let resolveBlock: @convention(block) (String, String, JSValue) -> JSValue = { service, repository, purposeValue in
                env.call(suspendingTimeout: true) {
                    try await $0.resolveRepositoryConflict(service: service, repository: repository, purpose: purposeValue.toString()!)
                }
            }
            ctx.setObject(resolveBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryResolve" as NSString)

            let connectRepositoryBlock: @convention(block) (String, JSValue) -> JSValue = { origin, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.connectRepository(origin: origin, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(connectRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryConnect" as NSString)

            let syncRepositoryBlock: @convention(block) (String, JSValue) -> JSValue = { repository, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.syncRepository(repository: repository, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(syncRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositorySync" as NSString)

            let enableRepositoryBlock: @convention(block) (String, Bool, String) -> JSValue = { repository, enabled, purpose in
                env.call(suspendingTimeout: true) {
                    try await $0.enableRepository(repository: repository, enabled: enabled, purpose: purpose)
                }
            }
            ctx.setObject(enableRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryEnable" as NSString)

            let disconnectRepositoryBlock: @convention(block) (String, JSValue) -> JSValue = { repository, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.disconnectRepository(repository: repository, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(disconnectRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryDisconnect" as NSString)

        },
        jsFragment: """
          list: value => { const options = __oxOptions(value, 'ox.repository.list'); return __nativeRepositoryList(String(options.purpose)); },
            conflicts: (value) => { const options = __oxOptions(value, 'ox.repository.conflicts'); return __nativeRepositoryConflicts(options.service ?? null, options.compare ?? false, String(options.purpose)); },
            resolve: (value) => { const options = __oxOptions(value, 'ox.repository.resolve'); return __nativeRepositoryResolve(String(options.service), String(options.repository), String(options.purpose)); },
            connect: (value) => { const options = __oxOptions(value, 'ox.repository.connect'); return __nativeRepositoryConnect(String(options.origin), String(options.purpose)); },
            sync: (value) => { const options = __oxOptions(value, 'ox.repository.sync'); return __nativeRepositorySync(String(options.repository), String(options.purpose)); },
            enable: (value) => { const options = __oxOptions(value, 'ox.repository.enable'); return __nativeRepositoryEnable(String(options.repository), options.enabled, String(options.purpose)); },
            disconnect: (value) => { const options = __oxOptions(value, 'ox.repository.disconnect'); return __nativeRepositoryDisconnect(String(options.repository), String(options.purpose)); },
        """
    )
}
