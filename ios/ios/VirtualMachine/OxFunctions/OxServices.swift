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
                        "description": .string("Search the merged service MonoRepository with the same service search used by the app when no attached service covers the task: `await ox.service.find({ query, purpose })`. Returns up to five ranked matches (domain, kind, manifestPath, repository, repositoryProvenance, name, description, matchedAction, signIn, saved, attached). Read a strong candidate's `manifestPath` when its action contract matters, then bring the best match in with `ox.service.attach({ domain, purpose })`. `purpose` is a short (<10 words) human-readable description shown to the user as the step label."),
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
                    "ox.service.listAttached",
                    .object([
                        "description": .string("List the services currently attached to this chat: `await ox.service.listAttached({ kind?, purpose })`. Filter by `kind: \"web\"` for website services hosted by Ox Server, `kind: \"ios\"` for client-owned device services, or `kind: \"mcp\"` for directly connected remote MCP servers. Every result includes its kind."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "kind": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("web"), .string("ios"), .string("mcp")]),
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
                    "ox.service.createWeb",
                    .object([
                        "description": .string("Create a web service in the always-available editable Local repository and select it under `services/web/<domain>/`: `await ox.service.createWeb({ domain, purpose })`. The user approves service creation. The valid skeleton can then be changed with `ox.fs` tools."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "domain": .object([
                                    "type": .string("string"),
                                    "minLength": .int(3),
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
                    "ox.service.copyToLocal",
                    .object([
                        "description": .string("Copy the selected Bundled, Development, or Remote service into the editable Local repository and select that candidate: `await ox.service.copyToLocal({ domain, purpose })`. The user approves the copy. Edit its expanded source under `services/` with `ox.fs`."),
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
                    "ox.service.git.status",
                    .object([
                        "description": .string("Inspect the Local service repository's active commit, main tip, live or historical view, and staged, unstaged, and untracked paths: `await ox.service.git.status({ purpose })`. Local is the only Git-managed service repository."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([:]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.log",
                    .object([
                        "description": .string("Read the Local service repository's linear main history newest-first: `await ox.service.git.log({ limit?, cursor?, purpose })`. `limit` defaults to 20. Pass the returned `nextCursor` to continue."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "limit": .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(100)]),
                                "cursor": .object(["type": .string("string"), "pattern": .string("^[a-f0-9]{40}$")]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.show",
                    .object([
                        "description": .string("Inspect one Local service commit without changing the active service view: `await ox.service.git.show({ commitHash, path?, purpose })`. Add a repository-relative UTF-8 `path`, such as `web/example.com/actions.js`, to read that historical file."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "commitHash": .object(["type": .string("string"), "pattern": .string("^[a-f0-9]{40}$")]),
                                "path": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(1000)]),
                            ]),
                            "required": .array([.string("commitHash")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.diff",
                    .object([
                        "description": .string("Review Local service repository changes without changing its active view: `await ox.service.git.diff({ commitHash?, baseCommitHash?, path?, purpose })`. With no commit hashes, compares the active commit to the working tree. With `commitHash`, compares that commit to its parent. Add `baseCommitHash` to compare two commits. `path` narrows the result. When `truncated` is true, call again with a narrower path."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "commitHash": .object(["type": .string("string"), "pattern": .string("^[a-f0-9]{40}$")]),
                                "baseCommitHash": .object(["type": .string("string"), "pattern": .string("^[a-f0-9]{40}$")]),
                                "path": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(1000)]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.checkout",
                    .object([
                        "description": .string("Temporarily visit a Local service commit without moving its linear main tip: `await ox.service.git.checkout({ commitHash, purpose })`. Historical views are read-only. Use `commitHash: \"latest\"` to return to the live tip. Requires approval and a clean worktree."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "commitHash": .object(["type": .string("string"), "pattern": .string("^(?:latest|[a-f0-9]{40})$")]),
                            ]),
                            "required": .array([.string("commitHash")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.commit",
                    .object([
                        "description": .string("Validate, stage, and commit all Local service changes to its linear history: `await ox.service.git.commit({ message, purpose })`. Local must be at its live tip. Requires approval and fails when there are no changes."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "message": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                            ]),
                            "required": .array([.string("message")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.revert",
                    .object([
                        "description": .string("Revert one Local commit by applying its inverse and creating a new commit at the live tip: `await ox.service.git.revert({ commitHash, message, purpose })`. This never rewrites history. Requires approval and a clean Local worktree."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "commitHash": .object(["type": .string("string"), "pattern": .string("^[a-f0-9]{40}$")]),
                                "message": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                            ]),
                            "required": .array([.string("commitHash"), .string("message")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.git.restore",
                    .object([
                        "description": .string("Erase every uncommitted staged, unstaged, and untracked change in Local and restore its live tip: `await ox.service.git.restore({ purpose })`. Requires approval and is unavailable in a historical checkout."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([:]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.service.attach",
                    .object([
                        "description": .string("Attach an Ox Server service by domain after inspecting its `services/<kind>/<id>/manifest.json`: `await ox.service.attach({ domain, purpose })`. Saves the service and attaches it to the chat (it appears in the attachment bar, same as a user-attached service). The user is asked to approve the attach the first time — if they decline, this throws, so surface that and don't retry blindly. Returns the service snapshot with its cached sign-in status; a `requireAuth` action revalidates before use. `purpose` is a short (<10 words) human-readable description shown to the user as the step label."),
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

            let createWebBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call { try await $0.createWebService(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(createWebBlock as AnyObject, forKeyedSubscript: "__nativeServiceCreateWeb" as NSString)

            let copyToLocalBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                env.call { try await $0.copyServiceToLocal(domain: domain, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(copyToLocalBlock as AnyObject, forKeyedSubscript: "__nativeServiceCopyToLocal" as NSString)

            let gitStatusBlock: @convention(block) (String, JSValue) -> JSValue = { repository, purposeValue in
                env.call { try await $0.serviceGitStatus(repository: repository, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(gitStatusBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitStatus" as NSString)

            let gitLogBlock: @convention(block) (String, Int32, JSValue, JSValue) -> JSValue = { repository, limit, cursorValue, purposeValue in
                let cursor = cursorValue.isString ? cursorValue.toString() : nil
                return env.call {
                    try await $0.serviceGitLog(
                        repository: repository,
                        limit: Int(limit),
                        cursor: cursor,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitLogBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitLog" as NSString)

            let gitShowBlock: @convention(block) (String, String, JSValue, JSValue) -> JSValue = { repository, commitHash, pathValue, purposeValue in
                let path = pathValue.isString ? pathValue.toString() : nil
                return env.call {
                    try await $0.serviceGitShow(
                        repository: repository,
                        commitHash: commitHash,
                        path: path,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitShowBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitShow" as NSString)

            let gitDiffBlock: @convention(block) (String, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
                repository, commitHashValue, baseCommitHashValue, pathValue, purposeValue in
                let commitHash = commitHashValue.isString ? commitHashValue.toString() : nil
                let baseCommitHash = baseCommitHashValue.isString ? baseCommitHashValue.toString() : nil
                let path = pathValue.isString ? pathValue.toString() : nil
                return env.call {
                    try await $0.serviceGitDiff(
                        repository: repository,
                        commitHash: commitHash,
                        baseCommitHash: baseCommitHash,
                        path: path,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitDiffBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitDiff" as NSString)

            let gitCheckoutBlock: @convention(block) (String, String, JSValue) -> JSValue = { repository, commitHash, purposeValue in
                env.call(suspendingTimeout: true) {
                    try await $0.serviceGitCheckout(
                        repository: repository,
                        commitHash: commitHash,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitCheckoutBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitCheckout" as NSString)

            let gitCommitBlock: @convention(block) (String, JSValue) -> JSValue = { message, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.serviceGitCommit(message: message, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(gitCommitBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitCommit" as NSString)

            let gitRevertBlock: @convention(block) (String, String, JSValue) -> JSValue = { commitHash, message, purposeValue in
                env.call(suspendingTimeout: true) {
                    try await $0.serviceGitRevert(
                        commitHash: commitHash,
                        message: message,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitRevertBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitRevert" as NSString)

            let gitRestoreBlock: @convention(block) (JSValue) -> JSValue = { purposeValue in
                env.call(suspendingTimeout: true) { try await $0.serviceGitRestore(purpose: purposeValue.toString()!) }
            }
            ctx.setObject(gitRestoreBlock as AnyObject, forKeyedSubscript: "__nativeServiceGitRestore" as NSString)

            let attachBlock: @convention(block) (String, JSValue) -> JSValue = { domain, purposeValue in
                let purpose = purposeValue.toString()!
                return env.call { try await $0.attachService(domain: domain, purpose: purpose) }
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
          listAttached: (value) => { const options = __oxOptions(value, 'ox.service.listAttached'); return __nativeServiceListAttached(options.kind == null ? null : String(options.kind), String(options.purpose)); },
          inspect: (value) => { const options = __oxOptions(value, 'ox.service.inspect'); return __nativeServiceInspect(String(options.domain), options.actions ?? null, String(options.purpose)); },
          createWeb: (value) => { const options = __oxOptions(value, 'ox.service.createWeb'); return __nativeServiceCreateWeb(String(options.domain), String(options.purpose)); },
          copyToLocal: (value) => { const options = __oxOptions(value, 'ox.service.copyToLocal'); return __nativeServiceCopyToLocal(String(options.domain), String(options.purpose)); },
          git: {
            status: (value) => { const options = __oxOptions(value, 'ox.service.git.status'); return __nativeServiceGitStatus(String(options.repository ?? 'local'), String(options.purpose)); },
            log: (value) => { const options = __oxOptions(value, 'ox.service.git.log'); return __nativeServiceGitLog(String(options.repository ?? 'local'), Number(options.limit ?? 20), options.cursor ?? null, String(options.purpose)); },
            show: (value) => { const options = __oxOptions(value, 'ox.service.git.show'); return __nativeServiceGitShow(String(options.repository ?? 'local'), String(options.commitHash), options.path ?? null, String(options.purpose)); },
            diff: (value) => { const options = __oxOptions(value, 'ox.service.git.diff'); return __nativeServiceGitDiff(String(options.repository ?? 'local'), options.commitHash ?? null, options.baseCommitHash ?? null, options.path ?? null, String(options.purpose)); },
            checkout: (value) => { const options = __oxOptions(value, 'ox.service.git.checkout'); return __nativeServiceGitCheckout(String(options.repository ?? 'local'), String(options.commitHash), String(options.purpose)); },
            commit: (value) => { const options = __oxOptions(value, 'ox.service.git.commit'); return __nativeServiceGitCommit(String(options.message), String(options.purpose)); },
            revert: (value) => { const options = __oxOptions(value, 'ox.service.git.revert'); return __nativeServiceGitRevert(String(options.commitHash), String(options.message), String(options.purpose)); },
            restore: (value) => { const options = __oxOptions(value, 'ox.service.git.restore'); return __nativeServiceGitRestore(String(options.purpose)); }
          },
          attach: (value) => { const options = __oxOptions(value, 'ox.service.attach'); return __nativeServiceAttach(String(options.domain), String(options.purpose)); },
          detach: (value) => { const options = __oxOptions(value, 'ox.service.detach'); return __nativeServiceDetach(String(options.domain), String(options.purpose)); },
          signIn: (value) => { const options = __oxOptions(value, 'ox.service.signIn'); return __nativeServiceSignIn(String(options.domain), String(options.purpose)); },
          solve: (value) => { const options = __oxOptions(value, 'ox.service.solve'); return __nativeServiceSolve(String(options.domain), options.args, String(options.purpose)); },
          pay: (value) => { const options = __oxOptions(value, 'ox.service.pay'); return __nativeServicePayment(String(options.domain), options.args, String(options.purpose)); }
        """
    )
}
