import Foundation
import JavaScriptCore

nonisolated enum OxRepositories {
    static let function = OxFunction(
        namespace: "repository",
        schema: {
            [
                (
                    "ox.repository.connect",
                    .object([
                        "description": .string("Install a public HTTPS Git repository: `await ox.repository.connect({ origin, purpose })`. The repository must contain repository.json at its root. Returns its ID for later disconnection; services and skills become available after the repository loads."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "origin": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(2048)]),
                            ]),
                            "required": .array([.string("origin")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.sync",
                    .object([
                        "description": .string("Refresh an installed Remote repository in place: `await ox.repository.sync({ repository, purpose })`. Find its ID with ox.app.repositories. Returns the refreshed service and skill counts."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                            ]),
                            "required": .array([.string("repository")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.disconnect",
                    .object([
                        "description": .string("Remove an installed remote repository by ID: `await ox.repository.disconnect({ repository, purpose })`. Find its ID with ox.app.repositories. This removes the local snapshot, service definitions, and skills; website sign-ins and data remain."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                            ]),
                            "required": .array([.string("repository")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.propose",
                    .object([
                        "description": .string("Publish selected services and skills from one saved Local commit and create a change request in a configured target without cloning it: `await ox.repository.propose({ target, commitHash, services?, skills?, title, body, status, purpose })`. Use target `openox`. `status` must be `draft` or `open`. The user approves publication and may be asked to authorize the target provider."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "target": .object(["type": .string("string"), "enum": .array([.string("openox")])]),
                                "commitHash": .object(["type": .string("string"), "pattern": .string("^[a-f0-9]{40}$")]),
                                "services": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                                    "minItems": .int(0),
                                    "maxItems": .int(20),
                                    "uniqueItems": .bool(true),
                                ]),
                                "skills": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                                    "minItems": .int(0),
                                    "maxItems": .int(20),
                                    "uniqueItems": .bool(true),
                                ]),
                                "title": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(200)]),
                                "body": .object(["type": .string("string"), "maxLength": .int(20_000)]),
                                "status": .object(["type": .string("string"), "enum": .array([.string("draft"), .string("open")])]),
                            ]),
                            "required": .array([.string("target"), .string("commitHash"), .string("title"), .string("body"), .string("status")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.git.status",
                    .object([
                        "description": .string("Inspect the Local repository's active commit, main tip, live or historical view, and staged, unstaged, and untracked paths: `await ox.repository.git.status({ purpose })`. Local is the only Git-managed repository."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([:]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.git.log",
                    .object([
                        "description": .string("Read the Local repository's linear main history newest-first: `await ox.repository.git.log({ limit?, cursor?, purpose })`. `limit` defaults to 20. Pass the returned `nextCursor` to continue."),
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
                    "ox.repository.git.show",
                    .object([
                        "description": .string("Inspect one Local service commit without changing the active service view: `await ox.repository.git.show({ commitHash, path?, purpose })`. Add a repository-relative UTF-8 `path`, such as `web/example.com/actions.js`, to read that historical file."),
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
                    "ox.repository.git.diff",
                    .object([
                        "description": .string("Review Local repository changes without changing its active view: `await ox.repository.git.diff({ commitHash?, baseCommitHash?, path?, purpose })`. With no commit hashes, compares the active commit to the working tree. With `commitHash`, compares that commit to its parent. Add `baseCommitHash` to compare two commits. `path` narrows the result. When `truncated` is true, call again with a narrower path."),
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
                    "ox.repository.git.checkout",
                    .object([
                        "description": .string("Temporarily visit a Local service commit without moving its linear main tip: `await ox.repository.git.checkout({ commitHash, purpose })`. Historical views are read-only. Use `commitHash: \"latest\"` to return to the live tip. Requires a clean worktree."),
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
                    "ox.repository.git.commit",
                    .object([
                        "description": .string("Validate, stage, and commit all Local service changes to its linear history: `await ox.repository.git.commit({ message, purpose })`. Local must be at its live tip and the call fails when there are no changes."),
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
                    "ox.repository.git.revert",
                    .object([
                        "description": .string("Revert one Local commit by applying its inverse and creating a new commit at the live tip: `await ox.repository.git.revert({ commitHash, message, purpose })`. This never rewrites history and requires a clean Local worktree."),
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
                    "ox.repository.git.restore",
                    .object([
                        "description": .string("Restore Local changes from its live tip: `await ox.repository.git.restore({ path?, purpose })`. With a changed file `path` from `ox.repository.git.status`, or the same `services/` path passed to `ox.fs.delete`, restores only that file; without one, erases every uncommitted staged, unstaged, and untracked change. It is unavailable in a historical checkout."),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "path": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(1000)]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
            ]
        },
        installNatives: { ctx, env in
            let connectRepositoryBlock: @convention(block) (String, JSValue) -> JSValue = { origin, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.connectRepository(origin: origin, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(connectRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryConnect" as NSString)

            let syncRepositoryBlock: @convention(block) (String, JSValue) -> JSValue = { repository, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.syncRepository(repository: repository, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(syncRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositorySync" as NSString)

            let disconnectRepositoryBlock: @convention(block) (String, JSValue) -> JSValue = { repository, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.disconnectRepository(repository: repository, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(disconnectRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryDisconnect" as NSString)

            let proposeRepositoryBlock: @convention(block) (String, String, JSValue, JSValue, String, String, String, JSValue) -> JSValue = {
                target, commitHash, servicesValue, skillsValue, title, body, status, purposeValue in
                let services = servicesValue.toArray().compactMap { $0 as? String }
                let skills = skillsValue.toArray().compactMap { $0 as? String }
                return env.call(suspendingTimeout: true) {
                    try await $0.proposeRepository(
                        target: target,
                        commitHash: commitHash,
                        services: services,
                        skills: skills,
                        title: title,
                        body: body,
                        status: status,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(proposeRepositoryBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryPropose" as NSString)

            let gitStatusBlock: @convention(block) (String, JSValue) -> JSValue = { repository, purposeValue in
                env.call { try await $0.repositoryGitStatus(repository: repository, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(gitStatusBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitStatus" as NSString)

            let gitLogBlock: @convention(block) (String, Int32, JSValue, JSValue) -> JSValue = { repository, limit, cursorValue, purposeValue in
                let cursor = cursorValue.isString ? cursorValue.toString() : nil
                return env.call {
                    try await $0.repositoryGitLog(
                        repository: repository,
                        limit: Int(limit),
                        cursor: cursor,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitLogBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitLog" as NSString)

            let gitShowBlock: @convention(block) (String, String, JSValue, JSValue) -> JSValue = { repository, commitHash, pathValue, purposeValue in
                let path = pathValue.isString ? pathValue.toString() : nil
                return env.call {
                    try await $0.repositoryGitShow(
                        repository: repository,
                        commitHash: commitHash,
                        path: path,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitShowBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitShow" as NSString)

            let gitDiffBlock: @convention(block) (String, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
                repository, commitHashValue, baseCommitHashValue, pathValue, purposeValue in
                let commitHash = commitHashValue.isString ? commitHashValue.toString() : nil
                let baseCommitHash = baseCommitHashValue.isString ? baseCommitHashValue.toString() : nil
                let path = pathValue.isString ? pathValue.toString() : nil
                return env.call {
                    try await $0.repositoryGitDiff(
                        repository: repository,
                        commitHash: commitHash,
                        baseCommitHash: baseCommitHash,
                        path: path,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitDiffBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitDiff" as NSString)

            let gitCheckoutBlock: @convention(block) (String, String, JSValue) -> JSValue = { repository, commitHash, purposeValue in
                env.call(suspendingTimeout: true) {
                    try await $0.repositoryGitCheckout(
                        repository: repository,
                        commitHash: commitHash,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitCheckoutBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitCheckout" as NSString)

            let gitCommitBlock: @convention(block) (String, JSValue) -> JSValue = { message, purposeValue in
                env.call(suspendingTimeout: true) { try await $0.repositoryGitCommit(message: message, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(gitCommitBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitCommit" as NSString)

            let gitRevertBlock: @convention(block) (String, String, JSValue) -> JSValue = { commitHash, message, purposeValue in
                env.call(suspendingTimeout: true) {
                    try await $0.repositoryGitRevert(
                        commitHash: commitHash,
                        message: message,
                        purpose: purposeValue.toString()!
                    )
                }
            }
            ctx.setObject(gitRevertBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitRevert" as NSString)

            let gitRestoreBlock: @convention(block) (JSValue, JSValue) -> JSValue = { pathValue, purposeValue in
                let path = pathValue.isString ? pathValue.toString() : nil
                return env.call(suspendingTimeout: true) {
                    try await $0.repositoryGitRestore(path: path, purpose: purposeValue.toString()!)
                }
            }
            ctx.setObject(gitRestoreBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryGitRestore" as NSString)

        },
        jsFragment: """
            connect: (value) => { const options = __oxOptions(value, 'ox.repository.connect'); return __nativeRepositoryConnect(String(options.origin), String(options.purpose)); },
            sync: (value) => { const options = __oxOptions(value, 'ox.repository.sync'); return __nativeRepositorySync(String(options.repository), String(options.purpose)); },
            disconnect: (value) => { const options = __oxOptions(value, 'ox.repository.disconnect'); return __nativeRepositoryDisconnect(String(options.repository), String(options.purpose)); },
            propose: (value) => { const options = __oxOptions(value, 'ox.repository.propose'); return __nativeRepositoryPropose(String(options.target), String(options.commitHash), options.services ?? [], options.skills ?? [], String(options.title), String(options.body), String(options.status), String(options.purpose)); },
          git: {
            status: (value) => { const options = __oxOptions(value, 'ox.repository.git.status'); return __nativeRepositoryGitStatus(String(options.repository ?? 'local'), String(options.purpose)); },
            log: (value) => { const options = __oxOptions(value, 'ox.repository.git.log'); return __nativeRepositoryGitLog(String(options.repository ?? 'local'), Number(options.limit ?? 20), options.cursor ?? null, String(options.purpose)); },
            show: (value) => { const options = __oxOptions(value, 'ox.repository.git.show'); return __nativeRepositoryGitShow(String(options.repository ?? 'local'), String(options.commitHash), options.path ?? null, String(options.purpose)); },
            diff: (value) => { const options = __oxOptions(value, 'ox.repository.git.diff'); return __nativeRepositoryGitDiff(String(options.repository ?? 'local'), options.commitHash ?? null, options.baseCommitHash ?? null, options.path ?? null, String(options.purpose)); },
            checkout: (value) => { const options = __oxOptions(value, 'ox.repository.git.checkout'); return __nativeRepositoryGitCheckout(String(options.repository ?? 'local'), String(options.commitHash), String(options.purpose)); },
            commit: (value) => { const options = __oxOptions(value, 'ox.repository.git.commit'); return __nativeRepositoryGitCommit(String(options.message), String(options.purpose)); },
            revert: (value) => { const options = __oxOptions(value, 'ox.repository.git.revert'); return __nativeRepositoryGitRevert(String(options.commitHash), String(options.message), String(options.purpose)); },
            restore: (value) => { const options = __oxOptions(value, 'ox.repository.git.restore'); return __nativeRepositoryGitRestore(options.path ?? null, String(options.purpose)); }
          }
        """
    )
}
