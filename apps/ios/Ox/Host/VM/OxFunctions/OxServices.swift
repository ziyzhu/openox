import Foundation
import JavaScriptCore

nonisolated enum OxServices {
    static let function = OxFunction(
        namespace: "service",
        schema: {
            [
                (
                    "ox.service.find",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.find")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "query": .object([
                                    "type": .string("string"),
                                    "description": .string("What the user wants to do, in a few words (e.g. \"stream music\", \"order food\")."),
                                ]),
                                "purpose": .object([
                                    "type": .string("string"),
                                    "description": .string("Short (<10 words) description of why you're making this call, shown to the user as the step label."),
                                ]),
                            ]),
                            "required": .array([.string("query")]),
                        ]),
                        "outputSchema": .object([
                            "description": .string("Array of service snapshots, best match first."),
                        ]),
                    ])
                ),
                (
                    "ox.service.list",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.list")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("web"), .string("api"), .string("ios"), .string("mcp")]),
                                ]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "description": .string("Array of available service snapshots with domain, name, description when present, kind, signIn, saved, attached, and repository or MCP connection metadata when applicable."),
                        ]),
                    ])
                ),
                (
                    "ox.service.listAttached",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.listAttached")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("web"), .string("api"), .string("ios"), .string("mcp")]),
                                ]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "description": .string("Array of attached service snapshots."),
                        ]),
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
                                "actions": .object([
                                    "type": .string("array"),
                                    "items": .object([
                                        "type": .string("string"),
                                        "minLength": .int(1),
                                        "maxLength": .int(500),
                                    ]),
                                    "minItems": .int(1),
                                    "maxItems": .int(10),
                                    "uniqueItems": .bool(true),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "description": .string("The attached service snapshot, an action-keyed map of summaries or complete schemas, and supported signIn, botControl, and payment helper contracts. Unsupported helpers are omitted."),
                        ]),
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
                                "kind": .object(["type": .string("string"), "enum": .array([.string("web"), .string("api"), .string("mcp")])]),
                                "domain": .object(["type": .string("string"), "minLength": .int(3), "maxLength": .int(253)]),
                                "endpoint": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048), "description": .string("Public HTTPS MCP endpoint without credentials. Required for MCP; omit domain.")]),
                                "transport": .object(["type": .string("string"), "enum": .array([.string("auto"), .string("streamable-http"), .string("sse")])]),
                            ]),
                            "required": .array([.string("kind")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.update",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.update")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(253)]),
                                "endpoint": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048)]),
                                "transport": .object(["type": .string("string"), "enum": .array([.string("auto"), .string("streamable-http"), .string("sse")])]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.copy",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.copy")),
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
                        "outputSchema": .object(["type": .string("object")]),
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
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.attach",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.attach")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "description": .string("The service's domain, e.g. \"spotify.com\"."),
                                ]),
                                "purpose": .object([
                                    "type": .string("string"),
                                    "description": .string("Short (<10 words) description of why you're making this call, shown to the user as the step label."),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                        ]),
                        "outputSchema": .object([
                            "description": .string("The attached service's snapshot."),
                        ]),
                    ])
                ),
                (
                    "ox.service.detach",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.detach")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "description": .string("The service's domain, e.g. \"spotify.com\"."),
                                ]),
                                "purpose": .object([
                                    "type": .string("string"),
                                    "description": .string("Short (<10 words) description of why you're making this call, shown to the user as the step label."),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                        ]),
                        "outputSchema": .object([
                            "description": .string("The detached service's snapshot."),
                        ]),
                    ])
                ),
                (
                    "ox.service.signIn",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.signIn")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(500),
                                ]),
                                "purpose": .object([
                                    "type": .string("string"),
                                    "maxLength": .int(200),
                                ]),
                            ]),
                            "required": .array([.string("domain")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object(["type": .string("string")]),
                                "signedIn": .object(["type": .string("boolean"), "const": .bool(true)]),
                            ]),
                            "required": .array([.string("domain"), .string("signedIn")]),
                            "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
                (
                    "ox.service.solve",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.solve")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(500),
                                ]),
                                "args": .object(["type": .string("object")]),
                                "purpose": .object([
                                    "type": .string("string"),
                                    "maxLength": .int(200),
                                ]),
                            ]),
                            "required": .array([.string("domain"), .string("args")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("null")]),
                    ])
                ),
                (
                    "ox.service.pay",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.pay")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(1),
                                    "maxLength": .int(500),
                                ]),
                                "args": .object([
                                    "type": .string("object"),
                                    "description": .string("Arguments shared by the service's payment URL and state actions."),
                                ]),
                                "purpose": .object([
                                    "type": .string("string"),
                                    "maxLength": .int(200),
                                ]),
                            ]),
                            "required": .array([.string("domain"), .string("args")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "description": .string("The service's completed payment state, including its reference."),
                        ]),
                    ])
                ),
            ]
        },
        installNatives: { ctx, env in
            let findBlock: @convention(block) (String, JSValue) -> JSValue = { query, purposeValue in
                let purpose = purposeValue.toString()!
                return env.call { try await $0.findServices(query: query, purpose: purpose) }
            }
            ctx.setObject(findBlock as AnyObject, forKeyedSubscript: "__nativeServiceFind" as NSString)

            let listBlock: @convention(block) (JSValue, JSValue) -> JSValue = { kindValue, purposeValue in
                let kind = kindValue.isString ? kindValue.toString() : nil
                return env.call { try await $0.listServices(kind: kind, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(listBlock as AnyObject, forKeyedSubscript: "__nativeServiceList" as NSString)

            let listAttachedBlock: @convention(block) (JSValue, JSValue) -> JSValue = { kindValue, purposeValue in
                let kind = kindValue.isString ? kindValue.toString() : nil
                return env.call { try await $0.listAttachedServices(kind: kind, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(listAttachedBlock as AnyObject, forKeyedSubscript: "__nativeServiceListAttached" as NSString)

            let inspectBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { domain, actionsValue, purposeValue in
                let actions = jsValueToJSON(actionsValue)?.arrayValue?.compactMap(\.stringValue)
                return env.call { try await $0.inspectService(domain: domain, actions: actions, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(inspectBlock as AnyObject, forKeyedSubscript: "__nativeServiceInspect" as NSString)

            let validateBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call { try await $0.validateService(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(validateBlock as AnyObject, forKeyedSubscript: "__nativeServiceValidate" as NSString)

            let createBlock: @convention(block) (JSValue, JSValue) -> JSValue = { optionsValue, purposeValue in
                let fields = jsValueToJSON(optionsValue)?.objectValue ?? [:]
                return env.call(suspendingTimeout: true) { try await $0.createService(kind: fields["kind"]?.stringValue ?? "", domain: fields["domain"]?.stringValue ?? "", endpoint: fields["endpoint"]?.stringValue, transport: fields["transport"]?.stringValue, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(createBlock as AnyObject, forKeyedSubscript: "__nativeServiceCreate" as NSString)

            let updateBlock: @convention(block) (JSValue, JSValue) -> JSValue = { optionsValue, purposeValue in
                let fields = jsValueToJSON(optionsValue)?.objectValue ?? [:]
                return env.call(suspendingTimeout: true) { try await $0.updateService(domain: fields["domain"]?.stringValue ?? "", endpoint: fields["endpoint"]?.stringValue, transport: fields["transport"]?.stringValue, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(updateBlock as AnyObject, forKeyedSubscript: "__nativeServiceUpdate" as NSString)

            let copyBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.copyService(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(copyBlock as AnyObject, forKeyedSubscript: "__nativeServiceCopy" as NSString)

            let deleteBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.deleteService(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(deleteBlock as AnyObject, forKeyedSubscript: "__nativeServiceDelete" as NSString)

            let attachBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                let purpose = purposeValue.toString()!
                return env.call(suspendingTimeout: true) { try await $0.attachService(domain: domain, purpose: purpose) }
            }
            ctx.setObject(attachBlock as AnyObject, forKeyedSubscript: "__nativeServiceAttach" as NSString)

            let detachBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                let purpose = purposeValue.toString()!
                return env.call { try await $0.detachService(domain: domain, purpose: purpose) }
            }
            ctx.setObject(detachBlock as AnyObject, forKeyedSubscript: "__nativeServiceDetach" as NSString)

            let signInBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                let purpose = purposeValue.toString()!
                return env.call(suspendingTimeout: true) { try await $0.signInService(domain: domain, purpose: purpose) }
            }
            ctx.setObject(signInBlock as AnyObject, forKeyedSubscript: "__nativeServiceSignIn" as NSString)

            let solveBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { domain, argsValue, purposeValue in
                let args = jsValueToJSON(argsValue) ?? .object([:])
                let purpose = purposeValue.toString()!
                return env.call(suspendingTimeout: true) {
                    try await $0.solveService(domain: domain, args: args, purpose: purpose)
                }
            }
            ctx.setObject(solveBlock as AnyObject, forKeyedSubscript: "__nativeServiceSolve" as NSString)

            let paymentBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { domain, argsValue, purposeValue in
                let args = jsValueToJSON(argsValue) ?? .object([:])
                let purpose = purposeValue.toString()!
                return env.call(suspendingTimeout: true) {
                    try await $0.payService(domain: domain, args: args, purpose: purpose)
                }
            }
            ctx.setObject(paymentBlock as AnyObject, forKeyedSubscript: "__nativeServicePayment" as NSString)
        },
        jsFragment: """
          find: (value) => { const options = __oxOptions(value, 'ox.service.find'); return __nativeServiceFind(String(options.query), String(options.purpose)); },
          list: (value) => { const options = __oxOptions(value, 'ox.service.list'); return __nativeServiceList(options.kind == null ? null : String(options.kind), String(options.purpose)); },
          listAttached: (value) => { const options = __oxOptions(value, 'ox.service.listAttached'); return __nativeServiceListAttached(options.kind == null ? null : String(options.kind), String(options.purpose)); },
          inspect: (value) => { const options = __oxOptions(value, 'ox.service.inspect'); return __nativeServiceInspect(String(options.domain), options.actions ?? null, String(options.purpose)); },
          validate: (value) => { const options = __oxOptions(value, 'ox.service.validate'); return __nativeServiceValidate(String(options.domain), String(options.purpose)); },
          create: (value) => { const options = __oxOptions(value, 'ox.service.create'); return __nativeServiceCreate(options, String(options.purpose)); },
          update: (value) => { const options = __oxOptions(value, 'ox.service.update'); return __nativeServiceUpdate(options, String(options.purpose)); },
          copy: (value) => { const options = __oxOptions(value, 'ox.service.copy'); return __nativeServiceCopy(String(options.domain), String(options.purpose)); },
          delete: (value) => { const options = __oxOptions(value, 'ox.service.delete'); return __nativeServiceDelete(String(options.domain), String(options.purpose)); },
          attach: (value) => { const options = __oxOptions(value, 'ox.service.attach'); return __nativeServiceAttach(String(options.domain), String(options.purpose)); },
          detach: (value) => { const options = __oxOptions(value, 'ox.service.detach'); return __nativeServiceDetach(String(options.domain), String(options.purpose)); },
          signIn: (value) => { const options = __oxOptions(value, 'ox.service.signIn'); return __nativeServiceSignIn(String(options.domain), String(options.purpose)); },
          solve: (value) => { const options = __oxOptions(value, 'ox.service.solve'); return __nativeServiceSolve(String(options.domain), options.args, String(options.purpose)); },
          pay: (value) => { const options = __oxOptions(value, 'ox.service.pay'); return __nativeServicePayment(String(options.domain), options.args, String(options.purpose)); }
        """
    )
}
