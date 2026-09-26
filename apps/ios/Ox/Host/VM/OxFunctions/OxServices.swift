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
                        "description": .string("Search the merged service MonoRepository with the same service search used by the app when no attached service covers the task: `await ox.service.find({ query, purpose })`. Returns up to ten ranked matches (domain, kind, manifestPath, repository, repositoryProvenance, name, description, matchedAction, signIn, saved, attached). Read a strong candidate's `manifestPath` when its action contract matters, then bring the best match in with `ox.service.attach({ domain, purpose })`. `purpose` is a short (<10 words) human-readable description shown to the user as the step label."),
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
                        "description": .string("List all available services from enabled repositories and saved MCP connections, sorted by domain: `await ox.service.list({ kind?, purpose })`. Filter by `kind: \"web\"` for website services hosted by Ox Server, `kind: \"ios\"` for client-owned device services, or `kind: \"mcp\"` for directly connected remote MCP servers. Every result includes its kind and current chat attachment state. Returns every service without a result limit; omits action contracts. Disabled repositories are excluded."),
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
                        "description": .string("List the services currently attached to this chat: `await ox.service.listAttached({ kind?, purpose })`. Filter by `kind: \"web\"` for website services hosted by Ox Server, `kind: \"ios\"` for client-owned device services, or `kind: \"mcp\"` for directly connected remote MCP servers. Every result includes its kind."),
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
                        "description": .string("Inspect one attached service: `await ox.service.inspect({ domain, actions?, purpose })`. Omit `actions` for a compact index of exposed actions plus the complete `payment` contract when checkout is supported. Pass up to ten action IDs to receive their complete, self-contained input and output schemas."),
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
                            "description": .string("The attached service snapshot and an action-keyed map of summaries or complete schemas."),
                        ]),
                    ])
                ),
                (
                    "ox.service.validate",
                    .object([
                        "description": .string("Validate a complete Local web or API service draft: `await ox.service.validate({ domain, purpose })`. Checks the manifest, action installer and matching action IDs, declared skills, required files, and service size limits together. Returns `{ domain, valid: true }` or throws with the validation error. Does not edit, attach, reload, Save, or invoke service actions. Finish related source edits before calling; individual file writes do not validate service contents."),
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
                        "description": .string("Create a Local API service with kind api and a stable domain identifier, a Local web service with `{ kind: \"web\", domain, purpose }`, or save a remote MCP connection with `{ kind: \"mcp\", endpoint, transport?, purpose }`. MCP discovers tools and may request user sign-in before saving; it returns the assigned domain for inspect/attach/invoke/delete. An existing endpoint is reused; use update to change its transport or refresh tools. MCP connections save immediately, have read-only manifests, and do not use Local Git. Never put credentials in the endpoint; use sign-in. This connects to a server, not hosts one."),
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
                        "description": .string("Update a directly connected MCP service: `await ox.service.update({ domain, endpoint?, transport?, purpose })`. With no settings, reconnects and refreshes tools. Omitted settings are preserved; transport auto enables detection. Validates before replacing and saves immediately. A failed connection leaves the previous service intact. A changed endpoint gets a new domain, clears old local authorization, and must be attached separately; it never inherits old tool approvals. Repository MCP definitions are read-only. For Local web services, edit source with ox.fs instead."),
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
                        "description": .string("Copy the selected Bundled, Development, or Remote service into the editable Local repository and select that candidate: `await ox.service.copy({ domain, purpose })`. Edit its expanded source under `services/` with `ox.fs`."),
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
                        "description": .string("Delete a Local web service or remove a saved MCP connection: `await ox.service.delete({ domain, purpose })`. The user approves deletion. For web services, source deletion becomes an uncommitted Local Git change and another repository candidate may become active. MCP removal is immediate, detaches it from this chat, clears local authorization and tool approvals, and does not revoke access at the server or delete a repository definition."),
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
                        "description": .string("Attach an Ox Server service by domain after inspecting its `services/<kind>/<id>/service.json`: `await ox.service.attach({ domain, purpose })`. The first call saves and attaches the service to this chat; a later call reloads that chat's attachment from the current service source so a coherent set of Local edits can be tested. Source writes do not reload running attachments. The user is asked to approve the first attach only — if they decline, this throws, so surface that and don't retry blindly. Returns the service snapshot with `reloaded` indicating whether an existing attachment was replaced; a `requireAuth` action revalidates before use. `purpose` is a short (<10 words) human-readable description shown to the user as the step label."),
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
                        "description": .string("Detach a service (by domain) from this chat: `await ox.service.detach({ domain, purpose })`. Removes it from the chat's attachment bar so its actions stop being available; the service stays saved. Use when the user is done with it or you attached the wrong one. Returns the service snapshot (`attached: false`). `purpose` is a short (<10 words) human-readable description shown to the user as the step label."),
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
                        "description": .string("Ask the user to sign in to an attached service and wait for completion: `await ox.service.signIn({ domain, purpose })`. Returns `{ domain, signedIn: true }` after successful sign-in so dependent JavaScript can continue. Throws when the user cancels, sign-in fails, or the service does not expose authentication."),
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
                        "description": .string("Ask the user to complete a service's human verification and wait for completion: `await ox.service.solve({ domain, args, purpose })`. Pass the operation arguments requested by the service. Resolves after successful verification so dependent JavaScript can continue. Throws when the user cancels or verification fails. Never ask for challenge answers or tokens."),
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
                        "description": .string("Hand final commitment to the user through an attached service's checkout: `await ox.service.pay({ domain, args, purpose })`. Prepare and price the pending cart, booking, or order first with the service's exposed actions. Pass the payment arguments required by that service. The user reviews and completes the payment on the service page; this function never commits payment itself. Resolves with the completed payment state and reference, and throws on cancellation, failure, or unsupported services."),
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
