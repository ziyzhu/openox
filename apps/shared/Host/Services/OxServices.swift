import Foundation
import JavaScriptCore

nonisolated enum OxServices {
    static let snapshotSchema: JSONValue = .object([
        "type": .string("object"), "properties": .object([
            "domain": .object(["type": .string("string")]), "name": .object(["type": .string("string")]),
            "description": .object(["type": .string("string")]),
            "kind": .object(["type": .string("string"), "enum": .array(["web", "api", "ios", "mcp"].map(JSONValue.string))]),
            "login": .object(["type": .string("string"), "enum": .array(["notRequired", "signedIn", "signedOut", "authorized", "notAuthorized", "unknown"].map(JSONValue.string))]),
            "attached": .object(["type": .string("boolean")]),
            "reloaded": .object(["type": .string("boolean")]), "endpoint": .object(["type": .string("string")]),
            "transport": .object(["type": .string("string")]), "faviconUrl": .object(["type": .array([.string("string"), .string("null")])]),
            "repository": .object(["type": .string("string")]), "repositoryProvenance": .object(["type": .string("string")]),
        ]), "required": .array(["domain", "name", "kind", "login", "attached"].map(JSONValue.string)), "additionalProperties": .bool(false),
    ])

    static let inspectionSchema: JSONValue = .object([
        "type": .string("object"), "properties": .object([
            "service": snapshotSchema,
            "actions": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("object"), "description": .string("Complete action inputSchema and outputSchema with metadata.")])]),
            "standardActions": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Available standard action IDs; their contracts are supplied upfront.")]),
            "nextCursor": .object(["type": .string("string"), "description": .string("Continuation cursor; absent after the last page.")]),
            "auth": .object([
                "type": .string("array"), "minItems": .int(1), "items": WebSessionContract.authMethodSchema,
                "description": .string("Observed web sign-in methods. Pass one item unchanged as login input.auth; absence means unknown, not no authentication support."),
            ]),
            "secrets": .object(["type": .string("array"), "description": .string("Typed saved secrets associated with this service: owned by it or granted to it. Metadata only."), "items": .object([
                "type": .string("object"), "properties": .object([
                    "key": .object(["type": .string("string")]),
                    "displayName": .object(["type": .string("string")]),
                    "serviceID": .object(["type": .array([.string("string"), .string("null")]), "description": .string("Owning service namespace; only this service can read the secret. Null for an unassigned secret.")]),
                    "type": .object(["type": .string("string"), "enum": .array(["account", "apiKey", "token"].map(JSONValue.string))]),
                ]), "required": .array(["key", "displayName", "type"].map(JSONValue.string)), "additionalProperties": .bool(false),
            ])]),
        ]), "required": .array(["service", "standardActions", "actions", "secrets"].map(JSONValue.string)), "additionalProperties": .bool(false),
    ])

    static var inventorySchema: JSONValue {
        var schema = snapshotSchema.objectValue!
        var properties = schema["properties"]!.objectValue!
        properties["manifestPath"] = .object(["type": .string("string")])
        properties["validationError"] = .object(["type": .string("string")])
        schema["properties"] = .object(properties)
        return .object(schema)
    }

    static let sourceSchema: JSONValue = .object([
        "type": .string("object"), "properties": .object([
            "domain": .object(["type": .string("string")]), "manifestPath": .object(["type": .string("string")]),
            "source": .object(["type": .string("string"), "const": .string("local")]),
            "kind": .object(["type": .string("string")]), "reloadRequired": .object(["type": .string("boolean")]),
        ]), "required": .array(["domain", "manifestPath", "source"].map(JSONValue.string)), "additionalProperties": .bool(false),
    ])

    static let function = OxFunction(
        namespace: "service",
        schema: {
            [
                ("ox.service.listAttached", .object([
                    "description": .string(ModelGuidance.text("ox.service.listAttached")),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]),
                    "outputSchema": .object(["type": .string("array"), "items": snapshotSchema]),
                ])),
                ("ox.service.attach", .object([
                    "description": .string(ModelGuidance.text("ox.service.attach")),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["domain": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)])]),
                        "required": .array([.string("domain")]), "additionalProperties": .bool(false),
                    ]),
                    "outputSchema": snapshotSchema,
                ])),
                ("ox.service.detach", .object([
                    "description": .string(ModelGuidance.text("ox.service.detach")),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["domain": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)])]),
                        "required": .array([.string("domain")]), "additionalProperties": .bool(false),
                    ]),
                    "outputSchema": .object([
                        "type": .string("object"),
                        "properties": .object(["domain": .object(["type": .string("string")]), "detached": .object(["type": .string("boolean"), "const": .bool(true)])]),
                        "required": .array([.string("domain"), .string("detached")]), "additionalProperties": .bool(false),
                    ]),
                ])),
                (
                    "ox.service.list",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.list")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array(["web", "api", "ios", "mcp"].map(JSONValue.string)),
                                ]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("array"), "items": inventorySchema]),
                    ])
                ),
                (
                    "ox.service.inspect",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.inspect")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(500),
                                ]),
                                "cursor": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(1500),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": inspectionSchema,
                    ])
                ),
                (
                    "ox.service.validate",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.validate")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(253),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object(["type": .string("string")]),
                                "valid": .object(["type": .string("boolean"), "const": .bool(true)]),
                            ]),
                            "required": .array([.string("domain"), .string("valid")]),
                            "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.service.create",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.create")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "kind": .object(["type": .string("string"), "const": .string("mcp")]),
                                "name": .object(["type": .string("string"), "minLength": .int(1), "description": .string("Explicit service display name chosen from the product name or user request; do not derive it from the endpoint hostname.")]),
                                "endpoint": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048), "description": .string("Public HTTPS MCP endpoint without credentials. Required for MCP; omit domain.")]),
                                "transport": .object(["type": .string("string"), "enum": .array([.string("auto"), .string("streamable-http"), .string("sse")])]),
                                "faviconUrl": .object(["type": .string("string"), "format": .string("uri"), "pattern": .string("^https://"), "maxLength": .int(2048), "description": .string("Optional public HTTPS PNG, JPEG, or ICO URL for this MCP connection.")]),
                            ]),
                            "required": .array([.string("kind"), .string("name"), .string("endpoint")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["anyOf": .array([sourceSchema, snapshotSchema])]),
                    ])
                ),
                (
                    "ox.service.update",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.update")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(253), "description": .string("Existing service domain. Direct MCP also accepts a saved connection name or unique endpoint host.")]),
                                "name": .object(["type": .string("string"), "minLength": .int(1), "description": .string("Local display name for any service kind.")]),
                                "endpoint": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048)]),
                                "transport": .object(["type": .string("string"), "enum": .array([.string("auto"), .string("streamable-http"), .string("sse")])]),
                                "faviconUrl": .object(["type": .array([.string("string"), .string("null")]), "format": .string("uri"), "pattern": .string("^https://"), "maxLength": .int(2048), "description": .string("Public HTTPS PNG, JPEG, or ICO URL for a Local MCP connection; null restores MCP-advertised icons.")]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["anyOf": .array([sourceSchema, snapshotSchema])]),
                    ])
                ),
                (
                    "ox.service.delete",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.delete")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(253),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"), "properties": .object([
                                "domain": .object(["type": .string("string")]), "kind": .object(["type": .string("string")]),
                                "deleted": .object(["type": .string("boolean"), "const": .bool(true)]), "source": .object(["type": .string("string")]),
                                "replacementRepository": .object(["type": .string("string")]), "replacementProvenance": .object(["type": .string("string")]),
                            ]), "required": .array(["domain", "kind", "deleted"].map(JSONValue.string)), "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
            ]
        },
        installNatives: { ctx, env in
            let attachBlock: @convention(block) (String, String) -> JSValue = { domain, purpose in
                env.call { try await $0.attachService(domain: domain, purpose: purpose) }
            }
            ctx.setObject(attachBlock as AnyObject, forKeyedSubscript: "__nativeServiceAttach" as NSString)
            let detachBlock: @convention(block) (String, String) -> JSValue = { domain, purpose in
                env.call { try await $0.detachService(domain: domain, purpose: purpose) }
            }
            ctx.setObject(detachBlock as AnyObject, forKeyedSubscript: "__nativeServiceDetach" as NSString)
            let listAttachedBlock: @convention(block) (String) -> JSValue = { purpose in
                env.call { try await $0.listAttachedServices(purpose: purpose) }
            }
            ctx.setObject(listAttachedBlock as AnyObject, forKeyedSubscript: "__nativeServiceListAttached" as NSString)

            let listBlock: @convention(block) (JSValue, JSValue) -> JSValue = { kindValue, purposeValue in
                let kind = kindValue.isString ? kindValue.toString() : nil
                return env.call { try await $0.listServices(kind: kind, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(listBlock as AnyObject, forKeyedSubscript: "__nativeServiceList" as NSString)

            let inspectBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { domain, cursorValue, purposeValue in
                let cursor = cursorValue.isNull || cursorValue.isUndefined ? nil : cursorValue.toString()
                return env.call { try await $0.inspectService(domain: domain, cursor: cursor, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(inspectBlock as AnyObject, forKeyedSubscript: "__nativeServiceInspect" as NSString)

            let validateBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call { try await $0.validateService(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(validateBlock as AnyObject, forKeyedSubscript: "__nativeServiceValidate" as NSString)

            let createBlock: @convention(block) (JSValue, JSValue) -> JSValue = { optionsValue, purposeValue in
                let fields = jsValueToJSON(optionsValue)?.objectValue ?? [:]
                return env.call(suspendingTimeout: true) { try await $0.createService(kind: fields["kind"]?.stringValue ?? "", domain: fields["domain"]?.stringValue ?? "", name: fields["name"]?.stringValue ?? "", endpoint: fields["endpoint"]?.stringValue, transport: fields["transport"]?.stringValue, faviconURL: fields["faviconUrl"], purpose: purposeValue.toString()!) }
            }
            ctx.setObject(createBlock as AnyObject, forKeyedSubscript: "__nativeServiceCreate" as NSString)

            let updateBlock: @convention(block) (JSValue, JSValue) -> JSValue = { optionsValue, purposeValue in
                var fields = jsValueToJSON(optionsValue)?.objectValue ?? [:]
                let domain = fields.removeValue(forKey: "domain")?.stringValue ?? ""
                fields.removeValue(forKey: "purpose")
                let settings = fields
                return env.call(suspendingTimeout: true) { try await $0.updateService(domain: domain, fields: settings, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(updateBlock as AnyObject, forKeyedSubscript: "__nativeServiceUpdate" as NSString)


            let deleteBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.deleteService(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(deleteBlock as AnyObject, forKeyedSubscript: "__nativeServiceDelete" as NSString)

        },
        jsFragment: """
          attach: (value) => { const options = __oxOptions(value, 'ox.service.attach'); return __nativeServiceAttach(String(options.domain), String(options.purpose)); },
          detach: (value) => { const options = __oxOptions(value, 'ox.service.detach'); return __nativeServiceDetach(String(options.domain), String(options.purpose)); },
          listAttached: (value) => { const options = __oxOptions(value, 'ox.service.listAttached'); return __nativeServiceListAttached(String(options.purpose)); },
          list: (value) => { const options = __oxOptions(value, 'ox.service.list'); return __nativeServiceList(options.kind == null ? null : String(options.kind), String(options.purpose)); },
          inspect: (value) => { const options = __oxOptions(value, 'ox.service.inspect'); return __nativeServiceInspect(String(options.domain), options.cursor ?? null, String(options.purpose)); },
          validate: (value) => { const options = __oxOptions(value, 'ox.service.validate'); return __nativeServiceValidate(String(options.domain), String(options.purpose)); },
          create: (value) => { const options = __oxOptions(value, 'ox.service.create'); return __nativeServiceCreate(options, String(options.purpose)); },
          update: (value) => { const options = __oxOptions(value, 'ox.service.update'); return __nativeServiceUpdate(options, String(options.purpose)); },
          delete: (value) => { const options = __oxOptions(value, 'ox.service.delete'); return __nativeServiceDelete(String(options.domain), String(options.purpose)); }
        """
    )
}
