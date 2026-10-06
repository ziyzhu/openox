import Foundation

extension OxHostProtocol {
    struct VirtualMachineLogRow: Encodable {
        let level: String
        let message: String
    }

    struct VMControlResult: Encodable {
        let value: JSONValue?
        let logs: [VirtualMachineLogRow]?
    }

    @MainActor
    static func handleVMInspect(
        _ command: VMRequest,
        conversationManager: ConversationManager,
        reply: OxHostRPC.Reply
    ) {
        let session: Conversation?
        switch resolveSession(conversationManager, command.sessionId) {
        case .error(let error):
            reply.failure(error)
            return
        case .found(let resolved): session = resolved
        }
        let functionCount = OxFunctionCatalog.build().objectValue?.count ?? 0
        let sessionValue: JSONValue = session.map {
            .object([
                "id": .string($0.id.uuidString),
                "temporary": .bool($0.isTemporary),
            ])
        } ?? .null
        var roots = session == nil ? [] : ["MEMORY.md", "SOUL.md", "artifacts", "skills", "services", "conversations"]
        if session?.attachedServices.contains(where: { $0.domain == "ios:files" }) == true {
            roots.append("files")
        }
        #if targetEnvironment(simulator)
        let mode = "simulator"
        #else
        let mode = "device"
        #endif
        let value = JSONValue.object([
            "host": .object([
                "kind": .string("ios"),
                "mode": .string(mode),
                "transport": .string("websocket"),
            ]),
            "vm": .object([
                "contract": .string("ox"),
                "engine": .string("javascriptcore"),
                "lifetime": .string("profile"),
                "sessionBinding": .string("chat"),
                "functionCount": .int(functionCount),
            ]),
            "session": sessionValue,
            "vfsRoots": .array(roots.map(JSONValue.string)),
        ])
        reply.success(VMControlResult(value: value, logs: nil))
    }

    @MainActor
    static func handleVMFunctions(_ command: VMFunctionsRequest, reply: OxHostRPC.Reply) {
        let catalog = OxFunctionCatalog.build()
        let help = OxFunctionCatalog.buildHelpText()
        let value: JSONValue
        if let name = command.function {
            guard let schema = catalog.objectValue?[name], let text = help.objectValue?[name] else {
                reply.failure("unknown VM function: \(name)")
                return
            }
            value = .object(["name": .string(name), "schema": schema, "help": text])
        } else {
            value = .object(["functions": catalog])
        }
        reply.success(VMControlResult(value: value, logs: nil))
    }

    @MainActor
    static func handleVMCall(
        _ command: VMCallRequest,
        conversationManager: ConversationManager,
        reply: OxHostRPC.Reply
    ) {
        guard command.arguments.objectValue != nil else {
            reply.failure("VM function arguments must be an object")
            return
        }
        guard OxFunctionCatalog.build().objectValue?[command.function] != nil else {
            reply.failure("unknown VM function: \(command.function)")
            return
        }
        let source = "return await \(command.function)(\(command.arguments.jsonString()));"
        executeVM(
            conversationManager: conversationManager,
            id: reply.id,
            sessionID: command.sessionId,
            source: source,
            logLabel: "call function=\(command.function)",
            reply: reply
        )
    }

    @MainActor
    static func handleVMEval(
        _ command: VMEvalRequest,
        conversationManager: ConversationManager,
        reply: OxHostRPC.Reply
    ) {
        guard !command.script.isEmpty else {
            reply.failure("missing script")
            return
        }
        executeVM(
            conversationManager: conversationManager,
            id: reply.id,
            sessionID: command.sessionId,
            source: command.script,
            logLabel: "eval bytes=\(command.script.utf8.count)",
            reply: reply
        )
    }

    @MainActor
    static func executeVM(
        conversationManager: ConversationManager,
        id: String,
        sessionID: String?,
        source: String,
        logLabel: String,
        reply: OxHostRPC.Reply
    ) {
        let session: Conversation
        switch resolveSession(conversationManager, sessionID) {
        case .error(let error):
            reply.failure(error)
            return
        case .found(nil):
            reply.failure("no active VM session")
            return
        case .found(let resolved?): session = resolved
        }
        Log.agent.debug("OxHostProtocol.\(logLabel) id=\(id) session=\(session.id.uuidString)")
        Task { @MainActor in
            do {
                let result = try await session.runDebugSnippet(source)
                reply.success(VMControlResult(
                    value: result.value,
                    logs: result.logs.map { VirtualMachineLogRow(level: $0.level, message: $0.message) }
                ))
            } catch {
                let logs = (error as? VirtualMachine.Error)?.logs ?? []
                reply.failure(error.localizedDescription, data: VMControlResult(
                    value: nil,
                    logs: logs.map { VirtualMachineLogRow(level: $0.level, message: $0.message) }
                ))
            }
        }
    }

}
