#if targetEnvironment(simulator)
import Foundation

extension OxHostAPI {
    struct RunAgentResult: Encodable {
        let kind = "run-agent-result"
        let id: String
        let ok: Bool
        let client: ClientInfo?
        let model: ProviderModel?
        let message: AssistantMessage?
        let ttftMs: Int?
        let toolReadyMs: Int?
        let totalMs: Int?
        let error: String?

        struct ClientInfo: Encodable {
            let id: String
            let displayName: String
        }
    }


    struct VirtualMachineLogRow: Encodable {
        let level: String
        let message: String
    }

    struct VirtualMachineEvalResult: Encodable {
        let kind = "virtual-machine-eval-result"
        let id: String
        let ok: Bool
        let value: JSONValue?
        let logs: [VirtualMachineLogRow]?
        let error: String?
    }

    struct VMControlResult: Encodable {
        let kind: String
        let id: String
        let ok: Bool
        let protocolVersion: Int
        let value: JSONValue?
        let logs: [VirtualMachineLogRow]?
        let error: String?
    }


    @MainActor
    static func handleRunAgent(
        _ command: RunAgentRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let id = command.id
        let sessionId = command.sessionId
        let clientId = command.clientId
        let modelId = command.modelId
        let prompt = command.prompt
        let hasPrompt = !(prompt ?? "").isEmpty
        let hasSession = !(sessionId ?? "").isEmpty

        @MainActor func fail(_ message: String) {
            Log.agent.error("OxHostAPI.run-agent id=\(id) failed: \(message)")
            reply(encode(RunAgentResult(id: id, ok: false, client: nil, model: nil,
                                        message: nil, ttftMs: nil, toolReadyMs: nil, totalMs: nil, error: message)))
        }

        let registry = LLMRegistry.shared
        guard let client = registry.client(id: clientId) else { return fail("unknown client: \(clientId)") }
        guard let model = client.models.first(where: { $0.id == modelId }) else {
            return fail("unknown model: \(modelId) for client \(clientId)")
        }

        var systemPrompt: String?
        var messages: [Message] = []
        var tools: [any AgentTool] = []
        var options = StreamOptions()
        var sessionLabel = "none"

        if hasSession || !hasPrompt {
            let session: Chat
            switch resolveSession(chatManager, sessionId) {
            case .error(let error): return fail(error)
            case .found(nil): return fail("no active chat")
            case .found(let resolved?): session = resolved
            }
            guard let agent = session.agentSnapshot else { return fail("agent state unavailable") }
            systemPrompt = agent.systemPrompt.isEmpty ? nil : agent.systemPrompt
            messages = agent.messages
            tools = agent.tools
            options = agent.streamOptions
            sessionLabel = session.id.uuidString
        }

        if let override = command.systemPromptOverride {
            systemPrompt = override
        }
        if let history = command.historyOverride {
            messages = history.flatMap { turn in
                [.user(UserMessage(text: turn.user)), .assistant(turn.assistant)]
            }
        }
        if command.toolDescriptionOverrides != nil || command.toolParameterOverrides != nil {
            let names = Set(tools.map(\.name))
            let descriptionNames = Set(command.toolDescriptionOverrides?.keys.map { $0 } ?? [])
            let parameterNames = Set(command.toolParameterOverrides?.keys.map { $0 } ?? [])
            let overrideNames = descriptionNames.union(parameterNames)
            let unknown = overrideNames.subtracting(names)
            guard unknown.isEmpty else {
                return fail("unknown tool overrides: \(unknown.sorted().joined(separator: ", "))")
            }
            tools = tools.map { tool in
                ToolSchema(
                    name: tool.name,
                    description: command.toolDescriptionOverrides?[tool.name] ?? tool.description,
                    parameters: command.toolParameterOverrides?[tool.name] ?? tool.parameters,
                    strict: tool.strict
                )
            }
        }

        if hasPrompt {
            messages.append(.user(UserMessage(text: prompt ?? "")))
        }

        guard !messages.isEmpty else { return fail("nothing to run: provide a prompt or a chat with messages") }
        Log.agent.debug("OxHostAPI.run-agent id=\(id) client=\(client.id) model=\(model.id) session=\(sessionLabel) prompt=\(hasPrompt) msgs=\(messages.count) tools=\(tools.count) historyOverride=\(command.historyOverride?.count ?? 0) systemOverride=\(command.systemPromptOverride != nil) descriptionOverrides=\(command.toolDescriptionOverrides?.count ?? 0) parameterOverrides=\(command.toolParameterOverrides?.count ?? 0)")

        let start = Date()
        Task { @MainActor in
            var ttftMs: Int?
            var toolReadyMs: Int?
            @MainActor func finish(_ message: AssistantMessage) {
                let totalMs = Int(Date().timeIntervalSince(start) * 1000)
                let ok = message.stopReason != .error && message.stopReason != .aborted
                Log.agent.debug("OxHostAPI.run-agent id=\(id) done stopReason=\(message.stopReason) tokens(in/out)=\(message.usage.input)/\(message.usage.output) ttftMs=\(ttftMs.map(String.init) ?? "nil") toolReadyMs=\(toolReadyMs.map(String.init) ?? "nil") totalMs=\(totalMs)")
                reply(encode(RunAgentResult(
                    id: id, ok: ok,
                    client: .init(id: client.id, displayName: client.displayName),
                    model: model, message: message, ttftMs: ttftMs, toolReadyMs: toolReadyMs, totalMs: totalMs,
                    error: ok ? nil : message.errorMessage)))
            }

            let stream = client.stream(model: model, systemPrompt: systemPrompt,
                                       messages: messages, tools: tools, options: options)
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta, .thinkingDelta, .toolCallDelta:
                        if ttftMs == nil { ttftMs = Int(Date().timeIntervalSince(start) * 1000) }
                    case .toolCallEnd:
                        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                        if ttftMs == nil { ttftMs = elapsedMs }
                        if toolReadyMs == nil { toolReadyMs = elapsedMs }
                    case .done(_, let message): finish(message); return
                    case .failed(_, let message): finish(message); return
                    default: break
                    }
                }
                var message = AssistantMessage(model: model.id)
                message.stopReason = .error
                message.errorMessage = "stream ended without done/failed"
                finish(message)
            } catch {
                var message = AssistantMessage(model: model.id)
                message.stopReason = .error
                message.errorMessage = error.localizedDescription
                finish(message)
            }
        }
    }

    @MainActor

    static func handleVirtualMachineEval(
        _ command: VirtualMachineEvalRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let script = command.script

        @MainActor func fail(_ message: String) {
            reply(encode(VirtualMachineEvalResult(id: command.id, ok: false, value: nil, logs: [], error: message)))
        }

        guard !script.isEmpty else { return fail("missing script") }
        let session: Chat
        switch resolveSession(chatManager, command.sessionId) {
        case .error(let error): return fail(error)
        case .found(nil):       return fail("no active chat")
        case .found(let resolved?): session = resolved
        }

        Log.agent.debug("OxHostAPI.virtual-machine-eval id=\(command.id) session=\(session.id.uuidString) bytes=\(script.utf8.count)")
        Task { @MainActor in
            do {
                let result = try await session.runDebugSnippet(script)
                reply(encode(VirtualMachineEvalResult(
                    id: command.id,
                    ok: true,
                    value: jsonSafe(result.value?.toAny()),
                    logs: result.logs.map { VirtualMachineLogRow(level: $0.level, message: $0.message) },
                    error: nil
                )))
            } catch {
                let logs = (error as? VirtualMachine.Error)?.logs ?? []
                reply(encode(VirtualMachineEvalResult(
                    id: command.id,
                    ok: false,
                    value: nil,
                    logs: (error as? VirtualMachine.Error).map { _ in
                        logs.map { VirtualMachineLogRow(level: $0.level, message: $0.message) }
                    },
                    error: error.localizedDescription
                )))
            }
        }
    }

    static let vmProtocolVersion = 1

    @MainActor
    static func handleVMInspect(
        _ command: VMRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard validateVMProtocol(command.protocolVersion, id: command.id, kind: "vm-inspect-result", reply: reply) else { return }
        let session: Chat?
        switch resolveSession(chatManager, command.sessionId) {
        case .error(let error):
            reply(vmFailure(id: command.id, kind: "vm-inspect-result", error: error))
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
        var roots = session == nil ? [] : ["MEMORY.md", "SOUL.md", "artifacts", "skills", "services", "chats"]
        if session?.attachedServices.contains(where: { $0.domain == "ios:files" }) == true {
            roots.append("files")
        }
        let value = JSONValue.object([
            "host": .object([
                "kind": .string("ios"),
                "mode": .string("simulator"),
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
        reply(encode(VMControlResult(
            kind: "vm-inspect-result",
            id: command.id,
            ok: true,
            protocolVersion: vmProtocolVersion,
            value: value,
            logs: nil,
            error: nil
        )))
    }

    @MainActor
    static func handleVMListSessions(
        _ command: VMRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard validateVMProtocol(command.protocolVersion, id: command.id, kind: "vm-list-sessions-result", reply: reply) else { return }
        let currentID = chatManager.currentId
        let sessions = chatManager.debugSessions().sorted { left, right in
            if left.id == currentID { return true }
            if right.id == currentID { return false }
            return left.createdAt > right.createdAt
        }.map { session in
            JSONValue.object([
                "id": .string(session.id.uuidString),
                "title": .string(session.title),
                "active": .bool(session.id == currentID),
                "temporary": .bool(session.isTemporary),
                "model": .string(session.model.id),
                "createdAt": .string(iso(session.createdAt)),
            ])
        }
        reply(encode(VMControlResult(
            kind: "vm-list-sessions-result",
            id: command.id,
            ok: true,
            protocolVersion: vmProtocolVersion,
            value: .object(["sessions": .array(sessions)]),
            logs: nil,
            error: nil
        )))
    }

    @MainActor
    static func handleVMFunctions(_ command: VMFunctionsRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard validateVMProtocol(command.protocolVersion, id: command.id, kind: "vm-functions-result", reply: reply) else { return }
        let catalog = OxFunctionCatalog.build()
        let help = OxFunctionCatalog.buildHelpText()
        let value: JSONValue
        if let name = command.function {
            guard let schema = catalog.objectValue?[name], let text = help.objectValue?[name] else {
                reply(vmFailure(id: command.id, kind: "vm-functions-result", error: "unknown VM function: \(name)"))
                return
            }
            value = .object(["name": .string(name), "schema": schema, "help": text])
        } else {
            value = .object(["functions": catalog])
        }
        reply(encode(VMControlResult(
            kind: "vm-functions-result",
            id: command.id,
            ok: true,
            protocolVersion: vmProtocolVersion,
            value: value,
            logs: nil,
            error: nil
        )))
    }

    @MainActor
    static func handleVMCall(
        _ command: VMCallRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard validateVMProtocol(command.protocolVersion, id: command.id, kind: "vm-call-result", reply: reply) else { return }
        guard command.arguments.objectValue != nil else {
            reply(vmFailure(id: command.id, kind: "vm-call-result", error: "VM function arguments must be an object"))
            return
        }
        guard OxFunctionCatalog.build().objectValue?[command.function] != nil else {
            reply(vmFailure(id: command.id, kind: "vm-call-result", error: "unknown VM function: \(command.function)"))
            return
        }
        let source = "return await \(command.function)(\(command.arguments.jsonString()));"
        executeVM(
            chatManager: chatManager,
            id: command.id,
            kind: "vm-call-result",
            sessionID: command.sessionId,
            source: source,
            logLabel: "call function=\(command.function)",
            reply: reply
        )
    }

    @MainActor
    static func handleVMEval(
        _ command: VMEvalRequest,
        chatManager: ChatManager,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard validateVMProtocol(command.protocolVersion, id: command.id, kind: "vm-eval-result", reply: reply) else { return }
        guard !command.script.isEmpty else {
            reply(vmFailure(id: command.id, kind: "vm-eval-result", error: "missing script"))
            return
        }
        executeVM(
            chatManager: chatManager,
            id: command.id,
            kind: "vm-eval-result",
            sessionID: command.sessionId,
            source: command.script,
            logLabel: "eval bytes=\(command.script.utf8.count)",
            reply: reply
        )
    }

    @MainActor
    static func executeVM(
        chatManager: ChatManager,
        id: String,
        kind: String,
        sessionID: String?,
        source: String,
        logLabel: String,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        let session: Chat
        switch resolveSession(chatManager, sessionID) {
        case .error(let error):
            reply(vmFailure(id: id, kind: kind, error: error))
            return
        case .found(nil):
            reply(vmFailure(id: id, kind: kind, error: "no active VM session"))
            return
        case .found(let resolved?): session = resolved
        }
        Log.agent.debug("OxHostAPI.\(logLabel) id=\(id) session=\(session.id.uuidString)")
        Task { @MainActor in
            do {
                let result = try await session.runDebugSnippet(source)
                reply(encode(VMControlResult(
                    kind: kind,
                    id: id,
                    ok: true,
                    protocolVersion: vmProtocolVersion,
                    value: result.value,
                    logs: result.logs.map { VirtualMachineLogRow(level: $0.level, message: $0.message) },
                    error: nil
                )))
            } catch {
                let logs = (error as? VirtualMachine.Error)?.logs ?? []
                reply(encode(VMControlResult(
                    kind: kind,
                    id: id,
                    ok: false,
                    protocolVersion: vmProtocolVersion,
                    value: nil,
                    logs: logs.map { VirtualMachineLogRow(level: $0.level, message: $0.message) },
                    error: error.localizedDescription
                )))
            }
        }
    }

    @MainActor
    static func validateVMProtocol(
        _ version: Int,
        id: String,
        kind: String,
        reply: @escaping @MainActor (Data) -> Void
    ) -> Bool {
        guard version == vmProtocolVersion else {
            reply(vmFailure(id: id, kind: kind, error: "unsupported VM protocol version \(version); expected \(vmProtocolVersion)"))
            return false
        }
        return true
    }

    static func vmFailure(id: String, kind: String, error: String) -> Data {
        encode(VMControlResult(
            kind: kind,
            id: id,
            ok: false,
            protocolVersion: vmProtocolVersion,
            value: nil,
            logs: nil,
            error: error
        ))
    }

    static func jsonSafe(_ value: Any?) -> JSONValue {
        guard let value, !(value is NSNull) else { return .null }
        return JSONSerialization.isValidJSONObject([value]) ? .from(value) : .string(String(describing: value))
    }

}
#endif
