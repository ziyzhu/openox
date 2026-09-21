import Foundation

nonisolated enum BrowserFunctionCatalog {
    struct Action: Sendable {
        let id: String
        let label: String
        let description: String
        let inputSchema: JSONValue
        let outputSchema: JSONValue

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
                "description": .string("\(description) `await \(name)({ ..., purpose })`."),
                "inputSchema": inputSchema,
                "outputSchema": outputSchema,
            ])
        }
    }

    static let publicNamespace = "ox.web.browser"
    static let internalDomain = "ios:browser"
    static let legacyAttachmentApproval = "ox.service.attach:ios:browser"

    static let actions: [Action] = [
        Action(
            id: "navigate",
            label: "Navigate",
            description: "Navigate Browser to an absolute HTTP or HTTPS URL.",
            inputSchema: object(
                ["url": string(description: "Absolute HTTP or HTTPS URL.", minimum: 1, maximum: 8_192)],
                required: ["url"]
            ),
            outputSchema: object(["url": string()], required: ["url"])
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
            id: "getPageInfo",
            label: "Get Page Info",
            description: "Read Browser's current URL, title, loading progress, security state, Screen Time state, and fullscreen state.",
            inputSchema: object(),
            outputSchema: object([
                "url": nullableString,
                "title": string(),
                "estimatedProgress": .object([
                    "type": .string("number"),
                    "minimum": .int(0),
                    "maximum": .int(1),
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
            ], required: [
                "url", "title", "estimatedProgress", "isLoading", "hasOnlySecureContent",
                "isBlockedByScreenTime", "fullscreenState",
            ])
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
            description: "Add a chat row the user can tap to view Browser's live page.",
            inputSchema: object(),
            outputSchema: object(["shown": boolean], required: ["shown"])
        ),
        Action(
            id: "executeScript",
            label: "Execute JavaScript",
            description: "Execute arbitrary JavaScript in Browser's page, including signed-in website data and network access.",
            inputSchema: object(
                ["script": string(
                    description: "Async JavaScript function body that returns a JSON-compatible value.",
                    minimum: 1,
                    maximum: 100_000
                )],
                required: ["script"]
            ),
            outputSchema: .object([:])
        ),
        Action(
            id: "exportPdf",
            label: "Export PDF",
            description: "Export Browser's complete page as a PDF attachment or named Profile artifact.",
            inputSchema: object([
                "filename": string(
                    description: "Optional artifact basename, never a path.",
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
                "artifact": nullableString,
            ], required: ["url", "contentType", "pages", "bytes", "attached", "artifact"])
        ),
        Action(
            id: "waitForUserInteraction",
            label: "Wait for User Interaction",
            description: "Pause automation and let the user complete a human-only step in Browser after clearing capture and injected scripts.",
            inputSchema: object(
                ["instructions": string(minimum: 1, maximum: 1_000)],
                required: ["instructions"]
            ),
            outputSchema: object(["completed": boolean], required: ["completed"])
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
            description: "Start a fresh redacted network capture at document start and reload Browser.",
            inputSchema: object(),
            outputSchema: object(["url": nullableString], required: ["url"])
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
            description: "List captured event metadata without request or response bodies.",
            inputSchema: object(),
            outputSchema: object([
                "events": .object([
                    "type": .string("array"),
                    "items": .object([:]),
                ]),
            ], required: ["events"])
        ),
        Action(
            id: "readCapturedEvent",
            label: "Read Captured Event",
            description: "Read one captured event, including bounded and redacted bodies available to the page.",
            inputSchema: object(
                ["id": string(minimum: 1, maximum: 100)],
                required: ["id"]
            ),
            outputSchema: .object(["type": .string("object")])
        ),
        Action(
            id: "stopCapture",
            label: "Stop Network Capture",
            description: "Stop network capture while retaining its current records.",
            inputSchema: object(),
            outputSchema: object(["stopped": boolean], required: ["stopped"])
        ),
    ]

    static let actionNames = actions.map(\.name)
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
