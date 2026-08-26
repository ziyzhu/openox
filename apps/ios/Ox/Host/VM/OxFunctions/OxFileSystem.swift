import Foundation
import JavaScriptCore

nonisolated enum OxFileSystem {
    static let invocations: [InvocationName] = [
        .fsList,
        .fsRead,
        .fsWrite,
        .fsEdit,
        .fsDelete,
        .fsGlob,
        .fsGrep,
    ]

    static let approvalInvocations: Set<InvocationName> = [
        .fsWrite,
        .fsEdit,
        .fsDelete,
    ]

    static let function = OxFunction(
        namespace: "fs",
        schema: {
            [
                entry(
                    "ox.fs.list",
                    "List one directory in the active Profile's virtual filesystem: `await ox.fs.list({ path?, options?, purpose })`. The default path is `.`. Persisted chats are read-only under `chats/<chat-id>/`. When Files is attached, chosen folders are mounted under `files/<folder-id>/`. Returns virtual paths only; local paths are never exposed.",
                    input: object([
                        "path": path("Directory path. Defaults to `.`."),
                        "options": object(["limit": integer("Maximum entries to return, clamped to 1-100.", minimum: 1, maximum: 100)]),
                        "purpose": purpose,
                    ], required: ["purpose"]),
                    output: listing
                ),
                entry(
                    "ox.fs.read",
                    "Read a file's complete text into JavaScript: `await ox.fs.read({ path, options?, purpose })`. There is no default text or PDF page cutoff. Filter or slice the result in JavaScript before printing; execution output has fixed line and byte limits. Optional `maxBytes` and `maxPages` request a shorter read and set `truncated` when content remains. A 32 MiB file safety limit applies. Persisted chat metadata and transcripts are read-only under `chats/<chat-id>/{chat.json,turns.jsonl}`; runtime `context.json` is private. Images and unsupported binary files return an explanation instead of text.",
                    input: object([
                        "path": path("File path to read."),
                        "options": object([
                            "maxBytes": integer("Optional text byte limit; omitted reads the full text.", minimum: 1, maximum: ArtifactLimits.fileBytes),
                            "maxPages": integer("Optional PDF page limit; omitted reads every page.", minimum: 1, maximum: Int.max),
                        ]),
                        "purpose": purpose,
                    ], required: ["path", "purpose"]),
                    output: read
                ),
                entry(
                    "ox.fs.write",
                    writeGuide,
                    input: object([
                        "path": path("File path to create or replace."),
                        "content": string("Complete UTF-8 file contents."),
                        "purpose": purpose,
                    ], required: ["path", "content", "purpose"]),
                    output: item
                ),
                entry(
                    "ox.fs.edit",
                    "Atomically edit one UTF-8 file with exact replacements: `await ox.fs.edit({ path, edits, purpose })`. Every non-empty `oldText` must match exactly once in the original file and edits must not overlap. One empty `oldText` appends.",
                    input: object([
                        "path": path("Existing UTF-8 file path."),
                        "edits": .object([
                            "type": .string("array"),
                            "items": object([
                                "oldText": string("Exact text to replace. Empty appends."),
                                "newText": string("Replacement text. Empty deletes the match."),
                            ], required: ["oldText", "newText"]),
                        ]),
                        "purpose": purpose,
                    ], required: ["path", "edits", "purpose"]),
                    output: item
                ),
                entry(
                    "ox.fs.delete",
                    "Delete one artifact, Profile-owned skill, Local service source file, or file inside a chosen Files folder: `await ox.fs.delete({ path, purpose })`. Resource roots such as Local services use their `ox.service.delete` lifecycle function. Deleting inside a chosen Files folder requires approval unless the user has allowed that action without asking. `MEMORY.md`, `SOUL.md`, and chosen folders themselves cannot be deleted.",
                    input: object(["path": path("Artifact, skill, Local service source, or chosen Files path."), "purpose": purpose], required: ["path", "purpose"]),
                    output: deletion
                ),
                entry(
                    "ox.fs.glob",
                    "Find file paths by glob: `await ox.fs.glob({ pattern, path?, options?, purpose })`. Supports `*`, `**`, and `?`. The optional directory path bounds the search; results are full virtual paths.",
                    input: object([
                        "pattern": string("Glob pattern matched relative to `path`."),
                        "path": path("Directory to search. Defaults to `.`."),
                        "options": object(["limit": integer("Maximum paths to return, clamped to 1-1000.", minimum: 1, maximum: 1_000)]),
                        "purpose": purpose,
                    ], required: ["pattern", "purpose"]),
                    output: glob
                ),
                entry(
                    "ox.fs.grep",
                    "Search text inside files: `await ox.fs.grep({ pattern, path?, options?, purpose })`. The optional `glob` filters candidate paths. Persisted chat transcripts are searched only when `path` explicitly names `chats` or one of its descendants; a root search does not sweep chat history. Matching excerpts are centered on the match. Unsupported binary artifacts are skipped.",
                    input: object([
                        "pattern": string("Regular expression, or literal text when `options.literal` is true."),
                        "path": path("Directory or file to search. Defaults to `.`."),
                        "options": object([
                            "glob": string("Optional glob matched relative to `path`."),
                            "ignoreCase": boolean("Case-insensitive matching. Defaults to false."),
                            "literal": boolean("Treat `pattern` as literal text. Defaults to false."),
                            "contextLines": integer("Lines before and after each match, clamped to 0-5.", minimum: 0, maximum: 5),
                            "limit": integer("Maximum matches to return, clamped to 1-200.", minimum: 1, maximum: 200),
                        ]),
                        "purpose": purpose,
                    ], required: ["pattern", "purpose"]),
                    output: grep
                ),
            ]
        },
        installNatives: { context, env in
            let list: @convention(block) (String, JSValue, JSValue) -> JSValue = { path, options, purpose in
                env.call { try await $0.listFileSystem(path: path, options: jsValueToJSON(options), purpose: purpose.toString()!) }
            }
            let read: @convention(block) (String, JSValue, JSValue) -> JSValue = { path, options, purpose in
                env.call { try await $0.readFileSystem(path: path, options: jsValueToJSON(options), purpose: purpose.toString()!) }
            }
            let write: @convention(block) (String, String, JSValue) -> JSValue = { path, content, purpose in
                env.call { try await $0.writeFileSystem(path: path, content: content, purpose: purpose.toString()!) }
            }
            let edit: @convention(block) (String, JSValue, JSValue) -> JSValue = { path, edits, purpose in
                env.call { try await $0.editFileSystem(path: path, edits: jsValueToJSON(edits), purpose: purpose.toString()!) }
            }
            let delete: @convention(block) (String, JSValue) -> JSValue = { path, purpose in
                env.call { try await $0.deleteFileSystem(path: path, purpose: purpose.toString()!) }
            }
            let glob: @convention(block) (String, String, JSValue, JSValue) -> JSValue = { pattern, path, options, purpose in
                env.call { try await $0.globFileSystem(pattern: pattern, path: path, options: jsValueToJSON(options), purpose: purpose.toString()!) }
            }
            let grep: @convention(block) (String, String, JSValue, JSValue) -> JSValue = { pattern, path, options, purpose in
                env.call { try await $0.grepFileSystem(pattern: pattern, path: path, options: jsValueToJSON(options), purpose: purpose.toString()!) }
            }
            context.setObject(list as AnyObject, forKeyedSubscript: "__nativeFSList" as NSString)
            context.setObject(read as AnyObject, forKeyedSubscript: "__nativeFSRead" as NSString)
            context.setObject(write as AnyObject, forKeyedSubscript: "__nativeFSWrite" as NSString)
            context.setObject(edit as AnyObject, forKeyedSubscript: "__nativeFSEdit" as NSString)
            context.setObject(delete as AnyObject, forKeyedSubscript: "__nativeFSDelete" as NSString)
            context.setObject(glob as AnyObject, forKeyedSubscript: "__nativeFSGlob" as NSString)
            context.setObject(grep as AnyObject, forKeyedSubscript: "__nativeFSGrep" as NSString)
        },
        jsFragment: """
          list: (value) => { const options = __oxOptions(value, 'ox.fs.list'); return __nativeFSList(options.path == null ? '.' : String(options.path), options.options ?? null, String(options.purpose)); },
          read: (value) => { const options = __oxOptions(value, 'ox.fs.read'); return __nativeFSRead(String(options.path), options.options ?? null, String(options.purpose)); },
          write: (value) => { const options = __oxOptions(value, 'ox.fs.write'); return __nativeFSWrite(String(options.path), String(options.content), String(options.purpose)); },
          edit: (value) => { const options = __oxOptions(value, 'ox.fs.edit'); return __nativeFSEdit(String(options.path), options.edits, String(options.purpose)); },
          delete: (value) => { const options = __oxOptions(value, 'ox.fs.delete'); return __nativeFSDelete(String(options.path), String(options.purpose)); },
          glob: (value) => { const options = __oxOptions(value, 'ox.fs.glob'); return __nativeFSGlob(String(options.pattern), options.path == null ? '.' : String(options.path), options.options ?? null, String(options.purpose)); },
          grep: (value) => { const options = __oxOptions(value, 'ox.fs.grep'); return __nativeFSGrep(String(options.pattern), options.path == null ? '.' : String(options.path), options.options ?? null, String(options.purpose)); }
        """
    )

    private static let purpose: JSONValue = .object([
        "type": .string("string"),
        "minLength": .int(1),
        "description": .string("Short (<10 words) description shown as the step label."),
    ])
    private static let nullableString = JSONValue.object(["type": .array([.string("string"), .string("null")])])

    private static let writeGuide = """
    Atomically create or replace one UTF-8 file: `await ox.fs.write({ path, content, purpose })`. The writable virtual layout is `MEMORY.md`, `SOUL.md`, `artifacts/<filename>`, user `skills/<name>/SKILL.md`, Local service source under `services/<kind>/<id>/...`, and files inside an attached chosen folder at `files/<folder-id>/...`. Bundled service source is read-only, while Development and Remote services expose only read-only manifests. Persisted chats and skills under `system:*` and `service:*` are read-only.

    Read before overwriting an existing file and prefer `ox.fs.edit` for targeted changes. Writing or editing inside a chosen Files folder requires approval unless the user has allowed that action without asking. Profile-owned memory, soul, artifact, and skill writes do not require approval. Persist concise durable memories when they are worth keeping, without waiting for an explicit request; do not register redundant memories. Persist soul or skills only when the user explicitly asks for a durable change.
    """

    private static let item = object([
        "path": path("Full virtual path."),
        "name": string("Final path component."),
        "type": .object(["type": .string("string"), "enum": .array([.string("file"), .string("directory")])]),
        "size": .object(["type": .array([.string("integer"), .string("null")])]),
    ], required: ["path", "name", "type", "size"])

    private static let listing = object([
        "items": .object(["type": .string("array"), "items": item]),
        "truncated": boolean("Whether more entries matched."),
    ], required: ["items", "truncated"])

    private static let read = object([
        "path": path("Full virtual path."),
        "text": nullableString,
        "truncated": boolean("Whether the returned text was truncated."),
        "unsupported": nullableString,
    ], required: ["path", "text", "truncated", "unsupported"])

    private static let deletion = object([
        "path": path("Deleted virtual path."),
        "deleted": boolean("Always true on success."),
    ], required: ["path", "deleted"])

    private static let glob = object([
        "paths": .object(["type": .string("array"), "items": path("Matching virtual path.")]),
        "truncated": boolean("Whether more paths matched."),
    ], required: ["paths", "truncated"])

    private static let grepMatch = object([
        "path": path("Matching virtual path."),
        "line": integer("One-indexed line number.", minimum: 1, maximum: Int.max),
        "text": string("Matching line, bounded to 500 characters."),
        "before": .object(["type": .string("array"), "items": string("Context line before the match.")]),
        "after": .object(["type": .string("array"), "items": string("Context line after the match.")]),
    ], required: ["path", "line", "text", "before", "after"])

    private static let grep = object([
        "matches": .object(["type": .string("array"), "items": grepMatch]),
        "scannedFiles": integer("Number of text files scanned.", minimum: 0, maximum: VirtualFileSystem.maximumSearchFiles),
        "skippedFiles": integer("Number of unsupported or unavailable files skipped.", minimum: 0, maximum: VirtualFileSystem.maximumSearchFiles),
        "truncated": boolean("Whether file, byte, match, or line limits truncated the search."),
    ], required: ["matches", "scannedFiles", "skippedFiles", "truncated"])

    private static func entry(_ name: String, _ description: String, input: JSONValue, output: JSONValue) -> (String, JSONValue) {
        (name, .object(["description": .string(description), "inputSchema": input, "outputSchema": output]))
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

    private static func path(_ description: String) -> JSONValue { string(description) }

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int) -> JSONValue {
        .object([
            "type": .string("integer"),
            "minimum": .int(minimum),
            "maximum": .int(maximum),
            "description": .string(description),
        ])
    }

    private static func string(_ value: JSValue) -> String? {
        value.isString ? value.toString() : nil
    }
}
