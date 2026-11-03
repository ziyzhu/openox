import Foundation
import JavaScriptCore

nonisolated enum OxSearch {
    static let resultSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "service": .object(["type": .string("string")]),
            "items": .object([
                "type": .string("array"),
                "maxItems": .int(50),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string"), "minLength": .int(1)]),
                        "url": .object(["type": .array([.string("string"), .string("null")])]),
                        "snippet": .object(["type": .array([.string("string"), .string("null")])]),
                        "id": .object(["type": .string("string")]),
                        "data": .object(["type": .string("object")]),
                    ]),
                    "required": .array(["title", "url", "snippet"].map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]),
            "nextCursor": .object(["type": .array([.string("string"), .string("null")])]),
            "scope": .object(["type": .string("string"), "minLength": .int(1)]),
            "coverage": .object(["type": .string("string"), "enum": .array(["complete", "partial", "unknown"].map(JSONValue.string))]),
        ]),
        "required": .array(["service", "items", "nextCursor", "scope", "coverage"].map(JSONValue.string)),
        "additionalProperties": .bool(false),
    ])

    static let function = OxFunction(
        namespace: "web",
        schema: {
            [("ox.web.search", .object([
                "description": .string(ModelGuidance.text("ox.web.search")),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(1000)]),
                        "services": .object([
                            "type": .string("array"), "minItems": .int(1), "maxItems": .int(4), "uniqueItems": .bool(true),
                            "items": .object(["type": .string("string"), "pattern": .string("^web:[a-z0-9.-]+$")]),
                        ]),
                        "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(50), "default": .int(10)]),
                        "cursors": .object(["type": .string("object"), "additionalProperties": .object(["type": .string("string"), "minLength": .int(1)])]),
                        "sessions": .object(["type": .string("object"), "additionalProperties": WebSessionContract.sessionSchema]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                "outputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")]),
                        "results": .object(["type": .string("array"), "items": resultSchema]),
                        "errors": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object(Dictionary(uniqueKeysWithValues: ["service", "code", "message", "recovery"].map { ($0, JSONValue.object(["type": .string("string")])) })),
                                "required": .array(["service", "code", "message", "recovery"].map(JSONValue.string)),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                    ]),
                    "required": .array(["query", "results", "errors"].map(JSONValue.string)),
                    "additionalProperties": .bool(false),
                ]),
            ]))]
        },
        installNatives: { context, environment in
            let authorize: @convention(block) (JSValue) -> JSValue = { value in
                let arguments = jsValueToJSON(value) ?? .object([:])
                let purpose = arguments.objectValue?["purpose"]?.stringValue ?? ""
                return environment.call(suspendingTimeout: true) {
                    try await $0.authorizeSearch(arguments: arguments, purpose: purpose)
                }
            }
            context.setObject(authorize as AnyObject, forKeyedSubscript: "__nativeSearchApproval" as NSString)
        },
        jsFragment: #"""
          search: async (value) => {
            const options = __oxOptions(value, 'ox.web.search');
            const services = options.services ?? ['web:search.brave.com', 'web:duckduckgo.com', 'web:google.com'];
            const fail = (code, message, recovery = 'Inspect the service search contract before retrying.') => Object.assign(new Error(message), {code, recovery});
            if (!options.query.trim()) throw fail('invalid_argument', 'Search query must not be blank.');
            if (services.some(service => !/^web:[a-z0-9.-]+$/.test(service))) throw fail('invalid_argument', 'Use a qualified web service ID.');
            for (const field of ['cursors', 'sessions']) {
              for (const [key, value] of Object.entries(options[field] ?? {})) {
                if (!services.includes(key)) throw fail('invalid_argument', `${field} contains an unselected service.`);
                const issue = __oxValidationError(value, __oxHelpCatalog['ox.web.search'].inputSchema.properties[field].additionalProperties, field);
                if (issue) throw fail('invalid_argument', issue);
              }
            }
            await __nativeSearchApproval(options);
            const attached = new Set((await ox.service.listAttached({purpose: options.purpose, kind: 'web'})).map(item => item.domain));
            const results = [], errors = [];
            for (const service of services) {
              try {
                const domain = service.slice(4);
                if (!attached.has(domain)) await ox.service.attach({purpose: options.purpose, domain});
                const index = await ox.service.inspect({purpose: options.purpose, domain});
                if (!index.actions.search) throw fail('search_unsupported', `${service} does not expose standard search.`);
                const detail = await ox.service.inspect({purpose: options.purpose, domain, actions: ['search']});
                const action = detail.actions.search;
                const expand = (schema, defs, depth = 0) => {
                  if (depth > 12) throw fail('invalid_contract', 'Search schema reference is too deep.');
                  if (schema?.$ref) {
                    if (!schema.$ref.startsWith('#/$defs/')) throw fail('invalid_contract', 'Search schema uses an unsupported reference.');
                    const target = defs[schema.$ref.slice(8)];
                    if (!target) throw fail('invalid_contract', 'Search schema reference is missing.');
                    return expand(target, defs, depth + 1);
                  }
                  return schema;
                };
                const input = expand(action.inputSchema, action.inputSchema?.$defs ?? {});
                const output = expand(action.outputSchema, action.outputSchema?.$defs ?? {});
                const required = input?.required ?? [];
                if (input?.type !== 'object' || input.additionalProperties !== false || !required.includes('query')
                    || required.some(key => key !== 'query') || input.properties?.query?.type !== 'string'
                    || input.properties?.limit?.type !== 'integer' || input.properties?.cursor?.type !== 'string'
                    || Object.keys(input.properties ?? {}).some(key => !['query', 'limit', 'cursor'].includes(key))
                    || output?.type !== 'object' || ['items', 'nextCursor', 'scope', 'coverage'].some(key => !(output.required ?? []).includes(key))) {
                  throw fail('invalid_contract', `${service}:search does not implement the standard search contract.`);
                }
                const definitions = action.outputSchema?.$defs ?? {};
                const properties = output.properties ?? {};
                const item = expand(properties.items?.items, definitions);
                const types = (schema, expected) => {
                  const resolved = expand(schema, definitions);
                  const actual = Array.isArray(resolved?.type) ? resolved.type : [resolved?.type];
                  return actual.length === expected.length && expected.every(type => actual.includes(type));
                };
                if (output.additionalProperties !== false || !types(properties.items, ['array'])
                    || !types(properties.nextCursor, ['string', 'null']) || !types(properties.scope, ['string'])
                    || !types(properties.coverage, ['string']) || !['complete', 'partial', 'unknown'].every(value => properties.coverage?.enum?.includes(value))
                    || item?.type !== 'object' || item.additionalProperties !== false
                    || ['title', 'url', 'snippet'].some(key => !(item.required ?? []).includes(key))
                    || !types(item.properties?.title, ['string']) || !types(item.properties?.url, ['string', 'null'])
                    || !types(item.properties?.snippet, ['string', 'null'])) {
                  throw fail('invalid_contract', `${service}:search does not declare standard search results.`);
                }
                if (action.requireApproval === true) throw fail('invalid_contract', 'Standard search must be read-only and requireApproval must be false.');
                if (action.requireAuth && !options.sessions?.[service]) throw fail('authentication_required', `${service} requires a selected session.`, 'Invoke listSessions and copy the intended authenticated descriptor into sessions for this service.');
                const maximum = input.properties.limit.maximum;
                if (!Number.isInteger(maximum) || maximum < 1 || maximum > 50) throw fail('invalid_contract', 'Search limit must declare a maximum from 1 to 50.');
                const limit = Math.min(options.limit ?? 10, maximum);
                const args = {query: options.query, limit};
                if (options.cursors?.[service] !== undefined) args.cursor = options.cursors[service];
                const issue = __oxValidationError(args, input, 'input');
                if (issue) throw fail('invalid_argument', issue);
                const page = await ox.service.invoke({purpose: options.purpose, name: `${service}:search`, input: args, ...(options.sessions?.[service] ? {session: options.sessions[service]} : {})});
                const result = {...page, service};
                const invalid = __oxValidationError(result, __oxHelpCatalog['ox.web.search'].outputSchema.properties.results.items, 'result');
                if (invalid || page.items.length > limit || (page.nextCursor !== null && page.coverage !== 'partial')) throw fail('invalid_output', invalid ?? 'Search returned too many items or inconsistent coverage.');
                if (options.cursors?.[service] !== undefined && page.nextCursor === options.cursors[service]) throw fail('invalid_output', 'Search cursor did not advance.');
                if (JSON.stringify(result).length > 1000000) throw fail('resource_limit', 'Search page exceeds the bounded response size.');
                results.push(result);
              } catch (error) {
                if (['cancelled', 'permission_denied', 'handoff_incomplete'].includes(error.code)) throw error;
                errors.push({service, code: error.code ?? 'search_failed', message: String(error.message ?? error), recovery: error.recovery ?? 'Inspect service state before retrying.'});
              }
            }
            if (!results.length) throw fail('all_searches_failed', errors.map(error => `${error.service}: ${error.code}: ${error.message}`).join('; '), 'Inspect each service failure. Do not report that no matches exist.');
            return {query: options.query, results, errors};
          }
        """#
    )
}
