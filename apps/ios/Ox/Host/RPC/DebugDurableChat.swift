import Foundation

extension OxHostProtocol {
    static let durableTemporarySessionID = ProcessInfo.processInfo.environment["OX_DURABLE_TEMPORARY_SESSION"].flatMap(UUID.init(uuidString:))

    #if DEBUG && targetEnvironment(simulator)
    struct DurableChatRequest: Codable {
        let caseID: UUID
        let action: String
        let sessionId: String?
        let path: String?
        let text: String?
        let artifactFiles: Bool?
        let reference: JSONValue?
        let limit: Int?
        let historyCursor: JSONValue?
        let listCursor: JSONValue?
        let presentation: JSONValue?
        let lastReadEntryID: Int?
    }
    #endif

    @MainActor
    static func prepareDurableTemporaryChat(_ chat: Conversation, caseID: UUID) async throws {
        _ = try await DurableChatController.attach(chat, caseID: caseID, artifactFiles: true)
    }

    @MainActor
    static func releaseDurableTemporaryChat(_ chat: Conversation) async {
        await chat.waitForSubmission()
        await DurableChatController.release(chat)
    }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    static func handleDurableChat(_ request: DurableChatRequest, chats: ConversationManager, reply: OxHostRPC.Reply) {
        Task { @MainActor in
            do { reply.success(try await DurableChatController.command(request, chats: chats)) }
            catch { reply.failure(error.localizedDescription) }
        }
    }
    #endif
}

/// Deliberate rollout gate: real native providers/capabilities and chat presentation, synthetic cache storage only.
/// Persisted chats are refused so the legacy transcript cannot become a second authority for the same conversation.
@MainActor
private enum DurableChatController {
    struct Session {
        let runtime: DurableRuntime
        let host: DurableAgentHost
        let scope: ProfileScope
        let artifactFiles: Bool
        let artifactScope: ProfileScope?
        var chats: [UUID: Conversation] = [:]
        var opening = true
        var closing = false
    }
    static var sessions: [UUID: Session] = [:]
    static var attaching: Set<UUID> = []

    static func attach(_ chat: Conversation, caseID: UUID, artifactFiles requestedBackend: Bool?) async throws -> JSONValue {
        guard chat.isTemporary, !chat.isBusy else { throw RuntimeError.bridge("Durable rollout requires an idle temporary chat") }
        guard !attaching.contains(chat.id), !sessions.contains(where: { $0.key != caseID && $0.value.chats[chat.id] != nil }) else {
            throw RuntimeError.bridge("Chat already belongs to another durable Session or attachment")
        }
        attaching.insert(chat.id)
        defer { attaching.remove(chat.id) }
        if sessions[caseID] == nil {
            guard sessions.count < 2 else { throw RuntimeError.bridge("Close another durable Session first") }
            let host = DurableAgentHost()
            let physical = requestedBackend == true
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "PiDurableProof/\(physical ? "NativeFiles" : "Native")/\(caseID.uuidString)")
            let runtime = DurableRuntime(databaseURL: directory.appending(path: physical ? "state.sqlite" : "session.sqlite"),
                artifactRoot: physical ? directory : nil) { method, params, stream in try await host.handle(method, params, stream: stream) }
            let artifactScope = physical ? ProfileScope(profileID: caseID, root: directory, location: .local) : nil
            sessions[caseID] = Session(runtime: runtime, host: host, scope: chat.scope, artifactFiles: physical, artifactScope: artifactScope)
            do {
                _ = try await runtime.command(JSONValue.object(["action": .string("open"), "profileID": .string(caseID.uuidString), "artifactFiles": .bool(physical)]).jsonString())
                sessions[caseID]?.opening = false
            } catch { await runtime.dispose(); sessions.removeValue(forKey: caseID); throw error }
        }
        guard var session = sessions[caseID], !session.opening, !session.closing, session.scope == chat.scope,
              requestedBackend == nil || requestedBackend == session.artifactFiles else { throw RuntimeError.bridge("Session unavailable or bound to another Profile scope") }
        guard session.chats.count < 8 || session.chats[chat.id] != nil else { throw RuntimeError.bridge("Durable Session chat limit reached") }
        try chat.installDurableRoute(DurableConversationRoute(
            session: .init(runtime: session.runtime, host: session.host, scope: chat.scope),
            nativeID: chat.id, profileID: caseID, artifactScope: session.artifactScope, reference: nil))
        session.chats[chat.id] = chat; sessions[caseID] = session
        Log.agent.info("PiDurable rollout attached chat=\(chat.id) case=\(caseID) profile=\(chat.scope.profileID?.uuidString ?? "nil")")
        return .object(["attached": .bool(true), "chatID": .string(chat.id.uuidString)])
    }

    static func release(_ chat: Conversation) async {
        guard let entry = sessions.first(where: { $0.value.chats[chat.id] != nil }) else { return }
        var session = entry.value
        session.chats[chat.id] = nil
        await session.host.unbind(chatID: chat.id.uuidString)
        if !session.chats.isEmpty { sessions[entry.key] = session; return }
        session.closing = true; sessions[entry.key] = session
        do {
            _ = try await session.runtime.command(JSONValue.object(["action": .string("close")]).jsonString())
            await session.runtime.dispose()
            sessions.removeValue(forKey: entry.key)
            if entry.key != OxHostProtocol.durableTemporarySessionID, let root = session.artifactScope?.root { try FileManager.default.removeItem(at: root) }
        } catch { Log.agent.error("PiDurable temporary close failed=\(error.localizedDescription)") }
    }

    #if DEBUG && targetEnvironment(simulator)
    static func command(_ request: OxHostProtocol.DurableChatRequest, chats: ConversationManager) async throws -> JSONValue {
        if request.action == "attach" {
            guard case .found(let chat?) = OxHostProtocol.resolveSession(chats, request.sessionId), chat.isTemporary, !chat.isBusy else {
                throw RuntimeError.bridge("Durable rollout requires an idle temporary chat; persisted chats remain behind the storage migration gate")
            }
            return try await attach(chat, caseID: request.caseID, artifactFiles: request.artifactFiles)
        }
        guard var session = sessions[request.caseID], !session.opening, !session.closing else { throw RuntimeError.bridge("Attach an isolated durable Session first") }
        guard ["inspect", "fileWrite", "fileRead", "fileReference", "fileRemove", "conversationList", "conversationMetadata",
               "conversationHistory", "conversationPresent", "conversationRead", "close"].contains(request.action) else { throw RuntimeError.bridge("Unknown durable rollout command") }
        if request.action == "close" {
            guard session.chats.values.allSatisfy({ !$0.isBusy }) else { throw RuntimeError.bridge("Stop active chats before closing the rollout Session") }
            session.closing = true; sessions[request.caseID] = session
        }
        let value = JSONValue.object(["action": .string(request.action), "chatID": request.sessionId.map(JSONValue.string) ?? .null, "path": request.path.map(JSONValue.string) ?? .null,
                                      "text": request.text.map(JSONValue.string) ?? .null,
                                      "reference": request.reference ?? .null, "limit": request.limit.map(JSONValue.int) ?? .int(100),
                                      "historyCursor": request.historyCursor ?? .null, "listCursor": request.listCursor ?? .null,
                                      "presentation": request.presentation ?? .null, "lastReadEntryID": request.lastReadEntryID.map(JSONValue.int) ?? .null])
        do {
            let result = try await session.runtime.command(value.jsonString(), entry: "agentCommand")
            if request.action == "close" {
                for chat in session.chats.values {
                    try chat.installDurableRoute(nil)
                    await session.host.unbind(chatID: chat.id.uuidString)
                }
                await session.runtime.dispose(); sessions.removeValue(forKey: request.caseID)
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        } catch {
            if request.action == "close" { sessions[request.caseID]?.closing = false }
            throw error
        }
    }
    #endif
}
