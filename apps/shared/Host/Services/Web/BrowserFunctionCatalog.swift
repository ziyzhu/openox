import Foundation

nonisolated enum BrowserFunctionCatalog {
    struct Action: Sendable {
        let id: String
        let label: String
        let description: String
        let inputSchema: JSONValue
        let outputSchema: JSONValue
        var hasModelGuidance = false

        var name: String { "\(publicNamespace).\(id)" }

        var manifest: JSONValue {
            .object([
                "id": .string(id),
                "label": .string(label),
                "description": .string(description),
                "inputSchema": inputSchema,
                "outputSchema": outputSchema,
                "requireApproval": .bool(false),
                "requireAuth": .bool(false),
            ])
        }

        var functionSchema: JSONValue {
            .object([
                "description": .string(modelDescription),
                "inputSchema": inputSchema,
                "outputSchema": outputSchema,
            ])
        }

        private var modelDescription: String {
            hasModelGuidance ? ModelGuidance.text(name) : "\(description) `await \(name)({ purpose, ... })`."
        }
    }

    static let publicNamespace = "ox.web.browser"
    static let internalDomain = "ios:browser"
    static let legacyAttachmentApproval = "ox.service.attach:ios:browser"

    static let actions: [Action] = [
        Action(
            id: "navigate",
            label: "Navigate",
            description: "Navigate Browser to an absolute public HTTPS URL. Simulator builds also allow loopback HTTP.",
            inputSchema: object(
                ["url": string(description: "Absolute public HTTPS URL, or loopback HTTP in a simulator.", minimum: 1, maximum: 8_192)],
                required: ["url"]
            ),
            outputSchema: object(["url": string()], required: ["url"]),
            hasModelGuidance: true
        ),
        Action(
            id: "reload",
            label: "Reload",
            description: "Reload Browser's current page, optionally revalidating every resource from its origin.",
            inputSchema: object([
                "fromOrigin": .object([
                    "type": .string("boolean"),
                    "description": .string("When true, revalidate the page and its resources from their origin."),
                ]),
            ]),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "stopLoading",
            label: "Stop Loading",
            description: "Stop Browser's current page load.",
            inputSchema: object(),
            outputSchema: object([
                "stopped": boolean,
                "url": nullableString,
            ], required: ["stopped", "url"])
        ),
        Action(
            id: "goBack",
            label: "Go Back",
            description: "Navigate Browser to the previous item in its history.",
            inputSchema: object(),
            outputSchema: navigationResult
        ),
        Action(
            id: "goForward",
            label: "Go Forward",
            description: "Navigate Browser to the next item in its history.",
            inputSchema: object(),
            outputSchema: navigationResult
        ),
        Action(
            id: "getNavigationHistory",
            label: "Get Navigation History",
            description: "Read Browser's back, current, and forward navigation history.",
            inputSchema: object(),
            outputSchema: object([
                "back": .object(["type": .string("array"), "items": historyItem]),
                "current": .object(["oneOf": .array([.object(["type": .string("null")]), historyItem])]),
                "forward": .object(["type": .string("array"), "items": historyItem]),
            ], required: ["back", "current", "forward"])
        ),
        Action(
            id: "getPageState",
            label: "Get Page State",
            description: "Observe a bounded, read-only snapshot of Browser's visible headings, dialogs, status messages, and controls without returning input values. Control id and name attributes are separate, unnormalized strings capped at 256 characters, or null when absent; clipping sets truncated. Optionally scope with a CSS selector or frameId. Lists bounded live frames with origin-only metadata; parentId is null when unavailable across origins. Optional service selects an attached service’s prepared page instead of Browser. Includes page identity, navigation generation, loading progress, security, Screen Time, fullscreen state, and coverage limits; does not infer application readiness or authentication. Uses the same site authorization as executeScript.",
            inputSchema: observationOptions,
            outputSchema: pageState
        ),
        Action(
            id: "waitForNavigation",
            label: "Wait for Navigation",
            description: "Wait until Browser finishes its next navigation.",
            inputSchema: object([
                "timeoutMs": .object([
                    "type": .string("integer"),
                    "minimum": .int(100),
                    "maximum": .int(120_000),
                    "description": .string("Maximum wait in milliseconds. Defaults to 15000."),
                ]),
            ]),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "showPage",
            label: "Show Page",
            description: "Present Browser's live page using the Host's supported presentation. iOS adds a conversation row; macOS opens a Host window. With waitForUserInteraction, first clear capture and injected scripts, then wait until the user taps Done or Cancel.",
            inputSchema: object([
                "waitForUserInteraction": .object([
                    "type": .string("boolean"),
                    "description": .string("Show Done/Cancel and wait for the user. Requires instructions. Defaults to false."),
                ]),
                "instructions": string(description: "What the user must do on the page before tapping Done.", minimum: 1, maximum: 1_000),
            ]),
            outputSchema: object([
                "shown": boolean,
                "completion": .object([
                    "type": .string("string"),
                    "enum": .array([.string("completed"), .string("cancelled")]),
                    "description": .string("Present only when waiting: completed means the user tapped Done; cancelled means the user tapped Cancel or closed the page."),
                ]),
            ], required: ["shown"]),
            hasModelGuidance: true
        ),
        Action(
            id: "executeScript",
            label: "Execute JavaScript",
            description: "Execute arbitrary JavaScript in Browser's page, including logged-in website data and network access.",
            inputSchema: object(
                ["frameId": frameID, "script": string(
                    description: "Async JavaScript function body that returns a JSON-compatible value.",
                    minimum: 1,
                    maximum: 100_000
                )],
                required: ["script"]
            ),
            outputSchema: .object([:]),
            hasModelGuidance: true
        ),
        Action(
            id: "exportPdf",
            label: "Export PDF",
            description: "Export Browser's complete page as a PDF attachment or named Profile file.",
            inputSchema: object([
                "filename": string(
                    description: "Optional file basename, never a path.",
                    minimum: 1,
                    maximum: 255
                ),
            ]),
            outputSchema: object([
                "url": nullableString,
                "contentType": .object([
                    "type": .string("string"),
                    "enum": .array([.string("application/pdf")]),
                ]),
                "pages": integer(minimum: 1),
                "bytes": integer(minimum: 1),
                "attached": boolean,
                "file": nullableString,
            ], required: ["url", "contentType", "pages", "bytes", "attached", "file"])
        ),
        Action(
            id: "injectScript",
            label: "Inject Script",
            description: "Install a document-start script for selected domains and reload Browser.",
            inputSchema: object([
                "domains": .object([
                    "type": .string("array"),
                    "items": string(minimum: 1),
                ]),
                "script": string(minimum: 1, maximum: 100_000),
            ], required: ["domains", "script"]),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "clearScripts",
            label: "Clear Scripts",
            description: "Remove all session-scoped injected scripts and reload Browser.",
            inputSchema: object(),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "startCapture",
            label: "Start Network Capture",
            description: "Start a fresh redacted network capture in Browser and future documents without delaying page requests.",
            inputSchema: object([
                "includeBodies": .object([
                    "type": .string("boolean"),
                    "description": .string("Capture bounded request and response bodies. Defaults to false."),
                ]),
                "reload": .object([
                    "type": .string("boolean"),
                    "description": .string("Reload after installing capture when initial document-load traffic is required. Defaults to false."),
                ]),
            ]),
            outputSchema: object([
                "active": boolean,
                "includeBodies": boolean,
                "reloaded": boolean,
                "url": nullableString,
            ], required: ["active", "includeBodies", "reloaded", "url"])
        ),
        Action(
            id: "markCapture",
            label: "Mark Network Capture",
            description: "Add a labeled marker to the active network capture.",
            inputSchema: object(
                ["label": string(minimum: 1, maximum: 200)],
                required: ["label"]
            ),
            outputSchema: object(["marked": boolean], required: ["marked"])
        ),
        Action(
            id: "listCapturedEvents",
            label: "List Captured Events",
            description: "List captured event metadata without bodies. Filter by origin, path prefix, or kind; use nextCursor as after for incremental reads. Reads do not consume events. Capture is main-document instrumentation, not a complete network trace.",
            inputSchema: object([
                "after": string(description: "Opaque nextCursor from an earlier read of this capture. Restarting or discarding capture invalidates it.", minimum: 1, maximum: 100),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(500), "description": .string("Maximum returned events. Defaults to 500.")]),
                "origin": string(description: "Exact HTTP(S) or WebSocket origin, including a non-default port when present.", minimum: 1, maximum: 2_048),
                "pathPrefix": string(description: "Prefix matched against the captured URL path.", minimum: 1, maximum: 2_048),
                "kinds": .object(["type": .string("array"), "items": capturedEventProperties["kind"]!, "minItems": .int(1), "maxItems": .int(6), "uniqueItems": .bool(true)]),
            ]),
            outputSchema: object([
                "active": boolean,
                "dropped": integer(minimum: 0),
                "evicted": integer(minimum: 0),
                "events": .object([
                    "type": .string("array"),
                    "items": object(capturedEventProperties, required: ["id", "kind", "timestamp"]),
                ]),
                "nextCursor": string(description: "Opaque scan position; advances past filtered-out records too."),
                "hasMore": .object(["type": .string("boolean"), "description": .string("Unscanned records remain in this capture.")]),
                "gap": .object(["type": .string("boolean"), "description": .string("Unread records before this cursor were evicted. Check dropped separately for rejected records.")]),
                "coverage": string(),
            ], required: ["active", "dropped", "evicted", "events", "nextCursor", "hasMore", "gap", "coverage"])
        ),
        Action(
            id: "readCapturedEvent",
            label: "Read Captured Event",
            description: "Read one captured event. bodyMode defaults to raw bounded, redacted bodies; shape returns bounded JSON field/type structure without scalar values. Body completeness is unknown; invalid_json can mean non-JSON or clipped content. Shape field names may still be private.",
            inputSchema: object([
                "id": string(minimum: 1, maximum: 100),
                "bodyMode": .object(["type": .string("string"), "enum": .array([.string("raw"), .string("shape")])]),
            ], required: ["id"]),
            outputSchema: object(capturedEventProperties.merging([
                "requestBody": nullableString,
                "responseBody": nullableString,
                "requestShape": .object(["type": .array([.string("object"), .string("null")])]),
                "responseShape": .object(["type": .array([.string("object"), .string("null")])]),
                "bodyCoverage": object(["request": bodyCoverage, "response": bodyCoverage], required: ["request", "response"]),
            ]) { _, value in value }, required: ["id", "kind", "timestamp"])
        ),
        Action(
            id: "stopCapture",
            label: "Stop Network Capture",
            description: "Stop network capture, optionally discarding its current records.",
            inputSchema: object([
                "discard": .object([
                    "type": .string("boolean"),
                    "description": .string("Discard captured records after stopping. Defaults to false."),
                ]),
            ]),
            outputSchema: object(["stopped": boolean], required: ["stopped"])
        ),
    ]

    static let serviceDefinition: ServiceDefinition = {
        let manifest: JSONValue = .object([
            "domain": .string(internalDomain),
            "name": .string("Browser"),
            "description": .string("Intrinsic Browser runtime for ox.web.browser."),
            "icon": .object(["system": .string("safari")]),
            "supportedIOS": .object(["minimum": .string("26.0")]),
            "actions": .array(actions.map(\.manifest)),
        ])
        let data = try! JSONEncoder().encode(manifest)
        let catalog = try! JSONDecoder().decode(IOSCatalogManifest.self, from: data)
        return try! ServiceDefinition(iOS: catalog)
    }()

    static func action(named name: String) -> Action? {
        actions.first { $0.name == name }
    }

    static func action(id: String) -> Action? {
        actions.first { $0.id == id }
    }

    static func isLegacyApproval(_ name: String) -> Bool {
        name.hasPrefix("\(internalDomain):") || name == legacyAttachmentApproval
    }

    private static let boolean: JSONValue = .object(["type": .string("boolean")])
    private static let nullableString: JSONValue = .object([
        "type": .array([.string("string"), .string("null")]),
    ])
    private static let frameID = string(description: "Opaque live document ID from getPageState.frames. Stale IDs fail; omission selects the main frame.", minimum: 1, maximum: 100)
    private static let observationOptions = object([
        "frameId": frameID,
        "service": string(description: "Attached web service whose existing prepared page to inspect. Omit for Browser.", minimum: 1, maximum: 253),
        "selector": string(description: "Optional CSS selector limiting observation to one light-DOM subtree. Defaults to document.body. Missing scope is reported, not treated as an empty page.", minimum: 1, maximum: 2_000),
    ])
    private static let pageState = object([
        "pageID": string(),
        "navigationGeneration": integer(minimum: 0),
        "url": nullableString,
        "title": string(),
        "estimatedProgress": .object([
            "type": .string("number"), "minimum": .int(0), "maximum": .int(1),
        ]),
        "isLoading": boolean,
        "hasOnlySecureContent": boolean,
        "isBlockedByScreenTime": boolean,
        "fullscreenState": .object([
            "type": .string("string"),
            "enum": .array([
                "enteringFullscreen", "exitingFullscreen", "inFullscreen",
                "notInFullscreen", "unknown",
            ].map(JSONValue.string)),
        ]),
        "frameId": nullableString,
        "frames": .object(["type": .string("array"), "maxItems": .int(65), "items": object([
            "id": string(), "parentId": nullableString, "origin": string(), "isMainFrame": boolean,
            "serviceID": nullableString, "attached": boolean,
        ], required: ["id", "parentId", "origin", "isMainFrame", "serviceID", "attached"])]),
        "framesTruncated": boolean,
        "document": object([
            "scope": nullableString,
            "scopeFound": boolean,
            "readyState": string(),
            "busy": boolean,
            "headings": stringArray,
            "dialogs": .object(["type": .string("array"), "items": object(["label": string()], required: ["label"])]),
            "messages": stringArray,
            "controls": .object(["type": .string("array"), "items": object([
                "id": nullableString, "name": nullableString,
                "role": string(), "label": string(), "type": string(),
                "disabled": boolean, "required": boolean, "invalid": boolean,
                "checked": boolean, "expanded": boolean, "selected": boolean, "hasValue": boolean,
            ], required: ["id", "name", "role", "label", "type", "disabled", "required", "invalid"])]),
            "embeddedFrames": .object(["type": .string("array"), "items": object([
                "id": nullableString, "name": nullableString, "title": string(),
                "origin": .object(["type": .array([.string("string"), .string("null")]), "description": .string("Resolved declared src origin, not the frame's final navigated origin. No path, query, or fragment is returned.")]),
            ], required: ["id", "name", "title", "origin"])]),
            "truncated": boolean,
            "coverage": string(),
        ], required: ["scope", "scopeFound", "readyState", "busy", "headings", "dialogs", "messages", "controls", "embeddedFrames", "truncated", "coverage"]),
    ], required: ["pageID", "navigationGeneration", "url", "title", "estimatedProgress", "isLoading", "hasOnlySecureContent", "isBlockedByScreenTime", "fullscreenState", "frameId", "frames", "framesTruncated", "document"])
    private static let bodyCoverage = object([
        "status": .object(["type": .string("string"), "enum": .array(["unavailable", "invalid_json", "json"].map(JSONValue.string))]),
        "shapeTruncated": boolean,
        "bodyCompleteness": .object(["type": .string("string"), "enum": .array([.string("unknown")])]),
    ], required: ["status", "shapeTruncated", "bodyCompleteness"])
    private static let capturedEventProperties: [String: JSONValue] = [
        "id": string(),
        "kind": .object([
            "type": .string("string"),
            "enum": .array(["mark", "fetch", "xhr", "form", "resource", "websocket"].map(JSONValue.string)),
        ]),
        "timestamp": .object([
            "type": .string("number"),
            "description": .string("Milliseconds since the Unix epoch."),
        ]),
        "label": string(),
        "site": nullableString,
        "frameURL": string(),
        "method": string(),
        "url": string(),
        "requestHeaders": .object(["type": .string("object"), "additionalProperties": string()]),
        "responseHeaders": .object(["type": .string("object"), "additionalProperties": string()]),
        "status": integer(minimum: 0),
        "durationMs": .object(["type": .string("number")]),
        "started": .object(["type": .string("number")]),
        "error": string(),
        "initiatorType": string(),
        "event": string(),
    ]
    private static let stringArray: JSONValue = .object(["type": .string("array"), "items": string()])
    private static let historyItem = object([
        "initialUrl": string(),
        "title": nullableString,
        "url": string(),
    ], required: ["initialUrl", "title", "url"])
    private static let navigationResult = object([
        "navigated": boolean,
        "url": nullableString,
    ], required: ["navigated", "url"])

    private static func object(
        _ properties: [String: JSONValue] = [:],
        required: [String] = []
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func string(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string")]
        if let description { schema["description"] = .string(description) }
        if let minimum { schema["minLength"] = .int(minimum) }
        if let maximum { schema["maxLength"] = .int(maximum) }
        return .object(schema)
    }

    private static func integer(minimum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer")]
        if let minimum { schema["minimum"] = .int(minimum) }
        return .object(schema)
    }
}
