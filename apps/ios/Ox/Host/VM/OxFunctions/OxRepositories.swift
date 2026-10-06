import Foundation
import JavaScriptCore

nonisolated enum OxRepositories {
    static let function = OxFunction(
        namespace: "repository",
        schema: {
            [
                (
                    "ox.repository.conflicts",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.conflicts")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "service": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                            ]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.resolve",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.resolve")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "service": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(500)]),
                                "repository": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(100)]),
                            ]),
                            "required": .array([.string("service"), .string("repository")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.connect",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.connect")),
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
                        "description": .string(ModelGuidance.text("ox.repository.sync")),
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
                        "description": .string(ModelGuidance.text("ox.repository.disconnect")),
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
                        "description": .string(ModelGuidance.text("ox.repository.propose")),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "repository": .object(["type": .string("string"), "pattern": .string("^https://github\\.com/[^/]+/[^/]+(?:\\.git)?$"), "maxLength": .int(2048)]),
                                "base": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(255)]),
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
                            "required": .array([.string("repository"), .string("commitHash"), .string("title"), .string("body"), .string("status")]),
                            "additionalProperties": .bool(false),
                        ]),
                        "outputSchema": .object(["type": .string("object")]),
                    ])
                ),
                (
                    "ox.repository.git.status",
                    .object([
                        "description": .string(ModelGuidance.text("ox.repository.git.status")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.log")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.show")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.diff")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.checkout")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.commit")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.revert")),
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
                        "description": .string(ModelGuidance.text("ox.repository.git.restore")),
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
            let conflictsBlock: @convention(block) (JSValue, JSValue) -> JSValue = { serviceValue, purposeValue in
                let service = serviceValue.isString ? serviceValue.toString() : nil
                return env.call { try await $0.repositoryConflicts(service: service, purpose: purposeValue.toString()!) }
            }
            ctx.setObject(conflictsBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryConflicts" as NSString)

            let resolveBlock: @convention(block) (String, String, JSValue) -> JSValue = { service, repository, purposeValue in
                env.call(suspendingTimeout: true) {
                    try await $0.resolveRepositoryConflict(service: service, repository: repository, purpose: purposeValue.toString()!)
                }
            }
            ctx.setObject(resolveBlock as AnyObject, forKeyedSubscript: "__nativeRepositoryResolve" as NSString)

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

            let proposeRepositoryBlock: @convention(block) (String, JSValue, String, JSValue, JSValue, String, String, String, JSValue) -> JSValue = {
                repository, baseValue, commitHash, servicesValue, skillsValue, title, body, status, purposeValue in
                let services = servicesValue.toArray().compactMap { $0 as? String }
                let skills = skillsValue.toArray().compactMap { $0 as? String }
                let base = baseValue.isString ? baseValue.toString() : nil
                return env.call(suspendingTimeout: true) {
                    try await $0.proposeRepository(
                        repository: repository,
                        base: base,
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
            conflicts: (value) => { const options = __oxOptions(value, 'ox.repository.conflicts'); return __nativeRepositoryConflicts(options.service ?? null, String(options.purpose)); },
            resolve: (value) => { const options = __oxOptions(value, 'ox.repository.resolve'); return __nativeRepositoryResolve(String(options.service), String(options.repository), String(options.purpose)); },
            connect: (value) => { const options = __oxOptions(value, 'ox.repository.connect'); return __nativeRepositoryConnect(String(options.origin), String(options.purpose)); },
            sync: (value) => { const options = __oxOptions(value, 'ox.repository.sync'); return __nativeRepositorySync(String(options.repository), String(options.purpose)); },
            disconnect: (value) => { const options = __oxOptions(value, 'ox.repository.disconnect'); return __nativeRepositoryDisconnect(String(options.repository), String(options.purpose)); },
            propose: (value) => { const options = __oxOptions(value, 'ox.repository.propose'); return __nativeRepositoryPropose(String(options.repository), options.base ?? null, String(options.commitHash), options.services ?? [], options.skills ?? [], String(options.title), String(options.body), String(options.status), String(options.purpose)); },
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
