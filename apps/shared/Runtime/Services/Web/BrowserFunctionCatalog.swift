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
        Action(id: "newPage", label: "New Page", description: "Open an explicit conversation-owned page. At most eight agent pages may be open across the active Profile; opening pages count. At capacity, closes the least recently active idle page, including another conversation's page, and returns a fresh page with new IDs. Fails if every page is busy. Reuse owned pages when useful and close them when no longer needed. The page records events from its first load; networkContent embed also records bounded, redacted request and response bodies.",
               inputSchema: object([
                   "url": string(minimum: 1, maximum: 8_192),
                   "networkContent": .object([
                       "type": .string("string"), "enum": .array([.string("omit"), .string("embed")]),
                       "description": .string("Network body recording. Defaults to omit."),
                   ]),
               ], required: ["url"]),
               outputSchema: object(["pageId": string(), "mainFrameId": string()], required: ["pageId", "mainFrameId"])),
        Action(id: "pages", label: "List Pages", description: "List every live agent page in the active Profile, including pages owned by other conversations, which count toward the eight-page limit. Pages are sorted oldest lastActiveAt first; lastActiveAt is an ISO 8601 timestamp updated by page operations, not by listing. busy pages cannot be reclaimed. Opening at capacity reclaims the oldest idle page. Only owned pages expose full URLs and titles and accept page operations; other pages show their origin. Discover frame targets with frames.",
               inputSchema: object(),
               outputSchema: object(["pages": .object(["type": .string("array"), "items": object([
                   "pageId": string(), "url": nullableString, "title": string(), "isLoading": boolean, "busy": boolean, "owned": boolean, "lastActiveAt": string(),
               ], required: ["pageId", "url", "title", "isLoading", "busy", "owned", "lastActiveAt"])]), "limit": integer(minimum: 1)], required: ["pages", "limit"])),
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
            description: "Observe a bounded, read-only snapshot of the explicitly selected frame document without returning input values. Optionally scope with a CSS selector. Includes page identity, navigation generation, loading, security, frame discovery, and coverage limits; does not infer application readiness or authentication. Control id and name attributes are separate strings capped at 256 characters. Uses the same site authorization as evaluate. Discover fresh frame targets with frames; stale targets fail without fallback.",
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
            description: "Present the exact live page with Done/Cancel after pausing event recording and clearing the init script. Await user interaction and return its status in the same execution. Completed acknowledges interaction, not task success.",
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
            id: "events",
            label: "Read Events",
            description: "Read an explicit page's recorded events in order, like page.on() handlers run after the fact. Pass nextCursor as after for incremental reads; save a cursor before a step to read only what it caused. Reads do not consume events. The page keeps its latest 500 events; gap reports evicted unread events. Bodies are omitted; use readEventBody.",
            inputSchema: object([
                "pageId": pageID,
                "event": eventName,
                "after": string(description: "Opaque nextCursor from an earlier read of this page.", minimum: 1, maximum: 100),
                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(500), "description": .string("Maximum returned events. Defaults to 200.")]),
            ], required: ["pageId"]),
            outputSchema: object([
                "events": .object(["type": .string("array"), "items": event]),
                "nextCursor": string(description: "Opaque position; advances past filtered-out events too."),
                "hasMore": .object(["type": .string("boolean"), "description": .string("Unscanned events remain.")]),
                "gap": .object(["type": .string("boolean"), "description": .string("Unread events before this cursor were evicted.")]),
                "evicted": integer(minimum: 0),
                "dropped": integer(minimum: 0),
                "recording": boolean,
                "coverage": string(),
            ], required: ["events", "nextCursor", "hasMore", "gap", "evicted", "dropped", "recording", "coverage"])
        ),
        Action(
            id: "waitForEvent",
            label: "Wait for Event",
            description: "Wait for an explicit page's next matching event, like page.waitForEvent(). Only events recorded after the call starts resolve it; read events for earlier ones.",
            inputSchema: object([
                "pageId": pageID,
                "event": eventName,
                "timeoutMs": .object([
                    "type": .string("integer"), "minimum": .int(100), "maximum": .int(120_000),
                    "description": .string("Maximum wait in milliseconds. Defaults to 15000."),
                ]),
            ], required: ["pageId", "event"]),
            outputSchema: event
        ),
        Action(
            id: "readEventBody",
            label: "Read Event Body",
            description: "Read the bounded, redacted bodies of one request or response event from a page opened with networkContent embed. mode defaults to raw; shape returns JSON field/type structure without scalar values. Body completeness is unknown; invalid_json can mean non-JSON or clipped content. Shape field names may still be private.",
            inputSchema: object([
                "pageId": pageID,
                "id": string(minimum: 1, maximum: 100),
                "mode": .object(["type": .string("string"), "enum": .array([.string("raw"), .string("shape")])]),
            ], required: ["pageId", "id"]),
            outputSchema: object([
                "id": string(),
                "requestBody": nullableString,
                "responseBody": nullableString,
                "requestShape": .object(["type": .array([.string("object"), .string("null")])]),
                "responseShape": .object(["type": .array([.string("object"), .string("null")])]),
                "bodyCoverage": object(["request": bodyCoverage, "response": bodyCoverage], required: ["request", "response"]),
            ], required: ["id"])
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
    ], required: ["pageID", "navigationGeneration", "url", "title", "estimatedProgress", "isLoading", "hasOnlySecureContent", "isBlockedByScreenTime", "fullscreenState", "frameId", "frames", "framesTruncated", "document"])
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
    private static let eventName: JSONValue = .object([
        "type": .string("string"),
        "enum": .array(BrowserEventLog.names.map(JSONValue.string)),
    ])
    private static let event = object([
        "id": string(),
        "event": eventName,
        "timestamp": .object(["type": .string("number"), "description": .string("Milliseconds since the Unix epoch.")]),
        "frameId": nullableString,
        "origin": nullableString,
        "site": nullableString,
        "url": string(),
        "type": string(description: "console: warning or error; dialog: alert, confirm or prompt."),
        "text": string(),
        "message": string(),
        "stack": string(),
        "defaultValue": nullableString,
        "disposition": .object(["type": .string("string"), "enum": .array(["dismissed", "user", "samePage", "rejected", "cancelled"].map(JSONValue.string))]),
        "suggestedFilename": string(),
        "isMultiple": boolean,
        "parentId": nullableString,
        "resourceType": string(),
        "method": string(),
        "status": integer(minimum: 0),
        "requestHeaders": .object(["type": .string("object"), "additionalProperties": string()]),
        "responseHeaders": .object(["type": .string("object"), "additionalProperties": string()]),
        "hasBody": boolean,
        "failure": string(),
        "durationMs": .object(["type": .string("number")]),
    ], required: ["id", "event", "timestamp"], additional: true)
    private static let stringArray: JSONValue = .object(["type": .string("array"), "items": string()])
    private static let navigationResult = object([
        "navigated": boolean,
        "url": nullableString,
    ], required: ["navigated", "url"])

    private static func object(
        _ properties: [String: JSONValue] = [:],
        required: [String] = [],
        additional: Bool = false
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(additional),
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
