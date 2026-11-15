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
        Action(id: "newPage", label: "New Page", description: "Open an explicit conversation-owned page. At most six agent pages may be open across the active Profile; opening pages count. At capacity reuse a page or close one. Never silently replaces or evicts pages.",
               inputSchema: object(["url": string(minimum: 1, maximum: 8_192)], required: ["url"]),
               outputSchema: object(["pageId": string(), "mainFrameId": string()], required: ["pageId", "mainFrameId"])),
        Action(id: "pages", label: "List Pages", description: "List every live agent page in the active Profile, including pages owned by other conversations, which count toward the six-page limit. Only owned pages expose full URLs and titles and accept page operations; other pages show their origin. Discover frame targets with frames.",
               inputSchema: object(),
               outputSchema: object(["pages": .object(["type": .string("array"), "items": object([
                   "pageId": string(), "url": nullableString, "title": string(), "isLoading": boolean, "busy": boolean, "owned": boolean,
               ], required: ["pageId", "url", "title", "isLoading", "busy", "owned"])]), "limit": integer(minimum: 1)], required: ["pages", "limit"])),
        Action(id: "frames", label: "List Frames", description: "List fresh document targets of an explicit owned page, including the main document. Frame discovery is bounded; cross-origin parents may be unknown. A replaced document invalidates its frameId.",
               inputSchema: object(["pageId": pageID], required: ["pageId"]),
               outputSchema: object(["frames": frames, "framesTruncated": boolean], required: ["frames", "framesTruncated"])),
        Action(id: "close", label: "Close Page", description: "Close an explicit idle conversation-owned page. Busy pages and pages awaiting user interaction cannot be closed. Does not clear website data or sign out.",
               inputSchema: object(["pageId": pageID], required: ["pageId"]), outputSchema: object(["closed": boolean], required: ["closed"])),
        Action(
            id: "goto",
            label: "Go to URL",
            description: "Navigate Browser to an absolute public HTTPS URL. Simulator builds also allow loopback HTTP.",
            inputSchema: object(
                ["pageId": pageID, "url": string(description: "Absolute public HTTPS URL, or loopback HTTP in a simulator.", minimum: 1, maximum: 8_192)],
                required: ["pageId", "url"]
            ),
            outputSchema: object(["url": string()], required: ["url"]),
            hasModelGuidance: true
        ),
        Action(
            id: "reload",
            label: "Reload",
            description: "Reload an explicit page, optionally revalidating every resource from its origin.",
            inputSchema: object([
                "pageId": pageID,
                "fromOrigin": .object([
                    "type": .string("boolean"),
                    "description": .string("When true, revalidate the page and its resources from their origin."),
                ]),
            ], required: ["pageId"]),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "goBack",
            label: "Go Back",
            description: "Navigate an explicit page to the previous item in its history. Returns navigated: false without a previous item.",
            inputSchema: object(["pageId": pageID], required: ["pageId"]),
            outputSchema: navigationResult
        ),
        Action(
            id: "goForward",
            label: "Go Forward",
            description: "Navigate an explicit page to the next item in its history. Returns navigated: false without a next item.",
            inputSchema: object(["pageId": pageID], required: ["pageId"]),
            outputSchema: navigationResult
        ),
        Action(
            id: "snapshot",
            label: "Snapshot",
            description: "Observe a bounded, read-only snapshot of the explicitly selected frame document without returning input values. Optionally scope with a CSS selector. Includes page identity, navigation generation, loading, security, frame discovery, recent auto-dismissed JavaScript dialogs, and coverage limits; does not infer application readiness or authentication. Control id and name attributes are separate strings capped at 256 characters. Uses the same site authorization as evaluate. Discover fresh frame targets with frames; stale targets fail without fallback.",
            inputSchema: observationOptions,
            outputSchema: pageState
        ),
        Action(
            id: "waitForURL",
            label: "Wait for URL",
            description: "Wait until an explicit page finishes a navigation. With url, resolve once the finished page URL matches it, including immediately; * matches any characters. Without url, wait for the next finished navigation.",
            inputSchema: object([
                "pageId": pageID,
                "url": string(description: "Exact URL or glob where * matches any characters.", minimum: 1, maximum: 8_192),
                "timeoutMs": .object([
                    "type": .string("integer"),
                    "minimum": .int(100),
                    "maximum": .int(120_000),
                    "description": .string("Maximum wait in milliseconds. Defaults to 15000."),
                ]),
            ], required: ["pageId"]),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "showPage",
            label: "Show Page",
            description: "Present the exact live page with Done/Cancel after clearing capture and the init script. Await user interaction and return its status in the same execution. Completed acknowledges interaction, not task success.",
            inputSchema: object(["pageId": pageID], required: ["pageId"]),
            outputSchema: object([
                "status": .object([
                    "type": .string("string"),
                    "enum": .array([.string("completed"), .string("cancelled")]),
                    "description": .string("Completed means Done, not verified task success; cancelled means Cancel."),
                ]),
            ], required: ["status"]),
            hasModelGuidance: true
        ),
        Action(
            id: "evaluate",
            label: "Evaluate JavaScript",
            description: "Execute arbitrary JavaScript in Browser's page, including logged-in website data and network access.",
            inputSchema: object(
                ["frameId": frameID, "script": string(
                    description: "Async JavaScript function body that returns a JSON-compatible value.",
                    minimum: 1,
                    maximum: 100_000
                )],
                required: ["frameId", "script"]
            ),
            outputSchema: .object([:]),
            hasModelGuidance: true
        ),
        Action(
            id: "pdf",
            label: "Export PDF",
            description: "Export an explicit complete page as a PDF attachment or named Profile file.",
            inputSchema: exportOptions,
            outputSchema: exportResult("application/pdf", extra: ["pages": integer(minimum: 1)])
        ),
        Action(
            id: "screenshot",
            label: "Screenshot",
            description: "Capture an explicit page's rendered contents as an image attachment or named Profile file. Large pages are downsampled. Analyze a named file on device with ox.vision.analyze.",
            inputSchema: exportOptions,
            outputSchema: exportResult("image/png", "image/jpeg", extra: ["width": integer(minimum: 1), "height": integer(minimum: 1)])
        ),
        Action(
            id: "addInitScript",
            label: "Add Init Script",
            description: "Replace an explicit page's document-start script for selected domains and reload it. Applies to future documents, not a single frame target. Calling again replaces the previous script; showPage and close remove it.",
            inputSchema: object([
                "pageId": pageID,
                "domains": .object([
                    "type": .string("array"),
                    "items": string(minimum: 1),
                ]),
                "script": string(minimum: 1, maximum: 100_000),
            ], required: ["pageId", "domains", "script"]),
            outputSchema: object(["url": nullableString], required: ["url"])
        ),
        Action(
            id: "startCapture",
            label: "Start Network Capture",
            description: "Start a fresh redacted network capture on an explicit page and its future documents without delaying page requests.",
            inputSchema: object([
                "pageId": pageID,
                "includeBodies": .object([
                    "type": .string("boolean"),
                    "description": .string("Capture bounded request and response bodies. Defaults to false."),
                ]),
                "reload": .object([
                    "type": .string("boolean"),
                    "description": .string("Reload after installing capture when initial document-load traffic is required. Defaults to false."),
                ]),
            ], required: ["pageId"]),
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
                ["pageId": pageID, "label": string(minimum: 1, maximum: 200)],
                required: ["pageId", "label"]
            ),
            outputSchema: object(["marked": boolean], required: ["marked"])
        ),
        Action(
            id: "listCapturedEvents",
            label: "List Captured Events",
            description: "List captured event metadata without bodies. Filter by origin, path prefix, or kind; use nextCursor as after for incremental reads. Reads do not consume events. Capture is main-document instrumentation, not a complete network trace.",
            inputSchema: object([
                "pageId": pageID,
                "after": string(description: "Opaque nextCursor from an earlier read of this capture. Restarting or discarding capture invalidates it.", minimum: 1, maximum: 100),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(500), "description": .string("Maximum returned events. Defaults to 500.")]),
                "origin": string(description: "Exact HTTP(S) or WebSocket origin, including a non-default port when present.", minimum: 1, maximum: 2_048),
                "pathPrefix": string(description: "Prefix matched against the captured URL path.", minimum: 1, maximum: 2_048),
                "kinds": .object(["type": .string("array"), "items": capturedEventProperties["kind"]!, "minItems": .int(1), "maxItems": .int(6), "uniqueItems": .bool(true)]),
            ], required: ["pageId"]),
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
                "pageId": pageID,
                "id": string(minimum: 1, maximum: 100),
                "bodyMode": .object(["type": .string("string"), "enum": .array([.string("raw"), .string("shape")])]),
            ], required: ["pageId", "id"]),
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
                "pageId": pageID,
                "discard": .object([
                    "type": .string("boolean"),
                    "description": .string("Discard captured records after stopping. Defaults to false."),
                ]),
            ], required: ["pageId"]),
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
    private static let pageID = string(description: "Explicit owned page ID from newPage or pages.", minimum: 1, maximum: 100)
    private static let frameID = string(description: "Explicit live document ID from newPage or frames. Required for main documents too. Stale targets fail without fallback.", minimum: 1, maximum: 100)
    private static let observationOptions = object([
        "frameId": frameID,
        "selector": string(description: "Optional CSS selector limiting observation to one light-DOM subtree. Defaults to document.body. Missing scope is reported, not treated as an empty page.", minimum: 1, maximum: 2_000),
    ], required: ["frameId"])
    private static let frames: JSONValue = .object(["type": .string("array"), "maxItems": .int(65), "items": object([
        "id": string(), "parentId": nullableString, "origin": string(), "isMainFrame": boolean,
        "serviceID": nullableString, "attached": boolean,
    ], required: ["id", "parentId", "origin", "isMainFrame", "serviceID", "attached"])])
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
        "javaScriptDialogs": .object(["type": .string("array"), "maxItems": .int(BrowserSession.maximumRecordedDialogs), "items": object([
            "type": .object(["type": .string("string"), "enum": .array(["alert", "confirm", "prompt"].map(JSONValue.string))]),
            "message": string(), "origin": string(), "timestamp": .object(["type": .string("number"), "description": .string("Milliseconds since the Unix epoch.")]),
        ], required: ["type", "message", "origin", "timestamp"])]),
        "frames": frames,
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
    ], required: ["pageID", "navigationGeneration", "url", "title", "estimatedProgress", "isLoading", "hasOnlySecureContent", "isBlockedByScreenTime", "fullscreenState", "frameId", "javaScriptDialogs", "frames", "framesTruncated", "document"])
    private static let exportOptions = object([
        "pageId": pageID,
        "filename": string(description: "Optional file basename, never a path.", minimum: 1, maximum: 255),
    ], required: ["pageId"])
    private static func exportResult(_ contentTypes: String..., extra: [String: JSONValue]) -> JSONValue {
        object([
            "url": nullableString,
            "contentType": .object(["type": .string("string"), "enum": .array(contentTypes.map(JSONValue.string))]),
            "bytes": integer(minimum: 1),
            "attached": boolean,
            "file": nullableString,
        ].merging(extra) { _, value in value }, required: ["url", "contentType"] + extra.keys.sorted() + ["bytes", "attached", "file"])
    }
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
