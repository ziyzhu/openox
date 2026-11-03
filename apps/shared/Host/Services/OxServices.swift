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
                            "description": .string("Array of available service snapshots with domain, name, description when present, kind, login, saved, attached, and repository or MCP connection metadata when applicable."),
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
                            "description": .string("The attached service snapshot, an action-keyed map of summaries or complete schemas, and applicable access helper contracts."),
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
                                "faviconUrl": .object(["type": .string("string"), "format": .string("uri"), "pattern": .string("^https://"), "maxLength": .int(2048), "description": .string("Optional public HTTPS PNG, JPEG, or ICO URL for this MCP connection.")]),
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
                                "domain": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(253), "description": .string("Existing service domain. Direct MCP also accepts a saved connection name or unique endpoint host.")]),
                                "name": .object(["type": .string("string"), "minLength": .int(1), "description": .string("Local display name for any service kind.")]),
                                "description": .object(["type": .array([.string("string"), .string("null")]), "description": .string("Local web/API description; null removes it.")]),
                                "baseUrl": .object(["type": .string("string"), "format": .string("uri"), "description": .string("Local web execution URL or API HTTPS base URL. Web URLs must remain on the service domain or its subdomains.")]),
                                "actions": .object(["type": .string("array"), "items": .object(["type": .string("object")]), "description": .string("Replace the complete Local web/API action declarations. Handlers remain in actions.js; edit them with ox.fs and validate before attaching.")]),
                                "$defs": .object(["type": .array([.string("object"), .string("null")]), "description": .string("Replace Local web/API shared JSON Schema definitions; null removes them.")]),
                                "auth": .object(["type": .string("object"), "description": .string("Replace Local API authentication configuration, never credentials. Supported objects: {type: 'none'}; {type: 'apiKey', in: 'header'|'query', name: '<header-or-query-name>'}; {type: 'http', scheme: 'basic'|'bearer'}; or {type: 'oauth2', flow: 'authorizationCode', authorizationURL: '<HTTPS URL>', tokenURL: '<HTTPS URL>', clientID: '<registered public client>', redirectURI: '<app callback URI>', scopes: ['<scope>'], pkce: 'S256'}. OAuth endpoints cannot contain credentials, query, or fragment; callback uses a non-HTTP app scheme without query or fragment. Requires setup again.")]),
                                "endpoint": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048)]),
                                "transport": .object(["type": .string("string"), "enum": .array([.string("auto"), .string("streamable-http"), .string("sse")])]),
                                "faviconUrl": .object(["type": .array([.string("string"), .string("null")]), "format": .string("uri"), "pattern": .string("^https://"), "maxLength": .int(2048), "description": .string("Public HTTPS PNG, JPEG, or ICO URL. Local web/API and direct MCP support this field; null removes a Local override or restores MCP-advertised icons.")]),
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
                    "ox.service.showPage",
                    .object([
                        "description": .string(ModelGuidance.text("ox.service.showPage")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object(["type": .string("string"), "description": .string("The same qualified web action name used for the page's invocation.")]),
                                "input": .object(["type": .string("object"), "description": .string("The same action input, used only to select its execution page.")]),
                                "session": WebSessionContract.sessionSchema,
                                "pageUrl": .object(["type": .string("string")]),
                                "purpose": .object(["type": .string("string")]),
                            ]),
                            "required": .array([.string("name")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object([
                            "type": .string("object"),
                            "properties": .object(["shown": .object(["type": .string("boolean")])]),
                            "required": .array([.string("shown")]),
                            "additionalProperties": .bool(false),
                        ]),
                    ])
                ),
            ] + ["ox.service.checkAccess", "ox.service.requestAccess"].map { name in
                var properties: [String: JSONValue] = [
                    "domain": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                    "purpose": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(80)]),
                    "pageUrl": .object(["type": .string("string"), "description": .string("Website-only discovery or login target within the service domain.")]),
                ]
                if name == "ox.service.requestAccess" { properties["input"] = .object(["type": .string("object")]) }
                return (name, .object([
                    "description": .string(ModelGuidance.text(name)),
                    "inputSchema": .object([
                        "type": .string("object"), "properties": .object(properties),
                        "required": .array([.string("purpose"), .string("domain")]),
                        "additionalProperties": .bool(false),
                    ]),
                    "outputSchema": .object(["oneOf": .array(["web", "api", "mcp", "ios"].map { kind in
                        name == "ox.service.checkAccess" ? OxActions.checkAccessOutput(kind: kind) : OxActions.requestAccessOutput(kind: kind)
                    })]),
                ]))
            }
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
                return env.call(suspendingTimeout: true) { try await $0.createService(kind: fields["kind"]?.stringValue ?? "", domain: fields["domain"]?.stringValue ?? "", endpoint: fields["endpoint"]?.stringValue, transport: fields["transport"]?.stringValue, faviconURL: fields["faviconUrl"], purpose: purposeValue.toString()!) }
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

            let showPageBlock: @convention(block) (String, JSValue, JSValue, JSValue, JSValue) -> JSValue = { name, argsValue, sessionValue, pageURLValue, purposeValue in
                let args = argsValue.isNull || argsValue.isUndefined ? nil : jsValueToJSON(argsValue)
                let purpose = purposeValue.toString()!
                let session = sessionValue.isNull || sessionValue.isUndefined ? nil : jsValueToJSON(sessionValue)
                let pageURL = pageURLValue.isNull || pageURLValue.isUndefined ? nil : pageURLValue.toString()
                return env.call(suspendingTimeout: true) { try await $0.showServicePage(name: name, args: args, session: session, pageURL: pageURL, purpose: purpose) }
            }
            ctx.setObject(showPageBlock as AnyObject, forKeyedSubscript: "__nativeServiceShowPage" as NSString)

            let checkAccessBlock: @convention(block) (String, JSValue, JSValue) -> JSValue = { domain, pageURLValue, purposeValue in
                let pageURL = pageURLValue.isNull || pageURLValue.isUndefined ? nil : pageURLValue.toString()
                return env.call { try await $0.checkServiceAccess(domain: domain, pageURL: pageURL, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(checkAccessBlock as AnyObject, forKeyedSubscript: "__nativeServiceCheckAccess" as NSString)

            let requestAccessBlock: @convention(block) (String, JSValue, JSValue, JSValue) -> JSValue = { domain, inputValue, pageURLValue, purposeValue in
                let input = inputValue.isNull || inputValue.isUndefined ? nil : jsValueToJSON(inputValue)
                let pageURL = pageURLValue.isNull || pageURLValue.isUndefined ? nil : pageURLValue.toString()
                return env.call(suspendingTimeout: true) { try await $0.requestServiceAccess(domain: domain, input: input, pageURL: pageURL, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(requestAccessBlock as AnyObject, forKeyedSubscript: "__nativeServiceRequestAccess" as NSString)

            let loginBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                let purpose = purposeValue.toString()!
                return env.call(suspendingTimeout: true) { try await $0.loginService(domain: domain, purpose: purpose) }
            }
            ctx.setObject(loginBlock as AnyObject, forKeyedSubscript: "__nativeServiceLogin" as NSString)
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
          showPage: (value) => { const options = __oxOptions(value, 'ox.service.showPage'); return __nativeServiceShowPage(String(options.name), options.input ?? null, options.session ?? null, options.pageUrl ?? null, String(options.purpose)); },
          checkAccess: (value) => { const options = __oxOptions(value, 'ox.service.checkAccess'); return __nativeServiceCheckAccess(String(options.domain), options.pageUrl ?? null, String(options.purpose)); },
          requestAccess: (value) => { const options = __oxOptions(value, 'ox.service.requestAccess'); return __nativeServiceRequestAccess(String(options.domain), options.input ?? null, options.pageUrl ?? null, String(options.purpose)); },
          login: (value) => { const options = __oxOptions(value, 'ox.service.requestAccess'); if ('input' in options || 'pageUrl' in options) throw Object.assign(new TypeError('Use ox.service.requestAccess for website routing.'), { code: 'invalid_argument', recovery: 'Inspect the applicable access contract before requesting setup.' }); return __nativeServiceLogin(String(options.domain), String(options.purpose)); }
        """
    )
}
