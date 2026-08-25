import Foundation
import JavaScriptCore

nonisolated enum OxArtifacts {
    static let function = OxFunction(
        namespace: "artifact",
        schema: {
            [
                entry(
                    "ox.artifact.attach",
                    "Add one stored artifact to model context: `await ox.artifact.attach({ source, purpose })`. This is transient and does not present the artifact in the visible conversation. Web images and PDFs are attached directly by `ox.web.fetch`.",
                    input: object([
                        "source": filename,
                        "purpose": purpose,
                    ], required: ["source", "purpose"]),
                    output: attachment
                ),
                entry(
                    "ox.artifact.import",
                    "Fetch and persist one public HTTP or HTTPS resource as an artifact: `await ox.artifact.import({ url, filename?, purpose })`. The user approves each import unless they enabled automatic approval.",
                    input: object([
                        "url": string("Public HTTP or HTTPS resource URL."),
                        "filename": filename,
                        "purpose": purpose,
                    ], required: ["url", "purpose"]),
                    output: item
                ),
                entry(
                    "ox.artifact.rename",
                    "Rename an artifact and rewrite Ox-controlled chat references: `await ox.artifact.rename({ filename, newFilename, purpose })`. Fails on a case-insensitive collision. The user approves each rename unless they enabled automatic approval.",
                    input: object(["filename": filename, "newFilename": filename, "purpose": purpose], required: ["filename", "newFilename", "purpose"]),
                    output: item
                ),
                entry(
                    "ox.artifact.present",
                    "Show one or more existing artifacts from the active Profile in the conversation: `await ox.artifact.present({ filename, purpose })` or `await ox.artifact.present({ filenames, purpose })`. Use this for artifacts that were not just written or edited, because successful `ox.fs.write` and `ox.fs.edit` calls for artifacts display them automatically. Adds live filename references the user can open; the files themselves are never copied. The single form returns one item, while the plural form returns items in the requested order.",
                    input: presentInput,
                    output: presentOutput
                ),
            ]
        },
        installNatives: { context, env in
            let attach: @convention(block) (String, JSValue) -> JSValue = { filename, purpose in
                env.call { try await $0.attachArtifact(filename: filename, purpose: purpose.toString()!) }
            }
            let importURL: @convention(block) (String, JSValue, JSValue) -> JSValue = { url, filename, purpose in
                env.call {
                    try await $0.importWebArtifact(
                        url: url,
                        filename: filename.isString ? filename.toString() : nil,
                        purpose: purpose.toString()!
                    )
                }
            }
            let rename: @convention(block) (String, String, JSValue) -> JSValue = { filename, newFilename, purpose in
                env.call { try await $0.renameArtifact(filename: filename, newFilename: newFilename, purpose: purpose.toString()!) }
            }
            let present: @convention(block) (String, JSValue) -> JSValue = { filename, purpose in
                env.call { try await $0.presentArtifact(filename: filename, purpose: purpose.toString()!) }
            }
            let presentMany: @convention(block) (JSValue, JSValue) -> JSValue = { filenames, purpose in
                let values = jsValueToJSON(filenames)?.arrayValue?.compactMap(\.stringValue) ?? []
                return env.call { try await $0.presentArtifacts(filenames: values, purpose: purpose.toString()!) }
            }
            context.setObject(attach as AnyObject, forKeyedSubscript: "__nativeArtifactAttach" as NSString)
            context.setObject(importURL as AnyObject, forKeyedSubscript: "__nativeArtifactImportURL" as NSString)
            context.setObject(rename as AnyObject, forKeyedSubscript: "__nativeArtifactRename" as NSString)
            context.setObject(present as AnyObject, forKeyedSubscript: "__nativeArtifactPresent" as NSString)
            context.setObject(presentMany as AnyObject, forKeyedSubscript: "__nativeArtifactsPresent" as NSString)
        },
        jsFragment: """
          attach: (value) => { const options = __oxOptions(value, 'ox.artifact.attach'); return __nativeArtifactAttach(String(options.source), String(options.purpose)); },
          import: (value) => { const options = __oxOptions(value, 'ox.artifact.import'); return __nativeArtifactImportURL(String(options.url), options.filename == null ? null : String(options.filename), String(options.purpose)); },
          rename: (value) => { const options = __oxOptions(value, 'ox.artifact.rename'); return __nativeArtifactRename(String(options.filename), String(options.newFilename), String(options.purpose)); },
          present: (value) => { const options = __oxOptions(value, 'ox.artifact.present'); return options.filenames == null ? __nativeArtifactPresent(String(options.filename), String(options.purpose)) : __nativeArtifactsPresent(options.filenames, String(options.purpose)); }
        """
    )

    private static let purpose: JSONValue = .object([
        "type": .string("string"),
        "minLength": .int(1),
        "description": .string("Short (<10 words) description shown as the step label."),
    ])
    private static let filename = string("Artifact basename, never a path.")
    private static let filenames: JSONValue = .object([
        "type": .string("array"),
        "items": filename,
        "minItems": .int(1),
        "maxItems": .int(20),
        "uniqueItems": .bool(true),
        "description": .string("Ordered artifact basenames, never paths."),
    ])
    private static let nullableString = JSONValue.object(["type": .array([.string("string"), .string("null")])])

    private static let presentInput: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["filename": filename, "filenames": filenames, "purpose": purpose]),
        "required": .array([.string("purpose")]),
        "oneOf": .array([
            .object(["required": .array([.string("filename")])]),
            .object(["required": .array([.string("filenames")])]),
        ]),
        "additionalProperties": .bool(false),
    ])

    private static let presentOutput: JSONValue = .object([
        "oneOf": .array([
            item,
            .object(["type": .string("array"), "items": item]),
        ]),
    ])

    private static let attachment = object([
        "filename": string("Attachment display filename."),
        "contentType": string("Attachment MIME type."),
        "bytes": .object(["type": .string("integer")]),
        "kind": .object(["type": .string("string"), "enum": .array(["image", "pdf", "text", "html", "file"].map(JSONValue.string))]),
    ], required: ["filename", "contentType", "bytes", "kind"])

    private static let item = object([
        "filename": string("Artifact filename."),
        "type": string("Uniform type identifier."),
        "mimeType": string("MIME type."),
        "kind": .object(["type": .string("string"), "enum": .array(["image", "pdf", "text", "html", "file"].map(JSONValue.string))]),
        "size": .object(["type": .array([.string("integer"), .string("null")])]),
        "createdAt": nullableString,
        "modifiedAt": nullableString,
        "exists": .object(["type": .string("boolean")]),
    ], required: ["filename", "type", "mimeType", "kind", "size", "createdAt", "modifiedAt", "exists"])

    private static func entry(_ name: String, _ description: String, input: JSONValue, output: JSONValue) -> (String, JSONValue) {
        (name, .object([
            "description": .string(description),
            "inputSchema": input,
            "outputSchema": output,
        ]))
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func string(_ value: JSValue) -> String? {
        value.isString ? value.toString() : nil
    }
}
